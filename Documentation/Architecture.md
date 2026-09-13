# Mix-Recording Architecture

## System Overview

Mix-Recording is a macOS application built with Swift and SwiftUI that provides audio recording capabilities from two primary sources:

1. **Microphone recording** - using standard AVFoundation APIs
2. **System audio recording** - using ScreenCaptureKit (macOS 13.0+) with legacy fallback options

The application follows an MVVM (Model-View-ViewModel) architecture pattern with clear separation of concerns:

- **Models**: Audio processing and file management functionality
- **ViewModels**: AudioRecorderViewModel manages recording state and user actions
- **Views**: SwiftUI interfaces for user interaction

## Core Components

### AudioRecorder Class

This is the central class that handles all audio recording functionality. Key features include:

- Audio source management (microphone, system audio, or both)
- Recording state management
- File I/O and format conversions
- Platform-specific implementations for different macOS versions

### System Audio Recording Implementation

The most complex feature is system audio recording, which requires special handling due to macOS security and API constraints. The implementation includes:

#### Version-Specific Containment Strategy

Since Swift doesn't allow `@available` attributes on stored properties, we use a containment class approach:

```swift
@available(macOS 13.0, *)
private class ScreenCaptureManager: NSObject, SCStreamDelegate {
    var stream: SCStream?
    var audioFile: AVAudioFile?
    var captureQueue = DispatchQueue(label: "com.screencapturekit.queue", qos: .userInitiated)
    
    // SCStreamDelegate implementation
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
        print("Stream stopped with error: \(error.localizedDescription)")
    }
}
```

This allows us to encapsulate all macOS 13.0+ specific functionality while maintaining compatibility with older versions.

#### Recording Initiation Process

1. **Entry point**: `startSystemAudioRecording()` method checks OS version and routes to appropriate implementation
2. **Permission verification**: Uses `CGPreflightScreenCaptureAccess()` to verify screen recording permissions
3. **Stream configuration**:
   - Creates unique audio file output path with timestamp and UUID
   - Initializes `ScreenCaptureManager` to encapsulate version-specific components
   - Configures AVAudioFile for output

```swift
// Flow control for version-specific implementations
func startSystemAudioRecording() -> Bool {
    if #available(macOS 13.0, *) {
        return startSystemAudioRecordingWithScreenCaptureKit()
    } else {
        return startLegacySystemAudioRecording()
    }
}
```

#### ScreenCaptureKit Setup Sequence

1. **Display selection**: Queries `SCShareableContent.current` for available displays
2. **Content filter creation**: Configures what to capture using `SCContentFilter`
3. **Stream configuration**: Sets up audio parameters with minimal video capture
   - Uses 2x2 pixel video (minimum allowed size)
   - Configures 44.1kHz stereo audio
   - Sets appropriate frame rates and quality settings
4. **Stream initialization**: Creates `SCStream` with the filter and configuration
5. **Output handler registration**: Adds `self` as a stream output to receive audio samples
6. **Capture start**: Initiates the capture process asynchronously

#### Audio Processing Pipeline

The most critical and complex part is the audio data handling in the `SCStreamOutput` protocol implementation:

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    // We only care about audio samples
    guard type == .audio, 
          let manager = screenCaptureManager as? ScreenCaptureManager,
          let audioFile = manager.audioFile else { return }
    
    // Process audio sample buffer using AVAssetWriter approach
    do {
        // Create temp file with AVAssetWriter
        // Process sampleBuffer through AVAssetWriter
        // Read back with AVAudioFile
        // Write to final destination
    } catch {
        // Error handling
    }
}
```

The audio processing follows this sequence:

1. **Receive CMSampleBuffer**: ScreenCaptureKit provides raw audio samples
2. **Direct AVAssetWriter processing**:
   - Creates temporary file to hold audio data
   - Uses AVAssetWriter to properly encode the raw CMSampleBuffer
   - Finishes writing to ensure data is flushed
3. **Audio file conversion**:
   - Opens temporary file with AVAudioFile for reading
   - Creates AVAudioPCMBuffer to hold the entire audio content
   - Writes buffer to the final recording file
4. **Cleanup**: Removes temporary files and updates counters

This indirect approach solves the complex challenge of properly handling audio format conversion from raw ScreenCaptureKit buffers to playable audio files.

#### Recording Termination Sequence

1. **Stop command**: User initiates stop action through UI
2. **Stream termination**: Calls `stopSystemAudioRecording()` which routes to appropriate implementation
3. **Resource cleanup**:
   - Stops SCStream capture
   - Closes audio files
   - Clears references to prevent memory leaks
4. **File processing**:
   - Verifies the recorded file exists and contains audio
   - Moves the working file from the temporary directory to the stable working name
5. **State updates**: Always notifies the UI when the recording ends, even when it captured nothing

### Legacy Implementation (removed)

An earlier fallback for macOS versions before 13.0 (CGDisplayStream + AVCaptureSession) existed in this repository. It was unreachable because the project deploys to macOS 13.5, and it has been deleted.

### Error Handling and Diagnostics

The implementation includes robust error handling:

1. **Standard output logging**: Diagnostic messages are printed while developing; the app does not write a log file
2. **Detailed error captures**: All errors include specific error domains and codes
3. **Recovery mechanisms**: Handles permission changes, file conflicts, and stream errors

## Playback Implementation

Audio playback is handled by AVAudioPlayer with these key steps:

1. **File preparation**: Opens the recorded file for playback
2. **Player configuration**: Sets up AVAudioPlayer with appropriate settings
3. **Playback controls**: Start, pause, and stop functionality
4. **Completion handling**: Uses AVAudioPlayerDelegate to detect playback end

## File Management

The app implements careful file management to prevent conflicts and ensure data integrity:

1. **Unique filenames**: Uses timestamps and UUIDs to prevent collisions
2. **Temporary storage**: All recordings (AAC `.m4a`) stay in FileManager.default.temporaryDirectory until the user saves them
3. **Save**: Moves the working file to the location the user picks (defaults to ~/Music)
4. **Cleanup**: Unsaved working files are deleted on quit and on the next launch

## Security and Permissions

System audio recording requires careful permission handling:

1. **Screen Recording permission**: Required by macOS for system audio access
2. **Permission verification**: Uses CGPreflightScreenCaptureAccess()
3. **Permission requests**: Implements CGRequestScreenCaptureAccess() with user guidance
4. **Settings assistance**: Helps users open System Settings for permission changes

## User Interface Integration

The MVVM architecture allows clean separation between recording logic and UI:

1. **State propagation**: Uses callback closures to notify UI of state changes
2. **Progress updates**: Recording state reflected in UI immediately
3. **Error presentation**: User-friendly error messages and guidance

## Optimization Strategies

The implementation includes several performance optimizations:

1. **Minimal video capture**: Uses smallest allowed dimensions (2x2 pixels)
2. **Queue management**: Dedicated dispatch queues for audio processing
3. **Memory efficiency**: Proper cleanup of temporary resources
4. **Background processing**: Audio conversion happens off the main thread

## Technical Challenges Overcome

Several significant technical challenges were solved:

1. **ScreenCaptureKit integration**: Properly handling the complex API
2. **Audio buffer processing**: Converting raw CMSampleBuffer to playable audio
3. **Version compatibility**: Supporting different macOS versions
4. **Permission management**: Properly handling macOS security requirements
5. **Error recovery**: Building resilient error handling and recovery mechanisms

## Conclusion

The Mix-Recording architecture demonstrates a sophisticated approach to audio capture on macOS, particularly for system audio recording which requires navigating complex API constraints and security requirements. The implementation follows best practices for Swift development, error handling, and resource management while providing a smooth user experience across different macOS versions.
