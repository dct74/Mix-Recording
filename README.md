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
brew tap dct74/tap
brew trust dct74/tap                      # Homebrew 6 asks for this on third-party taps
brew install --cask mix-recording
```

- The cask lives in the [dct74/homebrew-tap](https://github.com/dct74/homebrew-tap) tap; the app
  itself comes from the release archive, so a release has to exist first — see
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

xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Release build

# Xcode puts the product in the default derived data folder
open ~/Library/Developer/Xcode/DerivedData/Mix-Recording-*/Build/Products/Release/Mix-Recording.app
```

Two things to know about signing:

- The project signs ad-hoc ("Sign to Run Locally") and applies
  `Mix-Recording/Mix-Recording.entitlements`. Do **not** pass `CODE_SIGNING_ALLOWED=NO`: that skips
  signing the bundle entirely and macOS then reports the app as *"damaged"* instead of merely
  unverified.
- Keep the build products out of a synced folder. With `-derivedDataPath build` inside an
  iCloud-synced `~/Documents`, the file provider stamps `com.apple.FinderInfo` /
  `com.apple.fileprovider.*` onto the bundle and `codesign` fails with *"resource fork, Finder
  information, or similar detritus not allowed"*.

```bash
# Debug build, for a quick local run
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Debug build
```

### Publishing a release

The Homebrew cask points at `Mix-Recording-<version>.zip` on the GitHub releases page:

```bash
# Bump MARKETING_VERSION in the project first, then:
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Release build

PRODUCT=~/Library/Developer/Xcode/DerivedData/Mix-Recording-*/Build/Products/Release/Mix-Recording.app
codesign --verify --deep --strict $PRODUCT        # must print "valid on disk"

# ditto keeps the bundle's symlinks and metadata; a plain zip can break the signature
ditto -c -k --sequesterRsrc --keepParent $PRODUCT /tmp/Mix-Recording-<version>.zip
shasum -a 256 /tmp/Mix-Recording-<version>.zip    # hash for the tap's Casks/mix-recording.rb
```

Create a release tagged `v1.0` and upload `/tmp/Mix-Recording-1.0.zip`, then update `version` and
`sha256` in `Casks/mix-recording.rb` in the [tap repository](https://github.com/dct74/homebrew-tap),
and commit and push there. Anyone who already tapped it picks the new checksum up with `brew update`.

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

**macOS says the app is "damaged", or refuses to open it**

- Releases are signed ad-hoc but not notarized, so Gatekeeper blocks the first launch of a downloaded
  copy. Clear the download flag and it starts normally:

  ```bash
  xattr -dr com.apple.quarantine /Applications/Mix-Recording.app
  ```

  (Right-click → *Open* also works, and macOS 15+ additionally offers *Open Anyway* under
  `System Settings → Privacy & Security`.)
- *"Mix-Recording.app is damaged"* with **no** *Open Anyway* button means the bundle signature is
  broken rather than merely untrusted. That happens when a build skipped signing
  (`CODE_SIGNING_ALLOWED=NO`); check with `codesign --verify --deep --strict /Applications/Mix-Recording.app`
  and rebuild without disabling signing.
- To remove the prompt entirely the app has to be signed with a Developer ID certificate and
  notarized, which requires a paid Apple Developer account.

**The app launches but no window appears**

- `brew reinstall --cask mix-recording` replaces the bundle, and LaunchServices can keep a stale
  registration for the old one. Re-register it, or open the app by path instead of by name:

  ```bash
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f -R -trusted /Applications/Mix-Recording.app
  open /Applications/Mix-Recording.app
  ```

**"Could not start recording"**
- Check microphone access under `System Settings → Privacy & Security → Microphone`
- For system audio, check `Screen Recording`

**The combined recording is missing after a mix failure**
- The mixdown runs offline and logs its result to standard output; a failed or cancelled mix leaves no
  half-written file behind and is reported in the status line

## Development

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # if xcode-select points at the CLT

xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Debug build

# Build the test bundles (Mix-RecordingTests / Mix-RecordingUITests)
xcodebuild -project Mix-Recording.xcodeproj -scheme Mix-Recording -configuration Debug \
  build-for-testing
```

The unit test target imports the app module as `@testable import Mix_Recording` (the product name is
`Mix-Recording`, so the module name replaces the hyphen).

`Documentation/Pitfalls.md` collects the build, signing, Homebrew and AVAudioEngine pitfalls hit while
working on this project, together with the commands that fix them (Chinese).

`Documentation/` contains design notes; the files describing the old implementation
(`CombinedRecordingRootCauseAnalysis.md`, `CombinedRecordingIssuesResolved.md`,
`CriticalFixesImplementationPlan.md`) are kept as historical records.

## License

MIT — see [LICENSE](LICENSE). The original project is by Ian Pilon; this fork keeps that copyright
notice alongside the fork's own.
