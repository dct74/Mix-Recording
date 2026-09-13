import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

@MainActor
class AudioRecorderViewModel: ObservableObject {
    private let audioRecorder = AudioRecorder()
    
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var statusMessage = "Ready to record"
    @Published var selectedSource: AudioSource = .microphone
    
    init() {
        // Set up observers for recording/playback state changes. The recorder calls these on the
        // main actor, so no further hop is needed.
        audioRecorder.recordingStateChanged = { [weak self] isRecording in
            self?.isRecording = isRecording
            self?.statusMessage = isRecording ? "Recording..." : "Ready"
        }
        
        audioRecorder.playbackStateChanged = { [weak self] isPlaying in
            self?.isPlaying = isPlaying
            self?.statusMessage = isPlaying ? "Playing..." : "Ready"
        }
        
        // Work that is neither recording nor playback (e.g. mixing a combined recording)
        audioRecorder.statusChanged = { [weak self] message in
            self?.statusMessage = message
        }
    }
    
    func setAudioSource(_ source: AudioSource) {
        selectedSource = source
        audioRecorder.setAudioSource(source)
    }
    
    func toggleRecording() {
        if audioRecorder.isRecording {
            audioRecorder.stopRecording()
            return
        }
        
        // System audio needs screen recording permission. Ask the system first: that call is what
        // registers the app in System Settings, otherwise the user finds nothing to enable there.
        if selectedSource == .systemAudio || selectedSource == .combined,
           !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            presentScreenRecordingPermissionAlert()
            statusMessage = "Screen recording permission required"
            return
        }
        
        // System-audio-only recording never touches the microphone
        if selectedSource == .systemAudio {
            startRecording()
            return
        }
        
        audioRecorder.requestPermission { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.statusMessage = "Microphone access denied - enable it in System Settings > Privacy & Security > Microphone"
                return
            }
            self.startRecording()
        }
    }
    
    private func startRecording() {
        audioRecorder.setAudioSource(selectedSource)
        if !audioRecorder.startRecording() {
            statusMessage = "Could not start recording - check microphone and screen recording permissions"
        }
    }
    
    private func presentScreenRecordingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        let featureName = selectedSource == .combined ? "combined recording" : "system audio"
        alert.informativeText = "To record \(featureName), you must grant screen recording permission for this app in System Settings > Privacy & Security > Screen Recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    
    func togglePlayback() {
        if audioRecorder.isPlaying {
            audioRecorder.stopPlayback()
        } else if !audioRecorder.startPlayback() {
            statusMessage = "Nothing to play - record something first"
        }
    }
    
    func saveRecording() {
        let panel = NSSavePanel()
        // Match the container the recorder actually produced and name it per source
        let fileExtension = audioRecorder.recordingFileExtension
        panel.allowedContentTypes = UTType(filenameExtension: fileExtension).map { [$0] } ?? [.audio]
        panel.nameFieldStringValue = audioRecorder.suggestedSaveFileName
        panel.message = "Save your recording"
        panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        
        panel.begin { [weak self] result in
            if result == .OK, let url = panel.url {
                self?.audioRecorder.saveRecording(to: url) { success in
                    self?.statusMessage = success ? "Recording saved" : "Failed to save"
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AudioRecorderViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Mix-Recording")
                .font(.largeTitle)
                .padding(.top, 30)
            
            // Audio source picker
            sourcePickerView
                .padding(.horizontal)
                .padding(.top, 10)
            
            Text(viewModel.statusMessage)
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(8)
            
            HStack(spacing: 20) {
                // Record button
                recordButton
                
                // Play button
                playButton
                    
                // Save button
                saveButton
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 500, height: 300)
    }
    
    // MARK: - UI Components
    
    private var sourcePickerView: some View {
        VStack(alignment: .leading) {
            Text("Recording Source:")
                .font(.headline)
                .padding(.bottom, 5)
            
            Picker("", selection: $viewModel.selectedSource) {
                Text("Microphone Only").tag(AudioSource.microphone)
                Text("System Audio Only").tag(AudioSource.systemAudio)
                Text("Combined Recording").tag(AudioSource.combined)
            }
            .pickerStyle(SegmentedPickerStyle())
            .onChange(of: viewModel.selectedSource) { newSource in
                viewModel.setAudioSource(newSource)
            }
        }
    }
    
    // MARK: - Button Views
    
    private var recordButton: some View {
        Button(action: viewModel.toggleRecording) {
            Label(
                viewModel.isRecording ? "Stop Recording" : "Record",
                systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .frame(minWidth: 120)
        }
        .disabled(viewModel.isPlaying)
        .applyButtonStyling(color: .red)
    }
    
    private var playButton: some View {
        Button(action: viewModel.togglePlayback) {
            Label(
                viewModel.isPlaying ? "Stop Playback" : "Play",
                systemImage: viewModel.isPlaying ? "stop.circle.fill" : "play.circle.fill"
            )
            .frame(minWidth: 120)
        }
        .disabled(viewModel.isRecording)
        .applyButtonStyling(color: .blue)
    }
    
    private var saveButton: some View {
        Button(action: viewModel.saveRecording) {
            Label("Save", systemImage: "square.and.arrow.down")
                .frame(minWidth: 120)
        }
        .disabled(viewModel.isRecording || viewModel.isPlaying)
        .applyButtonStyling(color: .green)
    }
}

// Custom view extension to handle different macOS versions
extension View {
    @ViewBuilder
    func applyButtonStyling(color: Color) -> some View {
        if #available(macOS 12.0, *) {
            // Use modern styling for macOS 12.0+
            self.buttonStyle(.borderedProminent)
                .tint(color)
        } else {
            // Fallback for older macOS versions
            self.padding(6)
                .background(color)
                .cornerRadius(8)
                .foregroundColor(.white)
        }
    }
}

#Preview {
    ContentView()
}
