# Project Scratchpad

## Background and Motivation

The user wants to add a new feature to the Mac Audio Recorder app. This feature will allow recording both microphone input and system audio simultaneously. It will be accessed via a new "Combined Recording" button on the main screen, leading to a dedicated view for this functionality. The initial focus is on implementing the UI structure and navigation, deferring the actual recording logic.

## Key Challenges and Analysis

- **UI Navigation:** Choosing the appropriate SwiftUI navigation method (e.g., `NavigationStack`, presenting a sheet, full-screen cover) to switch between the main view and the new combined recording view. Need to ensure a clear way back.
- **State Management:** How to manage the state (e.g., which view is currently active) if needed. For simple navigation, SwiftUI's built-in mechanisms might suffice initially.
- **UI Layout:** Designing the layout for the new `CombinedRecordingView` to be consistent with the existing UI but clearly indicate its purpose (recording both sources).
- **Code Structure:** Creating a new, separate SwiftUI view file (`CombinedRecordingView.swift`) promotes organization.

## High-level Task Breakdown

1.  **Task 1: Add Navigation Button to Main View**
    - Add a "Combined Recording" button to `ContentView.swift`.
    - Place it appropriately within the existing layout (e.g., below the source selection or main buttons).
    - *Success Criteria:* The button appears on the main screen when the app runs. Clicking it (initially) does nothing, or triggers placeholder navigation.
2.  **Task 2: Create Combined Recording View File**
    - Create a new SwiftUI file named `CombinedRecordingView.swift`.
    - Add a basic `struct CombinedRecordingView: View` structure.
    - *Success Criteria:* The file `CombinedRecordingView.swift` exists and compiles without errors.
3.  **Task 3: Implement Basic Navigation**
    - Choose and implement a navigation method (e.g., `NavigationStack` in the main `App` file or `ContentView`, or presenting `CombinedRecordingView` as a sheet/fullScreenCover).
    - Link the "Combined Recording" button in `ContentView` to navigate to `CombinedRecordingView`.
    - Add a "Back" button or mechanism in `CombinedRecordingView`.
    - Link the "Back" button to dismiss the view and return to `ContentView`.
    - *Success Criteria:* Clicking "Combined Recording" shows the `CombinedRecordingView`. Clicking "Back" returns to the `ContentView`.
4.  **Task 4: Add Basic UI Elements to Combined View**
    - Add a title (e.g., "Combined Recording") to `CombinedRecordingView`.
    - Add placeholder buttons: "Record Mic + System Audio", "Play", "Save". Mimic the layout of `ContentView` but adjust labels as needed.
    - Ensure the "Back" button is clearly visible and functional.
    - *Success Criteria:* The `CombinedRecordingView` displays the title, placeholder buttons, and a functional Back button.

## Project Status Board

- [x] Task 1: Add Navigation Button to Main View
- [x] Task 2: Create Combined Recording View File
- [x] Task 3: Implement Basic Navigation
- [x] Task 4: Add Basic UI Elements to Combined View

## Executor's Feedback or Assistance Requests

- Task 4 Verified by User.
- Initial UI setup for Combined Recording feature is complete.
- Ready to proceed to planning the implementation of combined recording logic.

## Lessons Learned

- Creating `.cursor` directory might require a separate step if it doesn't exist before writing a file into it.
- If `write_to_file` is used to create a new source file (e.g., `.swift`), the file might not be automatically added to the Xcode project target. It may need to be added manually in Xcode using "Add Files to Project..." to resolve "Cannot find in scope" build errors.

## --- Phase 2: Implement Combined Recording Logic ---

## Background and Motivation (Phase 2)

With the UI structure in place, the next goal is to implement the core functionality: recording microphone input and system audio simultaneously and saving the result as a single, mixed audio file. As outlined by the user, this requires a different architecture than the existing independent recording feature due to the need for concurrency, potential audio mixing, more complex state management, and higher resource usage.

**User-Provided Architectural Context Summary:**
- Need to manage two concurrent capture processes (mic + system).
- `AVAudioEngine` is likely required for managing inputs and mixing.
- Synchronization and mixing are needed for a single output file.
- State management (`isRecordingMic`, `isRecordingSystem`, etc.) is more complex.
- Higher resource usage and more intricate error handling are expected.
- A separate class or significant refactoring of `AudioRecorder` is necessary.

## Key Challenges and Analysis (Phase 2)

- **Concurrency:** Managing two audio streams simultaneously without blocking the UI.
- **AVAudioEngine Setup:** Correctly configuring the engine, input nodes (mic tap, system audio source), mixer node, and output/tap for file writing.
- **ScreenCaptureKit Integration:** Capturing system audio samples (`CMSampleBuffer`) via `SCStream` and correctly feeding them into the `AVAudioEngine` (likely via `AVAudioSourceNode`). This involves format handling and timing.
- **Mixing & Synchronization:** Ensuring both audio streams are mixed correctly with compatible formats (sample rate, bit depth) and potentially compensating for any latency differences.
- **File Writing:** Saving the mixed audio stream from the engine to a file (e.g., using `AVAudioFile` tapped from the mixer node).
- **State Management:** Implementing robust state variables to track the status of both streams and reflect it in the `CombinedRecordingView` UI.
- **Resource Management:** Properly starting, stopping, and releasing resources used by `AVAudioEngine` and `ScreenCaptureKit`.
- **Error Handling:** Managing errors from either audio stream or the engine itself.
- **Permissions:** Ensuring both Microphone and Screen Recording permissions are handled correctly for this feature.

## Proposed Approach (Phase 2)

1.  Create a new class, `CombinedAudioEngine`, dedicated to handling simultaneous mic and system audio recording using `AVAudioEngine`.
2.  Configure `AVAudioEngine` with:
    - An input node for the microphone.
    - An `AVAudioSourceNode` to receive system audio samples from `ScreenCaptureKit`.
    - An `AVAudioMixerNode` to combine the two streams.
    - An output tap on the mixer node for writing the mixed audio to a file.
3.  Use `ScreenCaptureKit` (`SCStream`) to capture system audio, extract `CMSampleBuffer`s, and schedule them onto the `AVAudioSourceNode`.
4.  Use `AVAudioFile` to write the mixed audio data obtained from the mixer's output tap.
5.  Expose state variables (e.g., `isRecording`, `statusMessage`) from `CombinedAudioEngine` (potentially via a dedicated ViewModel or directly if simple) for the `CombinedRecordingView` UI.
6.  Handle permissions checks for Microphone and Screen Recording within the new engine or view logic.

## High-level Task Breakdown (Phase 2)

*Note: These tasks are complex and may require further sub-division.* 

5.  **Task 5: Create `CombinedAudioEngine.swift` Structure**
    - Create the new file `CombinedAudioEngine.swift`.
    - Define the basic class structure `class CombinedAudioEngine`.
    - Add basic properties for `AVAudioEngine`, `AVAudioMixerNode`, etc.
    - *Success Criteria:* File exists, basic class structure compiles.
6.  **Task 6: Implement Basic `AVAudioEngine` Setup**
    - Initialize the `AVAudioEngine` instance.
    - Set up the main mixer node.
    - Implement basic start/stop methods for the engine.
    - *Success Criteria:* Engine can be initialized, started, and stopped without errors.
7.  **Task 7: Implement Microphone Input**
    - Get the default microphone input node from the engine.
    - Connect the microphone input to the main mixer.
    - Handle microphone permissions if not already globally handled.
    - *Success Criteria:* Engine runs, mic input is connected to the mixer (can be verified later with playback/file writing).
8.  **Task 8: Implement System Audio Capture (`ScreenCaptureKit`)**
    - Set up `SCShareableContent` to find available displays/windows for audio capture.
    - Create an `SCStreamConfiguration` for audio-only capture.
    - Create an `SCStream` and implement the `SCStreamOutput` delegate method (`stream(_:didOutputSampleBuffer:ofType:)`) to receive audio `CMSampleBuffer`s.
    - Handle Screen Recording permissions explicitly.
    - *Success Criteria:* Delegate method receives audio `CMSampleBuffer`s when system audio is playing; permissions prompt correctly.
9.  **Task 9: Integrate System Audio into `AVAudioEngine`**
    - Create an `AVAudioSourceNode` in the engine.
    - In the `SCStreamOutput` delegate method, convert the received `CMSampleBuffer` to the engine's processing format if necessary.
    - Schedule the audio buffers onto the `AVAudioSourceNode`.
    - Connect the `AVAudioSourceNode` to the main mixer.
    - *Success Criteria:* System audio buffers are successfully scheduled onto the source node and connected to the mixer when the engine runs.
10. **Task 10: Implement Mixed Audio File Writing**
    - Install a tap on the main mixer's output node.
    - In the tap block, receive the mixed `AVAudioPCMBuffer`.
    - Create an `AVAudioFile` for writing.
    - Write the received buffers to the `AVAudioFile`.
    - Handle file creation, closing, and potential errors.
    - *Success Criteria:* Recording creates a valid audio file containing mixed audio (verification might require playback functionality later).
11. **Task 11: Implement State Management & UI Integration**
    - Add `@Published` properties to `CombinedAudioEngine` (or a ViewModel) for `isRecording`, `statusMessage`, etc.
    - Create an instance of `CombinedAudioEngine` accessible by `CombinedRecordingView`.
    - Connect the Record/Stop button in the UI to the start/stop methods of `CombinedAudioEngine`.
    - Update the UI based on the published state variables.
    - *Success Criteria:* UI reflects the recording state (e.g., button changes, status message updates).
12. **Task 12: Refine Stop/Save Logic & Error Handling**
    - Ensure engine, stream, and file are properly stopped and cleaned up.
    - Implement saving the completed `AVAudioFile` using `NSSavePanel` (similar to `ContentView`).
    - Add basic error handling and reporting to the UI.
    - *Success Criteria:* Recording stops cleanly, save panel appears, file saves successfully, basic errors are reported.

## Project Status Board

*(Executor updates this section to track task progress)*

- [x] Task 1: Add Navigation Button to Main View
- [x] Task 2: Create Combined Recording View File
- [x] Task 3: Implement Basic Navigation
- [x] Task 4: Add Basic UI Elements to Combined View
- **--- Phase 2 ---**
- [x] Task 5: Create `CombinedAudioEngine.swift` Structure
- [x] Task 6: Implement Basic `AVAudioEngine` Setup
- [x] Task 7: Implement Microphone Input
- [x] Task 8: Implement System Audio Capture (`ScreenCaptureKit`)
- [x] Task 9: Integrate System Audio into `AVAudioEngine`
- [x] Task 10: Implement Mixed Audio File Writing
- [x] Task 11: Implement State Management & UI Integration
- [x] Task 12: Refine Stop/Save Logic & Error Handling

## Executor's Feedback or Assistance Requests

*(Executor notes progress, asks questions, or raises blockers)*
- ~~Initial plan created. Ready for Executor to start Task 1.~~
- ~~Task 1 complete: Added "Combined Recording" button to `ContentView`. Awaiting user verification.~~
- ~~Task 1 Verified by User.~~
- ~~Task 2 complete: Created `CombinedRecordingView.swift` file.~~
- ~~Task 3 complete: Implemented sheet-based navigation between `ContentView` and `CombinedRecordingView` with a Back button. Awaiting user verification.~~
- ~~Task 3 Verified by User.~~
- ~~Task 4 complete: Added title, status bar, placeholder buttons, and styled Back button to `CombinedRecordingView`. Awaiting user verification of the final UI layout.~~
- ~~**BLOCKER:** Build failed. Error: "Cannot find 'CombinedRecordingView' in scope" in `ContentView.swift`. Resolved by manually adding the file to the project target.~~
- ~~Task 4 Verified by User.~~
- ~~Initial UI setup for Combined Recording feature is complete.~~
- Planner mode: Analyzed requirements for combined recording logic based on user context.
- Outlined new approach using `CombinedAudioEngine` with `AVAudioEngine` and `ScreenCaptureKit`.
- Created task breakdown (Tasks 5-12) for implementation.
- **Task 5 complete:** Created `CombinedAudioEngine.swift` file with basic class structure.
- **Action Required:** User needs to manually add `CombinedAudioEngine.swift` to the `Mix-Recording` target in Xcode ("Add Files to Project...") to ensure it's included in the build.
- User confirmed Deployment Target updated to 13.5 and build is successful.
- **Task 6 complete:** Implemented basic `AVAudioEngine` start/stop logic.
- **Starting Task 7:** Implement Microphone Input.
- **Task 7 complete:** Connected engine's inputNode (Mic) to the mixer.
- **Starting Task 8:** Implement System Audio Capture (`ScreenCaptureKit`).
- **Task 8 complete:** Implemented SCStream setup, start/stop logic. Delegate is ready to receive system audio buffers.
- **Starting Task 9:** Integrate System Audio into `AVAudioEngine`.
- **Task 9 complete:** Connected system audio source node to mixer and implemented buffer scheduling in delegate.
- **Starting Task 10:** Implement Mixed Audio File Writing.
- **Task 10 complete:** Implemented mixer tap, AVAudioFile creation, buffer writing, and file closing.
- **Starting Task 11:** Implement State Management & UI Integration.
- **Task 11 complete:** Integrated CombinedAudioEngine with CombinedRecordingView UI state and actions.
- **Starting Task 12:** Refine Stop/Save Logic & Error Handling.
- **Task 12 complete:** Implemented save functionality using NSSavePanel and linked to UI state.

## Lessons Learned
- Creating `.cursor` directory might require a separate step if it doesn't exist before writing a file into it.
- If `write_to_file` is used to create a new source file (e.g., `.swift`), the file might not be automatically added to the Xcode project target. It may need to be added manually in Xcode using "Add Files to Project..." to resolve "Cannot find in scope" build errors.
