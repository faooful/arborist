#!/bin/sh
# D29: writes PNG frames of the breeze (moving, stopped, settled) and the blow-away / Reduce Motion fade
# from the real PopoverView (DEBUG, ARBORIST_HOVER_SWEEP=1, cleanup disabled). Usage: scripts/motion-capture.sh [DIR]
set -eu
cd "$(dirname "$0")/.."
DIR="${1:-/tmp/arborist-motion}"
swift build --product ArboristApp
ARBORIST_HOVER_SWEEP=1 "$(swift build --show-bin-path)/ArboristApp" --motion-capture "$DIR"
echo "frames in $DIR"
