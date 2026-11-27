#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="StreamShadows"
BUILD_CONFIG="${1:-release}"
BUNDLE_FFMPEG="${2:-}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building $APP_NAME ($BUILD_CONFIG)..."
cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG"

BIN_PATH="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

if [[ "$BUNDLE_FFMPEG" == "--bundle-ffmpeg" ]]; then
    FFMPEG_SRC="$(command -v ffmpeg || true)"
    if [[ -n "$FFMPEG_SRC" && -f "$FFMPEG_SRC" ]]; then
        echo "Bundling ffmpeg from $FFMPEG_SRC..."
        cp "$FFMPEG_SRC" "$RESOURCES_DIR/ffmpeg"
        chmod +x "$RESOURCES_DIR/ffmpeg"
    else
        echo "Warning: --bundle-ffmpeg requested but ffmpeg was not found on PATH." >&2
    fi
fi

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>StreamShadows</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.shadowfetch.streamshadows</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>StreamShadows</string>
    <key>CFBundleDisplayName</key>
    <string>StreamShadows</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>StreamShadows uses your camera when you enable camera streaming or Picture-in-Picture overlay.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>StreamShadows uses your microphone to capture and mix your voice into your livestream.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>StreamShadows captures your selected display and system audio to stream your desktop.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
</dict>
</plist>
EOF

plutil -lint "$CONTENTS_DIR/Info.plist"

ENTITLEMENTS_FILE="$DIST_DIR/StreamShadows.entitlements"
cat > "$ENTITLEMENTS_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
EOF

# Prefer a real Apple Development signing identity so macOS TCC (Screen Recording, Mic, Camera)
# binds permissions stably to com.shadowfetch.streamshadows instead of invalidating on rebuild.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}' || true)"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with identity: $SIGN_IDENTITY"
    codesign --force --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    echo "No Apple Development certificate found; falling back to ad-hoc signing."
    codesign --force --entitlements "$ENTITLEMENTS_FILE" --sign - "$APP_BUNDLE"
fi

rm -f "$ENTITLEMENTS_FILE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Built $APP_BUNDLE successfully."
