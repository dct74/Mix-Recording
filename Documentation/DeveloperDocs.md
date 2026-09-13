# Mix-Recording Developer Documentation

## Overview

This documentation provides detailed technical information for developers working with the Mix-Recording codebase. It covers implementation details, class structures, key methods, and best practices for maintenance and extension.

## Table of Contents

1. [Project Structure](#project-structure)
2. [Core Classes](#core-classes)
3. [System Audio Recording Implementation](#system-audio-recording-implementation)
4. [Microphone Recording Implementation](#microphone-recording-implementation)
5. [Error Handling](#error-handling)
6. [State Management](#state-management)
7. [Testing](#testing)
8. [Extension Points](#extension-points)
9. [Common Issues and Solutions](#common-issues-and-solutions)

## Project Structure

The Mix-Recording project follows a standard Swift/SwiftUI application structure with MVVM architecture:

```
Mix-Recording/
├── ContentView.swift           # Main SwiftUI view and view model
├── MixRecordingApp.swift   # App entry point
├── AudioRecorder.swift         # Core recording functionality
├── AudioFileWriter.swift       # Off-thread audio writer (preallocated buffer pool)
├── AudioMixdown.swift          # Offline mixdown for combined recordings
├── Mix-Recording/
│   ├── Assets.xcassets         # App icon and accent color
│   └── Mix-Recording.entitlements
└── Info.plist                  # Permission usage descriptions
```

## Core Classes

### AudioRecorder

The `AudioRecorder` class is the heart of the application, handling all audio recording operations.

#### Key Properties

```swift
// Recording state properties
private(set) var isRecording = false
private(set) var isPlaying = false
private var recordingURL: URL?

// Recording components
private var audioRecorder: AVAudioRecorder?
private var audioPlayer: AVAudioPlayer?

// ScreenCaptureKit properties (iOS 13.0+)
private var screenCaptureManager: Any? // Type erased container for version-specific code
```

#### Primary Public Methods

```swift
// Start recording with specified source
func startRecording(source: AudioSource) -> Bool

// Stop current recording
func stopRecording()

// Play recorded audio
func playRecording() -> Bool

// Stop playback
func stopPlayback()

// Save recording to specified URL
func saveRecording(to destination: URL, completion: @escaping (Bool) -> Void)
```

### ScreenCaptureManager

This private nested class handles all ScreenCaptureKit-specific functionality for macOS 13.0+.

```swift
@available(macOS 13.0, *)
private class ScreenCaptureManager: NSObject, SCStreamDelegate {
    var stream: SCStream?
    var audioFile: AVAudioFile?
    var captureQueue = DispatchQueue(label: "com.screencapturekit.queue", qos: .userInitiated)
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Error handling
    }
}
```

## System Audio Recording Implementation

### Overview

System audio recording uses a sophisticated pipeline to capture audio through ScreenCaptureKit:

1. User calls `startRecording(source: .systemAudio)`
2. `startSystemAudioRecording()` checks OS version compatibility
3. For macOS 13.0+, `startSystemAudioRecordingWithScreenCaptureKit()` is called
4. Screen recording permission is verified
5. ScreenCaptureManager is created and configured
6. SCStream is initialized with minimal video settings and audio enabled
7. Audio samples are captured via SCStreamOutput protocol
8. CMSampleBuffers are processed through AVAssetWriter for reliable encoding
9. Final audio is written to the target file

### Implementation Details

#### Version Detection

```swift
func startSystemAudioRecording() -> Bool {
    if #available(macOS 13.0, *) {
        return startSystemAudioRecordingWithScreenCaptureKit()
    } else {
        return startLegacySystemAudioRecording()
    }
}
```

#### Permission Handling

```swift
// Check screen recording permission
let hasPermission = CGPreflightScreenCaptureAccess()
if !hasPermission {
    // Request permission and guide user
    CGRequestScreenCaptureAccess()
    // Show alert with instructions
}
```

#### Stream Configuration

```swift
// Configure stream with minimal video, focused on audio
let configuration = SCStreamConfiguration()
configuration.capturesAudio = true
configuration.excludesCurrentProcessAudio = true
configuration.sampleRate = 44100
configuration.channelCount = 2
configuration.width = 2  // Minimum size to satisfy API requirements
configuration.height = 2
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
```

#### Audio Sample Processing

The most critical part of the implementation is in the `SCStreamOutput` protocol extension:

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, 
          let manager = screenCaptureManager as? ScreenCaptureManager,
          let audioFile = manager.audioFile else { return }
    
    // The sample buffer is copied into an AVAudioPCMBuffer (CMSampleBufferCopyPCMDataIntoAudioBufferList)
    // and written on a dedicated serial queue. The output file is created from the first buffer so
    // its processing format matches the capture stream exactly - no temporary file is involved.
    manager.writeQueue.async {
        // create manager.audioFile lazily, then try manager.audioFile?.write(from: pcmBuffer)
    }
}
```

## Microphone Recording Implementation

Microphone recording uses standard AVFoundation APIs:

1. Configure AVAudioSession for recording
2. Set up AVAudioRecorder with appropriate settings
3. Start recording to a temporary file
4. Process recorded audio when stopping

```swift
private func startMicrophoneRecording() -> Bool {
    let recordSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44100.0,
        AVNumberOfChannelsKey: 2,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]
    
    // Create recorder and start recording
    do {
        audioRecorder = try AVAudioRecorder(url: micRecordingURL, settings: recordSettings)
        audioRecorder?.record()
        return true
    } catch {
        // Error handling
        return false
    }
}
```

## Error Handling

The application implements comprehensive error handling at multiple levels:

1. **Function-level error handling**: Each method returns a Bool success indicator
2. **Do-catch blocks**: For operations that might throw errors
3. **Delegate error methods**: For asynchronous errors via delegates
4. **Standard output**: Diagnostic messages are printed while developing; the app does not write a log file

## State Management

State is managed through a combination of properties and callbacks:

```swift
// State properties
private(set) var isRecording = false
private(set) var isPlaying = false

// Callback closures for state updates
var recordingStateChanged: ((Bool) -> Void)?
var playbackStateChanged: ((Bool) -> Void)?
```

These callbacks allow the ViewModel to react to state changes and update the UI accordingly.

## Testing

When testing the application, focus on these critical areas:

1. **Permission handling**: Verify the app correctly requests and responds to screen recording permissions
2. **Version compatibility**: Test on different macOS versions to ensure appropriate fallback behavior
3. **Error recovery**: Test error scenarios to ensure the app recovers gracefully
4. **Audio quality**: Verify the recorded audio plays back correctly

## Extension Points

To extend the application with new features, consider these primary extension points:

### 1. Adding New Audio Sources

Extend the `AudioSource` enum and implement corresponding recording methods:

```swift
enum AudioSource {
    case microphone
    case systemAudio
    case both
    // Add new source types here
}
```

### 2. Enhanced Audio Processing

Add audio effects or processing by modifying the `stopRecording` method to apply processing before saving.

### 3. Additional Output Formats

Implement new output formats by adding conversion methods in the `saveRecording` function.

## Common Issues and Solutions

### 1. No System Audio Recorded

**Symptoms**: App records without errors but no system audio is heard on playback.

**Solution**: 
- Verify screen recording permission is granted in System Settings
- Ensure audio is playing on the system during recording
- Check that `excludesCurrentProcessAudio` is set correctly

### 2. Permission Denied Errors

**Symptoms**: Console shows permission errors when starting recording.

**Solution**:
- Check System Settings > Privacy & Security > Screen Recording
- Ensure the app is allowed screen recording permission
- Restart the app after granting permission

### 3. Stream Initialization Failures

**Symptoms**: ScreenCaptureKit fails to start stream with error 1003.

**Solution**:
- Verify system resources aren't constrained by other capture apps
- Use direct references to stream objects (not optionals) when starting capture
- Ensure stream configuration parameters meet minimum requirements

## Conclusion

The Mix-Recording implementation demonstrates how to build a robust audio recording solution that handles the complexities of system audio capture on macOS. By carefully managing version compatibility, error handling, and using Apple's recommended APIs, the application provides reliable recording functionality across different macOS versions.
