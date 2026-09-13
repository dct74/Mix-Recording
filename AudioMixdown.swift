import AVFoundation

// Mixes several recorded files into a single AAC `.m4a`, entirely offline.
//
// Offline rendering (AVAudioEngine's manual rendering mode) never touches the audio hardware, so
// nothing is played to the speakers. That is what lets combined recording keep the microphone out of
// the output path: no monitoring means the microphone cannot re-record its own delayed signal, which
// is the acoustic feedback loop (an echo) users hear when the mix is monitored through speakers.
enum AudioMixdown {
    struct Source: Sendable {
        let url: URL
        // Seconds to delay this source so several streams line up on one timeline (captures never
        // start at exactly the same instant).
        let offset: TimeInterval
    }
    
    enum MixdownError: LocalizedError {
        case noSources
        case renderFailed
        case cancelled
        
        var errorDescription: String? {
            switch self {
            case .noSources: return "No recordings to mix"
            case .renderFailed: return "The offline mix could not be rendered"
            case .cancelled: return "The mix was cancelled"
            }
        }
    }
    
    static let outputSampleRate: Double = 48000
    static let outputChannels: AVAudioChannelCount = 2
    
    // Mixes `sources` into `destination` (AAC .m4a). Sources may differ in sample rate and channel
    // count; the mixer converts them. `shouldCancel` is polled between render blocks so a long mix
    // can be abandoned.
    static func mix(_ sources: [Source],
                    to destination: URL,
                    shouldCancel: @escaping @Sendable () -> Bool = { false }) throws {
        guard !sources.isEmpty else { throw MixdownError.noSources }
        
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: outputChannels)!
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        
        var players: [AVAudioPlayerNode] = []
        var totalFrames: AVAudioFramePosition = 0
        
        for source in sources {
            let file = try AVAudioFile(forReading: source.url)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: mixer, format: file.processingFormat)
            
            // Convert the offset and the file length into output-rate frames
            let offsetFrames = AVAudioFramePosition(max(0, source.offset) * outputSampleRate)
            let durationFrames = AVAudioFramePosition(Double(file.length) * outputSampleRate / file.processingFormat.sampleRate)
            totalFrames = max(totalFrames, offsetFrames + durationFrames)
            
            // Mixing several near-full-scale sources can clip, so give each one a little headroom
            if sources.count > 1 {
                player.volume = 0.707   // -3 dB
            }
            player.scheduleFile(file, at: AVAudioTime(sampleTime: offsetFrames, atRate: outputSampleRate))
            players.append(player)
        }
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: outputChannels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        // The manual-rendering buffer is de-interleaved float, so the file's processing format must
        // match it (an interleaved processing format makes every write fail with -50).
        let output = try AVAudioFile(forWriting: destination,
                                     settings: settings,
                                     commonFormat: .pcmFormatFloat32,
                                     interleaved: false)
        
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 4096)
        try engine.start()
        players.forEach { $0.play() }
        
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        // Render a short tail past the longest source so the encoder is flushed cleanly
        let target = totalFrames + AVAudioFramePosition(outputSampleRate * 0.2)
        var rendered: AVAudioFramePosition = 0
        var stalled = 0
        
        while rendered < target {
            if shouldCancel() {
                engine.stop()
                throw MixdownError.cancelled
            }
            
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), target - rendered))
            let status = try engine.renderOffline(frames, to: buffer)
            
            switch status {
            case .success:
                // A success that produced nothing would loop forever, so it counts as a stall too
                guard buffer.frameLength > 0 else {
                    stalled += 1
                    if stalled > 100 {
                        engine.stop()
                        throw MixdownError.renderFailed
                    }
                    continue
                }
                try output.write(from: buffer)
                rendered += AVAudioFramePosition(buffer.frameLength)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                // Should not happen in offline mode; bail out rather than spin forever
                stalled += 1
                if stalled > 100 {
                    engine.stop()
                    throw MixdownError.renderFailed
                }
                continue
            case .error:
                engine.stop()
                throw MixdownError.renderFailed
            @unknown default:
                rendered = target
            }
        }
        
        engine.stop()
    }
}
