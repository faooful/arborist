#!/bin/sh
# D23: runs `--action-check` as a real app bundle launched by LaunchServices (`open`), so macOS 14+ cooperative
# activation treats it like a user launch. A process started straight from Terminal can't become active while
# Terminal is frontmost, so its Settings check reports active=false / key=false (a harness limit, not a bug).
# Debug build, cleanup disabled (ARBORIST_HOVER_SWEEP=1), never quits through the router, no menu bar item.
set -eu
cd "$(dirname "$0")/.."
swift build --product ArboristApp
BIN="$(swift build --show-bin-path)/ArboristApp"
DIR="$(mktemp -d)"
APP="$DIR/ArboristCheck.app"
LOG="$DIR/action-check.log"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ArboristCheck"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ArboristCheck</string>
  <key>CFBundleIdentifier</key><string>com.faooful.arborist.check</string>
  <key>CFBundleExecutable</key><string>ArboristCheck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
open -n -W --env ARBORIST_HOVER_SWEEP=1 --stdout "$LOG" --stderr "$LOG" "$APP" --args --action-check
cat "$LOG"
rm -rf "$DIR"
