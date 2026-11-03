#!/bin/sh
# Builds ArboristApp in release mode and wraps it in Arborist.app (menu bar only: LSUIElement).
# Usage: scripts/make-app.sh   -> ./Arborist.app   (then: open Arborist.app, or move it to /Applications)
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product ArboristApp
BIN="$(swift build -c release --show-bin-path)/ArboristApp"
APP=Arborist.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Arborist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Arborist</string>
  <key>CFBundleIdentifier</key><string>com.faooful.arborist</string>
  <key>CFBundleExecutable</key><string>Arborist</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || echo "codesign skipped"
echo "Built $APP"
