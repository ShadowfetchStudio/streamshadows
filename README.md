# StreamShadows

A native macOS livestreaming studio built with SwiftUI, ScreenCaptureKit, AVFoundation, and hardware-accelerated H.264/AAC RTMP(S) streaming.

Stream your desktop, your camera, or both (with Picture-in-Picture) to **YouTube**, **Twitch**, and **X (Twitter)** — individually or simultaneously — with independent desktop and microphone audio mixing.

## Features

- **Screen Selection (`ScreenCaptureKit`)**: Pick any connected display and capture smooth desktop video and native system audio.
- **Optional Camera & Picture-in-Picture (`AVFoundation`)**: Stream **Screen Only**, **Camera Only**, or **Screen + Camera PiP** with configurable corner placement, PiP size, and horizontal mirror toggle.
- **Audio Mixer**:
  - Independent **System Audio**, **Microphone**, and **Master** volume controls and mute switches.
  - Real-time peak level meters and soft-clipping limiter to prevent distortion.
  - Microphone input device selector.
- **Multi-Platform Streaming**:
  - Built-in presets for **YouTube**, **Twitch**, and **X (Twitter)** (with editable RTMP/RTMPS ingest URLs).
  - Stream to one platform or enable multiple platforms at once.
  - Stream keys stored securely in the **macOS Keychain** and automatically redacted from logs.
- **Hardware-Accelerated Encoding**: Uses Apple VideoToolbox (`h264_videotoolbox`) via `ffmpeg` with software `libx264` fallback and selectable 720p/1080p 30/60fps quality presets.

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6 / Xcode 16+ (to build from source)
- `ffmpeg` installed on your Mac (e.g. `brew install ffmpeg`, or available in `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `~/.local/bin/ffmpeg`, or configured in the app's Output tab)

## Build & Run

Build and package the native `.app` bundle:

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh release
open dist/StreamShadows.app
```

Or run directly with Swift Package Manager:

```bash
swift run StreamShadows
```

Run unit tests:

```bash
swift test
```

## Permissions

On first launch, macOS will prompt for:
1. **Screen & System Audio Recording** (required for capturing displays and desktop audio)
2. **Camera** (only needed if you use Camera or Screen + Camera mode)
3. **Microphone** (only needed if you enable microphone audio)

## Platform Setup Tips

- **YouTube**: Open YouTube Studio -> Go Live -> copy your Stream Key. Default server: `rtmps://a.rtmps.youtube.com/live2/`
- **Twitch**: Open Twitch Creator Dashboard -> Settings -> Stream -> copy your Primary Stream Key. Default server: `rtmp://live.twitch.tv/app/`
- **X (Twitter)**: Open X Media Studio -> Producer -> Sources -> create an RTMP source and paste both the assigned RTMP/RTMPS Server URL and Stream Key.
