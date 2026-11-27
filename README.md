# StreamShadows

A native macOS livestreaming studio built with SwiftUI, ScreenCaptureKit, AVFoundation, Metal-backed CoreImage, and hardware-accelerated H.264/AAC RTMP(S) streaming.

Stream your desktop, your camera, or both (with Picture-in-Picture) to **YouTube**, **Twitch**, and **X (Twitter)** — individually or simultaneously — with independent desktop sound and microphone mixing.

## Features

- **Screen Selection (`ScreenCaptureKit` + `NSScreen`)**:
  - Lists every connected display immediately by its macOS monitor name and resolution, with clickable screen cards in the **Sources** tab and a quick **Screen switcher** directly in the preview bar.
  - **Hide StreamShadows from capture** toggle (enabled by default) prevents the infinite "hall of mirrors" preview loop when streaming the same display StreamShadows is on.
  - Automatically refreshes when displays are connected or disconnected.
- **Optional Camera & Picture-in-Picture (`AVFoundation` + Metal `CoreImage`)**:
  - Switch seamlessly between **Screen Only**, **Camera Only**, and **Screen + Cam** (Picture-in-Picture) with configurable corner placement, PiP size, and horizontal mirror toggle.
  - Zero-allocation pooled frame buffers and wall-clock pacing for smooth 30/60 fps compositing.
- **Real-Time Audio Mixer**:
  - Independent **Desktop Sound**, **Microphone**, and **Master Output** volume sliders, mute buttons, enable toggles, and live peak VU meters.
  - Supports built-in mics as well as 16-bit, 24-bit, and 32-bit USB/XLR audio interfaces (with automatic 48 kHz stereo conversion, O(1) ring buffers, soft-clipping limiter, and wall-clock drift protection).
  - Glitch-free live toggling of Desktop Sound without restarting video capture, plus automatic USB microphone/camera hot-plug detection.
- **Multi-Platform Streaming (YouTube, Twitch, X)**:
  - Built-in presets for **YouTube**, **Twitch**, and **X (Twitter)** with editable `rtmp://` / `rtmps://` ingest URLs, inline URL validation, and simultaneous multi-streaming (`tee` muxer with target escaping).
  - Stream keys are stored securely in the **macOS Keychain** (with debounced writes) and automatically redacted from logs.
  - Bounded backpressure frame dropping with live dropped-frame telemetry, handshake-confirmed `LIVE` status, and automatic macOS display sleep prevention (`IOPMAssertion`) while broadcasting.
- **Local Recording (MP4, MKV, MOV)**:
  - Record your screen, camera, or Screen + Cam PiP locally to disk with one click (**Record / Stop Rec**) — either standalone without streaming or simultaneously while live.
  - Uses crash-safe fragmented MP4/MOV (`+frag_keyframe+empty_moov+default_base_moof`) and clean FIFO EOF finalization so recordings are immediately playable and never corrupted.
  - Configurable output folder (default `~/Movies/StreamShadows`) with quick **Open Folder** and **Reveal Last** buttons.
- **Hardware-Accelerated Encoding**:
  - Uses Apple VideoToolbox (`h264_videotoolbox`) via `ffmpeg` with software `libx264` fallback and selectable 720p/1080p 30/60 fps presets.

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6 / Xcode 16+ (to build from source)
- `ffmpeg` installed on your Mac (auto-detected from `~/.local/bin/ffmpeg`, `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `PATH`, or configurable in the **Output** tab)

## Build, Install & Run

Build and sign the native `.app` bundle (automatically uses your Keychain's `Apple Development` certificate if available so macOS privacy permissions persist cleanly across rebuilds):

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh release
```

Install into `/Applications` and launch:

```bash
rm -rf /Applications/StreamShadows.app
ditto dist/StreamShadows.app /Applications/StreamShadows.app
open /Applications/StreamShadows.app
```

Run unit tests:

```bash
swift test
```

## macOS Permissions

On first launch, macOS will ask for:
1. **Screen & System Audio Recording** — click **Grant Screen Recording Access** (opens System Settings → Privacy & Security → Screen & System Audio Recording), toggle **StreamShadows** ON, then quit and reopen the app once so macOS activates the grant.
2. **Camera** — prompted once if you use **Camera Only** or **Screen + Cam** mode.
3. **Microphone** — prompted once when microphone capture is enabled.

## Platform Setup Tips

- **YouTube**: YouTube Studio → Go Live → copy your Stream Key. Default server: `rtmps://a.rtmps.youtube.com/live2/`
- **Twitch**: Twitch Creator Dashboard → Settings → Stream → copy your Primary Stream Key. Default server: `rtmp://live.twitch.tv/app/`
- **X (Twitter)**: X Media Studio → Producer → Sources → create an RTMP source and paste both the assigned RTMP/RTMPS Server URL and Stream Key.

## Architecture Overview

- `Sources/StreamShadows/Models/StreamModels.swift` — Core state types, platform presets, quality presets, and RTMP(S) URL validation.
- `Sources/StreamShadows/Services/CaptureManager.swift` — Thread-safe `ScreenCaptureKit` + `AVFoundation` capture with self-exclusion and error recovery.
- `Sources/StreamShadows/Services/FrameCompositor.swift` — Metal-backed `CoreImage` compositor with `FrameBufferPool` and wall-clock pacing.
- `Sources/StreamShadows/Services/AudioMixer.swift` — 48 kHz stereo mixer with `FloatRingBuffer`, 16/24/32-bit PCM decoding, resampling, soft clipping, and drift protection.
- `Sources/StreamShadows/Services/RTMPStreamer.swift` — `ffmpeg` process manager with non-blocking FIFO opening, bounded backpressure, secret redaction, and `tee` multi-streaming.
- `Sources/StreamShadows/Services/LocalRecorder.swift` — Standalone and simultaneous local MP4/MKV/MOV recorder with crash-safe container flags and graceful EOF finalization.
- `Sources/StreamShadows/Services/KeychainStore.swift` — macOS Keychain persistence for stream keys.
- `Sources/StreamShadows/Services/SleepPreventer.swift` — IOKit `IOPMAssertion` wrapper to prevent display sleep while live.
- `Sources/StreamShadows/ViewModels/StreamViewModel.swift` — `@MainActor` coordinator with debounced Keychain saves and hot-plug device observers.
- `Sources/StreamShadows/UI/` — Native SwiftUI studio interface (`ContentView`, `AudioMixerPanel`, `InspectorSidebar`, `LevelMeterView`).
