# Explaining System Audio Capture on macOS using ScreenCaptureKit

This document details the process used by the Mix-Recording application to capture system audio on macOS 13.0 and later, primarily leveraging the `ScreenCaptureKit` framework. This method requires obtaining Screen Recording permissions from the user.

## Core Approach: ScreenCaptureKit

`ScreenCaptureKit` is designed for screen recording but can be configured to capture system audio alongside video. The key is to configure the video capture minimally while enabling audio.

## Prerequisites

1.  **macOS Version**: 13.0 or later.
2.  **Screen Recording Permission**: The user must grant this permission via System Settings > Privacy & Security > Screen Recording.

## Setup and Configuration Steps

The setup involves configuring and starting an `SCStream`:

1.  **Check/Request Permissions**:
    *   Verify existing permission using `CGPreflightScreenCaptureAccess()`.
    *   If not granted, request it using `CGRequestScreenCaptureAccess()`. Guide the user to System Settings if needed.

2.  **Identify Content**: Use `SCShareableContent.current` to get a list of available displays.

3.  **Create Content Filter**: Instantiate an `SCContentFilter` targeting a specific display (e.g., the first available one). Importantly, do *not* exclude any applications if the goal is to capture all system audio.
    ```swift
    // Assuming 'mainDisplay' is an SCDisplay obtained from SCShareableContent
    let filter = SCContentFilter(display: mainDisplay, excludingApplications: [], exceptingWindows: [])
    ```

4.  **Configure Stream (`SCStreamConfiguration`)**:
    *   Enable audio capture: `configuration.capturesAudio = true`
    *   Exclude the app's own audio: `configuration.excludesCurrentProcessAudio = true`
    *   Set desired audio parameters: `configuration.sampleRate = 44100`, `configuration.channelCount = 2`
    *   **Crucially, configure minimal video**: `ScreenCaptureKit` requires video configuration. Use the smallest possible dimensions (2x2 pixels) to minimize overhead.
        ```swift
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 44100
        configuration.channelCount = 2
        
        // Minimal video settings
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30) // e.g., 30 FPS
        ```

5.  **Prepare Output File**: Create the final `AVAudioFile` where the processed audio will be stored. Use desired settings (e.g., AAC format).
    ```swift
    let outputURL = /* URL for the final recording */
    let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 2,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    let finalAudioFile = try AVAudioFile(forWriting: outputURL, settings: audioSettings)
    ```

6.  **Create `SCStream`**: Initialize the stream with the filter, configuration, and a delegate object (`SCStreamDelegate`) to handle lifecycle events.
    ```swift
    // Assuming 'delegate' conforms to SCStreamDelegate
    let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    ```

7.  **Register Audio Output Handler**: Add an object conforming to `SCStreamOutput` to handle incoming audio sample buffers. This is often the main `AudioRecorder` class itself.
    ```swift
    // Assuming 'self' conforms to SCStreamOutput and 'captureQueue' is a DispatchQueue
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
    ```

8.  **Start Capture**: Begin the asynchronous capture process.
    ```swift
    Task {
        try await stream.startCapture()
        // Recording has started
    }
    ```

## Handling Audio Data (`SCStreamOutput` Delegate)

The raw audio arrives as `CMSampleBuffer` objects in the `stream(_:didOutputSampleBuffer:ofType:)` delegate method.

An earlier version of this app wrote **each buffer** through its own `AVAssetWriter` (create a temporary file, write one buffer, finalize, read it back with `AVAudioFile`, append to the final file, delete the temp file). That is roughly 43 container write/read cycles per second, produced out-of-order writes and heavy disk churn, and has been replaced.

The current implementation:

1. **Receive buffer**: the delegate receives an audio `CMSampleBuffer` (ScreenCaptureKit delivers deinterleaved Float32 PCM).
2. **Copy out**: `CMSampleBufferCopyPCMDataIntoAudioBufferList` copies the samples into an `AVAudioPCMBuffer`, so nothing references capture-owned memory after the callback returns.
3. **Hand off**: the buffer is written on a dedicated serial queue (`ScreenCaptureManager.writeQueue`), never on the capture callback itself.
4. **Create once**: `AVAudioFile(forWriting:settings:commonFormat:interleaved:)` is created from the first buffer, so the file's processing format matches the stream exactly.
5. **Write**: `AVAudioFile.write(from:)` appends the samples; the file is closed only after the write queue has been drained.

Note that the samples are only *read* while the session is current: `isCapturing` is cleared on the write queue itself, so a late callback cannot recreate a file that has already been promoted to the finished recording.

```swift
// Inside stream(_:didOutputSampleBuffer:ofType:)

guard type == .audio, let finalAudioFile = /* reference to the main AVAudioFile */ else { return }

do {
    // Create a temporary file URL
    let tempAudioURL = FileManager.default.temporaryDirectory.appendingPathComponent("temp_audio_\(UUID().uuidString).m4a")
    
    // Setup an asset writer for the temporary file
    let assetWriter = try AVAssetWriter(outputURL: tempAudioURL, fileType: .m4a)
    let audioSettings: [String: Any] = [/* ... your desired AAC settings ... */]
    let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    writerInput.expectsMediaDataInRealTime = true // Important for live capture
    
    if assetWriter.canAdd(writerInput) {
        assetWriter.add(writerInput)
    } else {
        // Handle error: cannot add input
        return
    }
    
    // Start writing and finish asynchronously
    assetWriter.startWriting()
    assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) // Use buffer timestamp
    
    if writerInput.isReadyForMoreMediaData {
        writerInput.append(sampleBuffer)
    }
    
    writerInput.markAsFinished()
    assetWriter.finishWriting {
        // Writing to temp file complete, now read it back
        do {
            let tempAudioFile = try AVAudioFile(forReading: tempAudioURL)
            let format = tempAudioFile.processingFormat
            
            // Create buffer for the entire temp file content
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(tempAudioFile.length)) else {
                print("Could not create buffer from temp file")
                try? FileManager.default.removeItem(at: tempAudioURL)
                return
            }
            
            // Read temp file into buffer
            try tempAudioFile.read(into: buffer)
            
            // --- CRITICAL STEP: Write the processed buffer to the FINAL audio file ---
            try finalAudioFile.write(from: buffer)
            
            // Clean up the temporary file
            try? FileManager.default.removeItem(at: tempAudioURL)
            
        } catch {
            print("Error processing temp audio file: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tempAudioURL)
        }
    }
} catch {
    print("Error setting up asset writer for temp file: \(error.localizedDescription)")
}
```

This intermediate step ensures that the data written to the final `AVAudioFile` is correctly encoded and formatted as `AVAudioPCMBuffer` data, sidestepping potential issues with directly handling the raw `CMSampleBuffer` format for persistent AAC file writing.

## Stopping the Recording

1.  Call `stream.stopCapture()`.
2.  Ensure the final `AVAudioFile` is properly closed or finalized (often implicitly handled when the `AVAudioFile` object goes out of scope or is set to `nil`).
3.  Clean up references to the `SCStream`, `AVAudioFile`, and delegate objects.

## Legacy Approach (macOS < 13.0)

For older macOS versions, `ScreenCaptureKit` is unavailable. Alternative methods often involve:

*   `CGDisplayStream` (less common for audio).
*   Third-party kernel extensions or virtual audio drivers (like BlackHole or the now-deprecated Soundflower), which create virtual audio devices that can be recorded using standard `AVFoundation` APIs.
*   These methods are generally more complex to set up and may require separate installation steps for the user.

This application appears to have a `startLegacySystemAudioRecording` function as a fallback, but its specific implementation wasn't detailed in this analysis.
