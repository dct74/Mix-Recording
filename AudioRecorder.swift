import AVFoundation
import Cocoa
import CoreMedia
import ScreenCaptureKit

enum AudioSource {
    case microphone
    case systemAudio
    case combined
}

@MainActor
class AudioRecorder: NSObject {
    // Combined recording captures the microphone and the system audio separately and mixes them
    // offline when recording stops. Nothing is routed to the output device, so the microphone is
    // never monitored and cannot re-record its own delayed signal (the echo users heard before).
    private var combinedMicURL: URL
    private var combinedMicStart: Date?
    private var isMixingCombined = false
    
    // Audio recording properties
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    
    // The running ScreenCaptureKit session, if any. Only ever touched on the main actor; all of
    // the session's own state lives inside SystemAudioCapture, behind its own queues and lock.
    private var systemAudioSession: SystemAudioCapture?
    
    // Owns a ScreenCaptureKit audio capture session and runs it entirely off the main actor.
    // Its state is either immutable (`outputURL`, `id`) or guarded by `stateLock`/`writeQueue`,
    // so the capture callback never races with the main actor.
    private final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
        let id = UUID()
        let outputURL: URL
        
        // Called on the main thread when the stream dies on its own
        var onError: (@Sendable (UUID, Error) -> Void)?
        
        private let writer = AudioFileWriter()
        private let captureQueue = DispatchQueue(label: "com.screencapturekit.queue", qos: .userInitiated)
        
        // `stream`, `capturing` and `cancelled` are touched from the main thread (stop/cancel) and
        // from the start-up task, so they live behind one lock.
        private let stateLock = NSLock()
        private var capturing = false
        private var cancelled = false
        private var stream: SCStream?
        private var firstBufferDate: Date?
        private var writerOpened = false   // only used on captureQueue
        
        init(outputURL: URL) {
            self.outputURL = outputURL
        }
        
        private func withState<T>(_ body: () -> T) -> T {
            stateLock.lock()
            defer { stateLock.unlock() }
            return body()
        }
        
        var isCapturing: Bool { withState { capturing } }
        
        // When the first samples arrived - used to line this capture up with the microphone
        var firstBufferAt: Date? { withState { firstBufferDate } }
        
        // Starts capture. The completion runs on the main thread.
        func start(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
            Task {
                do {
                    let availableContent = try await SCShareableContent.current
                    guard let display = availableContent.displays.first else {
                        throw SystemAudioError.noDisplay
                    }
                    
                    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    
                    let configuration = SCStreamConfiguration()
                    configuration.capturesAudio = true
                    configuration.excludesCurrentProcessAudio = true
                    configuration.sampleRate = 44100
                    configuration.channelCount = 2
                    // Minimal video surface: we only want the audio stream
                    configuration.width = 2
                    configuration.height = 2
                    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                    
                    let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
                    
                    // Refuse to start if the session was cancelled while awaiting the content
                    let shouldStart = withState { () -> Bool in
                        guard !cancelled else { return false }
                        stream = newStream
                        capturing = true
                        return true
                    }
                    guard shouldStart else {
                        await completion(.failure(SystemAudioError.cancelled))
                        return
                    }
                    
                    try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
                    try await newStream.startCapture()
                    
                    // The session may have been stopped while startCapture() was awaiting
                    if withState({ cancelled }) {
                        await Self.stopQuietly(newStream)
                        await completion(.failure(SystemAudioError.cancelled))
                        return
                    }
                    await completion(.success(()))
                } catch {
                    await completion(.failure(error))
                }
            }
        }
        
        // Stops capture, closes the file and reports its size to the main thread.
        func stop(completion: @escaping @MainActor (Int) -> Void) {
            let streamToStop = withState { () -> SCStream? in
                cancelled = true
                capturing = false
                let current = stream
                stream = nil
                return current
            }
            
            let finish = {
                let dropped = self.writer.close()
                if dropped > 0 {
                    print("WARNING: dropped \(dropped) system audio buffers while writing")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: self.outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
                Task { @MainActor in completion(size) }
            }
            
            guard let streamToStop = streamToStop else {
                finish()
                return
            }
            streamToStop.stopCapture { _ in
                finish()
            }
        }
        
        // Tears the session down without keeping anything (used when start-up failed)
        func cancel() {
            let streamToStop = withState { () -> SCStream? in
                cancelled = true
                capturing = false
                let current = stream
                stream = nil
                return current
            }
            
            let cleanup = {
                self.writer.close()
                try? FileManager.default.removeItem(at: self.outputURL)
            }
            
            guard let streamToStop = streamToStop else {
                cleanup()
                return
            }
            streamToStop.stopCapture { _ in
                cleanup()
            }
        }
        
        private static func stopQuietly(_ stream: SCStream) async {
            do {
                try await stream.stopCapture()
            } catch {
                print("Error stopping capture: \(error.localizedDescription)")
            }
        }
        
        // MARK: SCStreamDelegate
        
        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            onError?(id, error)
        }
        
        // MARK: SCStreamOutput
        
        nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio,
                  isCapturing,
                  let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            
            let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer, format: format) else { return }
            
            if !writerOpened {
                withState { if firstBufferDate == nil { firstBufferDate = Date() } }
                do {
                    try writer.open(url: outputURL,
                                    settings: Self.audioFileSettings(for: format),
                                    format: format,
                                    capacity: pcmBuffer.frameCapacity)
                    writerOpened = true
                } catch {
                    print("ERROR creating system audio file: \(error.localizedDescription)")
                    withState { capturing = false }
                    return
                }
            }
            
            writer.write(pcmBuffer)
        }
        
        // Copies the captured samples into an AVAudioPCMBuffer (ScreenCaptureKit audio is PCM)
        private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }
            buffer.frameLength = frameCount
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
            guard status == noErr else {
                print("Could not copy system audio samples (status \(status))")
                return nil
            }
            return buffer
        }
        
        private static func audioFileSettings(for format: AVAudioFormat) -> [String: Any] {
            [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        }
    }
    
    enum SystemAudioError: LocalizedError {
        case noDisplay
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available for capture"
            case .cancelled: return "Capture session was cancelled"
            }
        }
    }
    
    // Recording state
    private(set) var isRecording = false
    private(set) var isPlaying = false
    
    // Selected audio source
    private var selectedSource: AudioSource = .microphone
    
    // File URLs for recordings
    private var recordingURL: URL?
    private var micRecordingURL: URL
    private var systemAudioRecordingURL: URL
    
    // Completion handlers
    var recordingStateChanged: (@MainActor (Bool) -> Void)?
    var playbackStateChanged: (@MainActor (Bool) -> Void)?
    // Reports work that is neither recording nor playback, e.g. mixing a combined recording
    var statusChanged: (@MainActor (String) -> Void)?
    
    // Trips the running offline mix when the user asks to stop while it is mixing
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private var mixCancellation: CancellationFlag?
    private var mixingTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    
    override init() {
        // Working files live in the temporary directory until the user saves them
        let tempPath = FileManager.default.temporaryDirectory
        self.micRecordingURL = tempPath.appendingPathComponent("mic_recording.m4a")
        self.systemAudioRecordingURL = tempPath.appendingPathComponent("system_audio_recording.m4a")
        self.combinedMicURL = tempPath.appendingPathComponent("combined_mic.m4a")
        
        // Default to microphone recording URL
        self.recordingURL = self.micRecordingURL
        
        super.init()
        
        // Discard anything left over from a previous run, and again when the app quits
        AudioRecorder.cleanupUnsavedRecordings()
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            AudioRecorder.cleanupUnsavedRecordings()
            MainActor.assumeIsolated { self?.cancelMixing() }
        }
    }
    
    deinit {
        if let terminateObserver = terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }
    
    // MARK: - Unsaved Recording Cleanup
    
    // Deletes working files for recordings the user never saved. Recordings live in the
    // temporary directory until Save moves them out; the Documents entry is a leftover
    // from older builds that wrote diagnostics there.
    nonisolated static func cleanupUnsavedRecordings() {
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tempPath = fileManager.temporaryDirectory
        
        var targets = [
            documentsPath.appendingPathComponent("audio_recorder_log.txt"),
            tempPath.appendingPathComponent("mic_recording.m4a"),
            tempPath.appendingPathComponent("system_audio_recording.m4a"),
            tempPath.appendingPathComponent("combined_recording.caf")
        ]
        targets += matchingFiles(in: tempPath, prefix: "combined_recording_", pathExtension: "m4a")
        targets += matchingFiles(in: tempPath, prefix: "combined_mic", pathExtension: "m4a")
        targets += matchingFiles(in: tempPath, prefix: "combined_recording_", pathExtension: "caf")
        targets += matchingFiles(in: tempPath, prefix: "system_audio_", pathExtension: "m4a")
        targets += matchingFiles(in: tempPath, prefix: "temp_audio_", pathExtension: "m4a")
        targets += matchingFiles(in: tempPath, prefix: "temp_video_", pathExtension: "mp4")
        
        for url in targets where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                print("Cleaned up unsaved recording: \(url.path)")
            } catch {
                print("Could not clean up \(url.path): \(error.localizedDescription)")
            }
        }
    }
    
    nonisolated private static func matchingFiles(in directory: URL, prefix: String, pathExtension: String) -> [URL] {
        let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return (entries ?? []).filter {
            $0.pathExtension.caseInsensitiveCompare(pathExtension) == .orderedSame
                && $0.lastPathComponent.hasPrefix(prefix)
        }
    }
    
    func requestPermission(completion: @escaping @MainActor (Bool) -> Void) {
        // Only the microphone is requested here. Screen recording permission is handled where
        // it is actually needed (the system audio / combined paths) so the user never sees two
        // alerts for the same thing.
        AVCaptureDevice.requestAccess(for: .audio) { micPermission in
            Task { @MainActor in
                completion(micPermission)
            }
        }
    }
    
    func setAudioSource(_ source: AudioSource) {
        // Stop any ongoing recording when switching sources
        if isRecording {
            stopRecording()
        }
        
        // Update the source
        selectedSource = source
        print("Audio source set to: \(source)")
    }
    
    func startRecording() -> Bool {
        // Print diagnostics before starting
        print("Start recording requested for source: \(selectedSource)")
        printDiagnostics()
        
        if isRecording {
            print("Already recording")
            return false
        }
        
        // First, attempt to get screen capture access if needed
        if selectedSource == .systemAudio || selectedSource == .combined {
            if !CGPreflightScreenCaptureAccess() {
                print("Requesting screen capture access")
                _ = CGRequestScreenCaptureAccess()
            }
        }
        
        // Set the recording URL based on selected source
        NSLog("🟡 SELECTED SOURCE IS: \(selectedSource)")
        print("🟡 SELECTED SOURCE IS: \(selectedSource)")
        
        switch selectedSource {
        case .microphone:
            NSLog("🟡 STARTING MICROPHONE RECORDING")
            print("🟡 STARTING MICROPHONE RECORDING")
            recordingURL = micRecordingURL
            return startMicrophoneRecording()
        case .systemAudio:
            NSLog("🟡 STARTING SYSTEM AUDIO RECORDING")
            print("🟡 STARTING SYSTEM AUDIO RECORDING")
            recordingURL = systemAudioRecordingURL
            return startSystemAudioRecording()
        case .combined:
            NSLog("🟡 STARTING COMBINED RECORDING")
            print("🟡 STARTING COMBINED RECORDING")
            return startCombinedRecording()
        }
    }
    
    // MARK: - Diagnostics
    
    func printDiagnostics() {
        print("\n=== AUDIO RECORDER DIAGNOSTICS ===")
        print("Selected audio source: \(selectedSource)")
        print("Is recording: \(isRecording)")
        print("Is playing: \(isPlaying)")
        print("Recording URL: \(recordingURL?.path ?? "Not set")")
        print("File exists: \(recordingURL != nil ? FileManager.default.fileExists(atPath: recordingURL!.path) : false)")
        
        if selectedSource == .combined {
            print("Combined recording mixes the microphone and the system audio offline")
        }
        print("===================================\n")
    }
    
    private func startMicrophoneRecording() -> Bool {
        guard let url = recordingURL else {
            print("No recording URL available")
            return false
        }
        guard startMicrophoneRecorder(at: url) else { return false }
        isRecording = true
        recordingStateChanged?(true)
        return true
    }
    
    // Starts an AVAudioRecorder on `url`. AVAudioRecorder writes straight to disk and never routes the
    // microphone to the speakers, which is why the microphone-only and combined paths stay echo-free.
    private func startMicrophoneRecorder(at url: URL) -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            try? FileManager.default.removeItem(at: url)
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.prepareToRecord()
            return audioRecorder?.record() == true
        } catch {
            print("Error starting microphone recording: \(error)")
            return false
        }
    }
    
    private func startSystemAudioRecording() -> Bool {
        return startSystemAudioRecordingWithScreenCaptureKit()
    }
    
    // Combined recording: microphone + system audio captured side by side, mixed offline on stop.
    // Neither capture touches the output device, so there is no monitoring and therefore no echo.
    private func startCombinedRecording() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("Microphone permission not granted")
            return false
        }
        
        // Starting the system audio capture also requests screen recording permission when needed
        guard beginSystemAudioCapture() else { return false }
        
        guard startMicrophoneRecorder(at: combinedMicURL) else {
            print("Could not start the microphone for combined recording")
            endSystemAudioCapture { _, _ in }
            return false
        }
        combinedMicStart = Date()
        
        isRecording = true
        recordingStateChanged?(true)
        return true
    }
    
    // Stops both captures and mixes them into a single file
    private func stopCombinedRecording() {
        audioRecorder?.stop()
        let micURL = combinedMicURL
        let micStart = combinedMicStart ?? Date()
        
        endSystemAudioCapture { [weak self] sysURL, sysStart in
            self?.mixCombined(micURL: micURL, micStart: micStart, sysURL: sysURL, sysStart: sysStart)
        }
    }
    
    // Mixes the captures into the finished file. Either half may be missing - a recording that only
    // has the microphone is still worth keeping.
    private func mixCombined(micURL: URL, micStart: Date, sysURL: URL?, sysStart: Date?) {
        var sources: [AudioMixdown.Source] = []
        if fileSize(of: micURL) > 1000 {
            sources.append(.init(url: micURL, offset: 0))
            if let sysURL = sysURL {
                // The system audio capture starts later, so it is delayed by exactly that difference
                let offset = max(0, (sysStart ?? micStart).timeIntervalSince(micStart))
                print(String(format: "Mixdown: system audio offset %.3fs", offset))
                sources.append(.init(url: sysURL, offset: offset))
            } else {
                print("WARNING: no system audio was captured - mixing the microphone only")
            }
        } else if let sysURL = sysURL {
            print("WARNING: no microphone audio was captured - mixing the system audio only")
            sources.append(.init(url: sysURL, offset: 0))
        }
        
        guard !sources.isEmpty else {
            print("WARNING: nothing was captured for the combined recording")
            self.cleanUpCombinedInputs(micURL: micURL, sysURL: sysURL)
            isMixingCombined = false
            resetRecordingState()
            return
        }
        statusChanged?("Mixing recording...")
        
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("combined_recording_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8))")
            .appendingPathExtension("m4a")
        let flag = CancellationFlag()
        mixCancellation = flag
        
        mixingTask = Task {
            let mixed = await AudioRecorder.mixdown(sources,
                                                    to: destination,
                                                    shouldCancel: { flag.isCancelled })
            self.mixCancellation = nil
            self.mixingTask = nil
            self.combinedMicStart = nil
            self.cleanUpCombinedInputs(micURL: micURL, sysURL: sysURL)
            
            if let mixed = mixed {
                self.recordingURL = mixed
                print("Combined recording ready: \(mixed.path)")
            } else {
                print("WARNING: combined mixdown failed or was cancelled")
                // Never leave a half-written mix behind
                try? FileManager.default.removeItem(at: destination)
                self.recordingURL = nil
            }
            self.isMixingCombined = false
            self.resetRecordingState()
        }
    }
    
    private func cleanUpCombinedInputs(micURL: URL, sysURL: URL?) {
        try? FileManager.default.removeItem(at: micURL)
        if let sysURL = sysURL {
            try? FileManager.default.removeItem(at: sysURL)
        }
    }
    
    private func fileSize(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }
    
    // Abandons a running mix (used when the user stops again while it is mixing, and on quit)
    private func cancelMixing() {
        guard isMixingCombined else { return }
        print("Cancelling the combined mix")
        mixCancellation?.cancel()
    }
    
    // Runs the offline mix away from the main actor
    nonisolated private static func mixdown(_ sources: [AudioMixdown.Source],
                                           to destination: URL,
                                           shouldCancel: @escaping @Sendable () -> Bool) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                try AudioMixdown.mix(sources, to: destination, shouldCancel: shouldCancel)
                return destination
            } catch {
                print("Combined mix failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
    
    private func startSystemAudioRecordingWithScreenCaptureKit() -> Bool {
        guard beginSystemAudioCapture() else { return false }
        isRecording = true
        recordingURL = systemAudioRecordingURL  // Final working path, set once capture is promoted
        return true
    }
    
    // Starts a ScreenCaptureKit capture session, asking for screen recording permission when needed.
    // Returns false when permission is missing (after prompting) or the session could not start.
    private func beginSystemAudioCapture() -> Bool {
        print("\n=== SYSTEM AUDIO RECORDING DEBUG ===")
        
        guard CGPreflightScreenCaptureAccess() else {
            print("Screen recording permission not granted - requesting access")
            CGRequestScreenCaptureAccess()
            let alert = NSAlert()
            alert.messageText = "Screen Recording Permission Required"
            alert.informativeText = "Mix-Recording needs screen recording permission to capture system audio. Please grant this permission in System Settings > Privacy & Security > Screen Recording."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            recordingStateChanged?(false)
            return false
        }
        
        // Unique working file: an in-progress capture never clobbers a previous unsaved one
        let tempDir = FileManager.default.temporaryDirectory
        let uniqueID = UUID().uuidString.prefix(8)
        let timestamp = Int(Date().timeIntervalSince1970)
        let outputURL = tempDir.appendingPathComponent("system_audio_\(timestamp)_\(uniqueID).m4a")
        
        let session = SystemAudioCapture(outputURL: outputURL)
        let sessionID = session.id
        session.onError = { [weak self] _, error in
            Task { @MainActor in
                guard let self = self, self.systemAudioSession?.id == sessionID else { return }
                print("System audio stream stopped with error: \(error.localizedDescription)")
                self.finishSystemAudioRecording(promote: true, generation: sessionID)
            }
        }
        
        systemAudioSession = session
        
        session.start { [weak self] result in
            guard let self = self, self.systemAudioSession?.id == sessionID else { return }
            switch result {
            case .success:
                print("Successfully started ScreenCaptureKit recording")
                self.recordingStateChanged?(true)
            case .failure(let error):
                print("ERROR starting ScreenCaptureKit recording: \(error.localizedDescription)")
                self.systemAudioSession = nil
                session.cancel()
                self.abortRecording()
            }
        }
        
        return true
    }
    
    // Stops the capture session and hands back the working file (nil when nothing usable was
    // captured) plus the time its first samples arrived, so several captures can be lined up.
    private func endSystemAudioCapture(completion: @escaping @MainActor (URL?, Date?) -> Void) {
        guard let session = systemAudioSession else {
            completion(nil, nil)
            return
        }
        systemAudioSession = nil
        
        session.stop { size in
            guard size > 1000 else {
                print("WARNING: system audio recording is empty or was not captured - discarding")
                try? FileManager.default.removeItem(at: session.outputURL)
                completion(nil, session.firstBufferAt)
                return
            }
            completion(session.outputURL, session.firstBufferAt)
        }
    }
    
    // Cleans up a failed start: stop the microphone and forget the captures
    private func abortRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        try? FileManager.default.removeItem(at: combinedMicURL)
        resetRecordingState()
    }

    // System audio only: promote the working file to the stable name
    private func stopSystemAudioRecording() {
        endSystemAudioCapture { [weak self] url, _ in
            guard let self = self else { return }
            defer { self.resetRecordingState() }
            guard let url = url else { return }
            
            let target = self.systemAudioRecordingURL
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                self.recordingURL = target
                print("System audio recording finished: \(target.path)")
            } catch {
                // Fall back to the unique file rather than losing the recording
                print("Could not promote recording to \(target.path): \(error.localizedDescription)")
                self.recordingURL = url
            }
        }
    }
    
    // Returns the recorder to a usable state without touching a session that may already be gone
    private func resetRecordingState() {
        isRecording = false
        recordingStateChanged?(false)
    }
    
    func stopRecording() {
        if isRecording {
            // Stop based on which recording method is active
            switch selectedSource {
            case .microphone:
                // Stop microphone recording
                audioRecorder?.stop()
                isRecording = false
                recordingStateChanged?(false)
                
            case .systemAudio:
                // Stop system audio recording with our new approach
                stopSystemAudioRecording()
                
            case .combined:
                // Stop both captures and mix them (the mix runs in the background)
                if isMixingCombined {
                    // Pressing stop again abandons the mix instead of silently doing nothing
                    cancelMixing()
                    return
                }
                isMixingCombined = true
                stopCombinedRecording()
            }
        }
    }
    
    // Called when the capture stream dies on its own or the session must be abandoned
    private func finishSystemAudioRecording(promote: Bool, generation sessionID: UUID) {
        guard let session = systemAudioSession, session.id == sessionID else {
            print("Ignoring teardown for a session that is no longer current")
            return
        }
        systemAudioSession = nil
        
        // Combined recording: the system half died, so stop the microphone too and mix whatever both
        // managed to capture instead of silently losing the microphone track.
        if selectedSource == .combined {
            print("System audio capture ended unexpectedly - finishing the combined recording")
            audioRecorder?.stop()
            let micURL = combinedMicURL
            let micStart = combinedMicStart ?? Date()
            isMixingCombined = true
            session.stop { [weak self] size in
                guard let self = self else { return }
                self.mixCombined(micURL: micURL,
                                 micStart: micStart,
                                 sysURL: size > 1000 ? session.outputURL : nil,
                                 sysStart: session.firstBufferAt)
            }
            return
        }
        
        if promote {
            session.stop { [weak self] size in
                guard let self = self else { return }
                defer { self.resetRecordingState() }
                guard size > 1000 else {
                    try? FileManager.default.removeItem(at: session.outputURL)
                    return
                }
                let target = self.systemAudioRecordingURL
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.moveItem(at: session.outputURL, to: target)
                    self.recordingURL = target
                } catch {
                    self.recordingURL = session.outputURL
                }
            }
        } else {
            session.cancel()
            resetRecordingState()
        }
    }
    
    func startPlayback() -> Bool {
        if isPlaying {
            print("Already playing")
            return false
        }
        
        print("\n=== PLAYBACK DEBUG ===")
        print("Attempting to play: \(recordingURL?.path ?? "No recording URL")")
        
        // Standard playback for microphone and system audio recordings
        guard let url = recordingURL else {
            print("❌ ERROR: No recording URL available")
            return false
        }
        
        // First check if the file exists at the recording URL
        if !FileManager.default.fileExists(atPath: url.path) {
            print("❌ ERROR: No recording found at \(url.path)")
            return false
        }
        
        // Check file size
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber {
                print("File size: \(size.intValue) bytes")
                if size.intValue < 1000 {
                    print("WARNING: File is suspiciously small, may not contain audio")
                }
            }
        } catch {
            print("Error checking file size: \(error)")
        }
        
        do {
            // Create audio player
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            
            // Start playback
            if audioPlayer?.play() == true {
                isPlaying = true
                playbackStateChanged?(true)
                return true
            } else {
                print("Failed to start playback")
            }
        } catch {
            print("Error starting playback: \(error)")
        }
        
        return false
    }
    
    func stopPlayback() {
        if !isPlaying {
            return
        }
        
        // All sources play through AVAudioPlayer now
        if let player = audioPlayer {
            player.stop()
            audioPlayer = nil
        }
        
        // Update state regardless of playback method
        isPlaying = false
        playbackStateChanged?(false)
    }
    
    // Extension of the current recording, exposed so the save panel offers a container that matches the file
    var recordingFileExtension: String {
        recordingURL?.pathExtension ?? "m4a"
    }
    
    // Default file name for the save panel, per recording source
    var suggestedSaveFileName: String {
        switch selectedSource {
        case .microphone: return "mic-recording.m4a"
        case .systemAudio: return "sys-recording.m4a"
        case .combined: return "mix-recording.m4a"
        }
    }
    
    // Writes `source` to `destination` without ever leaving the user without a file: the new
    // recording is staged next to the destination and then swapped in.
    private func stageAndReplace(_ source: URL, at destination: URL, move: Bool) throws {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: destination.path) else {
            if move {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
            return
        }
        
        // Stage inside the destination directory so the swap below is a rename, not a copy
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).incoming-\(UUID().uuidString.prefix(8))")
        if move {
            try fileManager.moveItem(at: source, to: staging)
        } else {
            try fileManager.copyItem(at: source, to: staging)
        }
        
        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } catch {
            // The recording must survive a failed swap: put a moved file back where it came from
            // (a copy is simply discarded, the original is untouched).
            if move {
                try? fileManager.moveItem(at: staging, to: source)
            } else {
                try? fileManager.removeItem(at: staging)
            }
            throw error
        }
    }
    
    func saveRecording(to url: URL, completion: @escaping @MainActor (Bool) -> Void) {
        do {
            guard let sourceURL = recordingURL else {
                print("No recording URL available to save")
                completion(false)
                return
            }
            
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                // Unsaved recordings live in the temporary directory and are moved out on save.
                // A recording that was already saved once is copied instead, so re-saving does
                // not destroy the copy that is already on disk.
                let isWorkingFile = sourceURL.path.hasPrefix(FileManager.default.temporaryDirectory.path)
                try stageAndReplace(sourceURL, at: url, move: isWorkingFile)
                
                if isWorkingFile {
                    // Playback and any later save now refer to the saved file
                    recordingURL = url
                }
                
                completion(true)
            } else {
                print("No recording found to save at \(sourceURL.path)")
                completion(false)
            }
        } catch {
            print("Error saving recording: \(error)")
            completion(false)
        }
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                print("Recording failed")
            }
            // In combined mode the microphone is only one of two captures; the recording state is
            // owned by the mixed result, so don't clear it here.
            guard self.selectedSource != .combined else { return }
            self.isRecording = false
            self.recordingStateChanged?(false)
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("Recording error: \(error)")
            }
            guard self.selectedSource != .combined else { return }
            self.isRecording = false
            self.recordingStateChanged?(false)
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.playbackStateChanged?(false)
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("Playback error: \(error)")
            }
            self.isPlaying = false
            self.playbackStateChanged?(false)
        }
    }
}
