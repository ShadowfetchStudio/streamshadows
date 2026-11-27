#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="StreamShadows"
BUILD_CONFIG="${1:-release}"
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

cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>StreamShadows</string>
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
EOF

# Ad-hoc sign the bundle so macOS TCC permissions (Screen Recording, Camera, Microphone) persist cleanly
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE successfully."
