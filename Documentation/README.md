# Mix-Recording

A simple macOS audio recording application created with Swift.

## Features

- Record audio from the built-in microphone
- Play back recorded audio
- Save recordings as .m4a files

## Requirements

- macOS 13.5+
- Xcode 16.0+
- Swift 5.5+

## How to Use

1. Clone this repository
2. Open the project in Xcode
3. Build and run the application

## Project Structure

- `MixRecordingApp.swift`: App entry point
- `ContentView.swift`: SwiftUI view and view model
- `AudioRecorder.swift`: Recording engine (microphone, system audio, combined)
- `AudioFileWriter.swift`: Off-thread audio writer used by the recording paths
- `CombinedAudioEngine.swift`: Microphone + system audio mixing engine
- `Mix-Recording/Assets.xcassets`: App icon and accent color
- `Info.plist`: Permission usage descriptions
