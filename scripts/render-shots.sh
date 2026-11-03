#!/bin/sh
# Renders the H8 leaf map (sample data) and the four menu bar leaf stages to PNG.
# Works on Linux or macOS; needs Google Chrome (headless) for SVG -> PNG.
set -eu
cd "$(dirname "$0")/.."
CHROME="${CHROME:-google-chrome}"
mkdir -p shots
swift build --product arborist
BIN="$(swift build --show-bin-path)/arborist"
"$BIN" render --sample --out shots/h8-linux.svg
"$BIN" render-stages --out shots/leaf-stages.svg
cd shots
"$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=480,580 --screenshot=h8-linux.png h8-linux.svg
"$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=384,232 --screenshot=leaf-stages.png leaf-stages.svg
