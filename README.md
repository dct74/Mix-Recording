# Mix-Recording

A macOS recorder for the microphone, the system audio, or both at once.

Fork of [ianpilon/Mac-Combined-Recording-working-Aug-2-20205](https://github.com/ianpilon/Mac-Combined-Recording-working-Aug-2-20205),
renamed and substantially rewritten (see [Architecture](#architecture)).

## Features

- **Three recording sources**: microphone only, system audio only, or combined (microphone + system audio)
- **Combined recording without echo**: the two captures are recorded side by side and mixed *offline* when
  you stop. Nothing is played back to the speakers while recording, so the microphone can never
  re-record its own delayed signal (the acoustic feedback loop an earlier version had)
- **Playback and Save** straight from the app; recordings are saved as AAC `.m4a`
- **No leftovers**: unsaved recordings live in the temporary directory and are removed when the app
  quits and on the next launch; no log files are written

## Requirements

- macOS 13.5 or later
- Xcode 16 or later to build (the project uses file system synchronized groups)

## Install

### Homebrew

```bash
brew tap dct74/mix-recording https://github.com/dct74/Mix-Recording
brew trust dct74/mix-recording            # Homebrew 6 asks for this on third-party taps
brew install --cask mix-recording
```

- The tap form above installs the cask straight from this repository (Homebrew clones it into its tap
  directory); the app itself comes from the release archive, so a release has to exist first — see
  [Publishing a release](#publishing-a-release).
- Homebrew 6 refuses to load casks from an untrusted tap, hence the `brew trust` step. Tapping before
  trusting prints a confusing "invalid syntax in tap!" error; just run the three lines in order.
- Uninstall with `brew uninstall --cask mix-recording` (add `brew zap mix-recording` to remove the
  sandbox container and preferences as well).

### Build from source

```bash
git clone git@github.com:dct74/Mix-Recording.git
cd Mix-Recording

# Only needed when xcode-select still points at the Command Line Tools
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording \
  -configuration Release -derivedDataPath build build

open build/Build/Products/Release/Mix-Recording.app
```

### Publishing a release

The Homebrew cask points at `Mix-Recording-<version>.zip` on the GitHub releases page:

```bash
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording \
  -configuration Release -derivedDataPath build build

(cd build/Build/Products/Release && zip -qry /tmp/Mix-Recording-1.0.zip Mix-Recording.app)
shasum -a 256 /tmp/Mix-Recording-1.0.zip     # put this hash into Casks/mix-recording.rb
```

Create a release tagged `v1.0` and upload `/tmp/Mix-Recording-1.0.zip`, then update `version` and
`sha256` in `Casks/mix-recording.rb`, commit and push. Anyone who already tapped the repository picks
the new checksum up with `brew update`.

`gh release create` may refuse with *"workflow" scope may be required*; creating the release through
the API (`gh api --method POST /repos/<owner>/<repo>/releases …`, then uploading the asset to
`uploads.github.com`) works with the ordinary `repo` scope.

## Usage

1. Pick a recording source: **Microphone Only**, **System Audio Only** or **Combined Recording**
2. Press **Record**, then **Stop Recording**
   - After a combined recording the app mixes the two captures; this takes a moment (the UI shows
     *"Mixing recording..."*), and a very long recording takes a few seconds. Pressing stop again
     cancels the mix.
3. **Play** to preview, **Save** to write the file (the panel defaults to `~/Music`)

First run asks for permissions:

- **Microphone** — required for the microphone and combined sources
- **Screen Recording** — required for the system audio and combined sources (system audio is captured
  with ScreenCaptureKit)

## Where recordings live

| Stage | Location |
| --- | --- |
| Being recorded (not saved yet) | `$TMPDIR` — `mic_recording.m4a`, `system_audio_<timestamp>_<id>.m4a`, `combined_mic.m4a`, `combined_recording_<timestamp>_<id>.m4a` |
| After **Save** | wherever you choose; the panel defaults to `~/Music` with `mic-recording.m4a`, `sys-recording.m4a` or `mix-recording.m4a` |

- Save *moves* the working file out of the temporary directory (re-saving an already saved recording
  copies it instead, so nothing on disk is destroyed)
- Unsaved recordings are deleted when the app quits and any leftovers are removed on the next launch;
  files that do not belong to the app are never touched

## Architecture

| File | Responsibility |
| --- | --- |
| `AudioRecorder.swift` | Source selection, permissions, session lifecycle, cleanup, save and playback |
| `AudioMixdown.swift` | Offline mixdown of a combined recording (AVAudioEngine manual rendering) |
| `AudioFileWriter.swift` | Writes capture buffers to disk from a dedicated queue with a preallocated buffer pool |
| `ContentView.swift` | SwiftUI view and view model |
| `MixRecordingApp.swift` | App entry point |

- **Combined recording** = microphone (`AVAudioRecorder`) + system audio (ScreenCaptureKit), mixed
  offline on stop. The two captures start at different moments, so the mixdown delays the system audio
  by the measured difference. Because neither capture touches the output device there is no monitoring
  and therefore no echo.
- **Thread isolation** is enforced by the compiler: `AudioRecorder` and `AudioRecorderViewModel` are
  `@MainActor`, and everything that runs on a capture or render thread lives in `Sendable` helpers
  (`SystemAudioCapture`, `SystemAudioPlayer`, `AudioFileWriter`) that own their state.
- The previous real-time mixing engine has been deleted. It fed the microphone and a copy of the system
  audio into the engine's main mixer, which is wired to the output node — so both were monitored through
  the speakers and the microphone re-recorded that delayed signal (a ~12 ms feedback loop in the file).

## Troubleshooting

**Screen recording permission is asked for again after every rebuild**
- Development builds are signed ad-hoc, so macOS treats each build as a new app. Grant the permission
  again, or use a stable signing identity.
- If *Mix-Recording* does not appear under `System Settings → Privacy & Security → Screen Recording`,
  press Record once with **System Audio Only** or **Combined Recording** selected: the app calls
  `CGRequestScreenCaptureAccess()` before showing its own instructions, which registers it there.

**macOS refuses to open the app installed with Homebrew**

- The build is signed ad-hoc and not notarized, so Gatekeeper may block the first launch
  ("Apple could not verify ..."). Right-click the app and choose *Open* once, or clear the quarantine
  flag: `xattr -dr com.apple.quarantine /Applications/Mix-Recording.app`.

**"Could not start recording"**
- Check microphone access under `System Settings → Privacy & Security → Microphone`
- For system audio, check `Screen Recording`

**The combined recording is missing after a mix failure**
- The mixdown runs offline and logs its result to standard output; a failed or cancelled mix leaves no
  half-written file behind and is reported in the status line

## Development

```bash
# Debug build
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording \
  -configuration Debug -derivedDataPath build build

# Build the test bundles (Mix-RecordingTests / Mix-RecordingUITests)
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording \
  -configuration Debug -derivedDataPath build build-for-testing
```

The unit test target imports the app module as `@testable import Mix_Recording` (the product name is
`Mix-Recording`, so the module name replaces the hyphen).

`Documentation/` contains design notes; the files describing the old implementation
(`CombinedRecordingRootCauseAnalysis.md`, `CombinedRecordingIssuesResolved.md`,
`CriticalFixesImplementationPlan.md`) are kept as historical records.

## License

MIT — see [LICENSE](LICENSE). The original project is by Ian Pilon; this fork keeps that copyright
notice alongside the fork's own.
