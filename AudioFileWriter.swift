import AVFoundation

// Writes PCM buffers to an audio file on its own serial queue.
//
// The audio render/capture thread only copies samples into a preallocated buffer, so the hot path
// never allocates an AVAudioPCMBuffer and never touches the disk. When every pooled buffer is
// still in flight the incoming buffer is dropped and counted instead of waiting for one.
//
// Note: handing the copy to the writer queue still costs a dispatch block allocation. Removing
// that would need a lock-free ring buffer with a dedicated consumer thread; the pooled-buffer
// approach here removes the dominant cost (buffer allocation plus unbounded growth) with far
// less code.
final class AudioFileWriter: @unchecked Sendable {
    static let minimumCapacity: AVAudioFrameCount = 4096
    
    private let queue = DispatchQueue(label: "com.mixrecording.audiofilewriter")
    private let poolSize: Int
    
    // Shared between the audio thread (pop) and the writer queue (open/close/recycle)
    private let poolLock = NSLock()
    private var pool: [AVAudioPCMBuffer] = []
    
    // Only touched on `queue`
    private var file: AVAudioFile?
    private var isOpen = false
    private var droppedBuffers = 0
    
    init(poolSize: Int = 4) {
        self.poolSize = poolSize
    }
    
    // Opens the output file and preallocates the buffer pool. Must be called before `write`.
    func open(url: URL, settings: [String: Any], format: AVAudioFormat, capacity: AVAudioFrameCount) throws {
        try queue.sync {
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
            isOpen = true
            
            let poolCapacity = max(capacity, AudioFileWriter.minimumCapacity)
            let buffers = (0..<poolSize).compactMap { _ in
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: poolCapacity)
            }
            poolLock.lock()
            pool = buffers
            poolLock.unlock()
        }
    }
    
    // Copies `source` into a pooled buffer and queues the write. Safe to call from the audio thread.
    func write(_ source: AVAudioPCMBuffer) {
        poolLock.lock()
        var target: AVAudioPCMBuffer?
        // Take a pooled buffer that can hold this source. Taps do not have to honour the requested
        // buffer size, so the pool adapts instead of dropping the audio.
        for (index, candidate) in pool.enumerated().reversed() where candidate.frameCapacity >= source.frameLength {
            target = candidate
            pool.remove(at: index)
            break
        }
        let needsAllocation = target == nil
        if needsAllocation {
            target = AVAudioPCMBuffer(pcmFormat: source.format,
                                      frameCapacity: max(source.frameLength, Self.minimumCapacity))
        }
        poolLock.unlock()
        
        guard let target = target else {
            countDrop()
            return
        }
        
        if needsAllocation {
            print("AudioFileWriter: incoming buffer of \(source.frameLength) frames needed a larger pool buffer")
        }
        
        guard AudioFileWriter.copy(source, into: target) != nil else {
            countDrop()
            return
        }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            guard self.isOpen, let file = self.file else {
                self.recycle(target)
                return
            }
            do {
                try file.write(from: target)
            } catch {
                print("Error writing audio buffer to file: \(error.localizedDescription)")
            }
            self.recycle(target)
        }
    }
    
    private func countDrop() {
        queue.async {
            self.droppedBuffers += 1
            if self.droppedBuffers == 1 {
                print("WARNING: dropping audio buffers - the writer cannot accept the incoming format or length")
            }
        }
    }
    
    // Stops accepting writes, drains the queue and closes the file. Returns the dropped buffer count.
    @discardableResult
    func close() -> Int {
        let dropped = queue.sync { () -> Int in
            isOpen = false
            file = nil
            return droppedBuffers
        }
        
        poolLock.lock()
        pool.removeAll()
        poolLock.unlock()
        
        return dropped
    }
    
    private func recycle(_ buffer: AVAudioPCMBuffer) {
        poolLock.lock()
        // Keep a few buffers in flight; more would only waste memory
        if pool.count < poolSize + 4 {
            pool.append(buffer)
        }
        poolLock.unlock()
    }
    
    // Copies every channel of `source` into `target` (no allocation, same format required)
    private static func copy(_ source: AVAudioPCMBuffer, into target: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength <= target.frameCapacity,
              source.format.channelCount == target.format.channelCount else { return nil }
        
        // Set the length first: this is what sizes the target's buffer list. A freshly created
        // AVAudioPCMBuffer reports mDataByteSize == 0 until frameLength is set.
        target.frameLength = source.frameLength
        
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let targetList = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        guard sourceList.count == targetList.count else { return nil }
        
        for index in 0..<sourceList.count {
            guard let src = sourceList[index].mData, let dst = targetList[index].mData else { return nil }
            let bytes = min(Int(sourceList[index].mDataByteSize), Int(targetList[index].mDataByteSize))
            memcpy(dst, src, bytes)
        }
        return target
    }
}
