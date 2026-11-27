# StreamShadows

A native macOS livestreaming and recording studio built with SwiftUI, ScreenCaptureKit, AVFoundation, Metal-backed CoreImage, and hardware-accelerated H.264/AAC encoding.

Stream your desktop, a single application window, your camera, or both (with rounded or circular Picture-in-Picture) to **YouTube**, **Twitch**, and **X (Twitter)** — individually or simultaneously — and record locally to **MP4**, **MKV**, or **MOV**.

## Features

- **Full-Screen & Single-Window Capture (`ScreenCaptureKit` + `NSScreen`)**:
  - Lists every connected display immediately by its macOS monitor name and resolution, with clickable screen cards in **Sources** and a quick switcher in the preview bar.
  - Switch between **Full Screen** and **Single Window** capture (`SCContentFilter(desktopIndependentWindow:)`).
  - **Hide StreamShadows from capture** toggle (enabled by default) prevents the infinite "hall of mirrors" preview loop when capturing the display StreamShadows is on.
- **1080p Camera & Picture-in-Picture (`AVFoundation` + Metal `CoreImage`)**:
  - Switch seamlessly between **Screen Only**, **Camera Only**, and **Screen + Cam** (Picture-in-Picture) with configurable corner placement, size, **Rounded / Circle / Sharp** shape masks, and horizontal mirror toggle.
  - Prefers **1080p** camera capture (with automatic 720p fallback), zero-allocation ref-counted `FrameBufferPool`, wall-clock pacing, and automatic **idle GPU pause** when minimized/hidden.
- **Real-Time Audio Mixer & Mic FX**:
  - Independent **Desktop Sound**, **Microphone**, and **Master Output** sliders, mute buttons, enable toggles, and live peak VU meters (with clear indicator when Desktop Sound is unavailable in Camera Only mode).
  - Built-in **Mic FX** popover with adjustable **Noise Gate** (silences keyboard/fan noise) and **Mic Sync Delay (0–300 ms)** for lip-syncing USB mics with webcams.
  - Supports built-in mics and 16/24/32-bit USB/XLR interfaces (48 kHz stereo conversion, O(1) `FloatRingBuffer`, soft-clipping limiter, wall-clock drift protection, and USB hot-plug detection).
- **Local Recording (MP4, MKV, MOV)**:
  - Clicking **Record** prompts with a native macOS **Save dialog** so you can choose the exact folder and filename for each recording (configurable in the **Output** tab to either ask every time or save directly to your default folder).
  - Supports **standalone recording** or **simultaneous recording while live**, **Pause / Resume**, optional **3-second countdown**, live **file-size readout**, pre-flight **disk-space checks**, crash-safe fragmented MP4/MOV (`+frag_keyframe+empty_moov+default_base_moof`), and graceful FIFO EOF finalization.
- **Multi-Platform Streaming (YouTube, Twitch, X)**:
  - Built-in presets for **YouTube**, **Twitch**, and **X (Twitter)** with editable `rtmp://` / `rtmps://` ingest URLs, inline validation, and simultaneous multi-streaming (`tee` muxer with target escaping).
  - **Auto-reconnect with exponential backoff** (up to 5 attempts) on transient network drops, real `ffmpeg` error extraction, synchronized dual-FIFO A/V gating, handshake-confirmed `LIVE` status, and **macOS Keychain** stream key storage with log redaction.
- **Native macOS Studio Ergonomics**:
  - **Menu Bar Extra** with live `LIVE` / `REC` / `PAUSED` status and quick Show, Record, Pause, Go Live, and Mute Mic controls.
  - **Quit confirmation & graceful flush**: warns before quitting during an active stream/recording and synchronously finalizes the recording file before exit.
  - Automatic macOS display sleep prevention (`IOPMAssertion`) while live or recording.

## Keyboard Shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘⇧R` | Start / Stop Recording |
| `⌘⇧P` | Pause / Resume Recording |
| `⌘⇧L` | Go Live / Stop Stream |
| `⌘⇧M` | Mute / Unmute Microphone |

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6 / Xcode 16+ (to build from source)
- `ffmpeg` installed on your Mac (auto-detected from app bundle, `~/.local/bin/ffmpeg`, `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `PATH`, or configurable in **Output**)

## Build, Install & Run

Build and sign the native `.app` bundle (automatically signs with your Keychain's `Apple Development` certificate when available so macOS privacy grants persist cleanly across rebuilds):

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh release
```

To create a self-contained bundle with `ffmpeg` embedded inside `Contents/Resources/ffmpeg`:

```bash
./scripts/build-app.sh release --bundle-ffmpeg
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
