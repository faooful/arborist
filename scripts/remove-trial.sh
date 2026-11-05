#!/bin/sh
# D28: runs `--remove-trial` (DEBUG): creates a throwaway repo + worktree at /tmp/arborist-trial-remove,
# removes it through the app path, and checks the leaf is gone in the next frame and the rescan confirms it.
# Touches only its own temp repo; never writes the scan cache.
set -eu
cd "$(dirname "$0")/.."
swift build --product ArboristApp
ARBORIST_HOVER_SWEEP=1 "$(swift build --show-bin-path)/ArboristApp" --remove-trial
