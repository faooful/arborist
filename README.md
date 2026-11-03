# Arborist

A small, read-only Mac tool that shows free disk space and how much your dev work uses, with a focus on git worktrees.

- **`arborist` CLI**: `arborist scan --json` for agents, `arborist scan` for people, `arborist free`.
- **ArboristApp**: a small menu bar app (no window). The menu bar leaf wilts as space runs low; the popover is a leaf map of repos, worktrees, deps, caches and free space, with a low-space alert.

It never deletes anything. Per-worktree actions are Reveal in Finder and copying a `git worktree remove` command.

## Build (macOS 13+, Xcode command line tools)

```sh
swift build -c release
.build/release/arborist scan                # human summary
.build/release/arborist scan --json         # JSON
swift run ArboristApp                       # menu bar app, no bundle (notifications fall back to a beep)
scripts/make-app.sh && open Arborist.app
.build/release/arborist render --sample --out map.svg   # H8 leaf map as SVG
scripts/render-shots.sh                     # PNG snapshots (needs Chrome)    # bundled menu bar app (LSUIElement)
```

Scan roots, depth, the alert threshold, the leaf stage multipliers (`leafStages`), `showFreeText` and `scanTimeoutSeconds` (default 180) live in `~/.config/arborist/config.json` (shared by the CLI and the app). Defaults: `~` and `/tmp`, depth 4, 20 GB. Linked worktrees anywhere else are found through their repo's `git worktree list`. Under `~`, Library, Desktop, Downloads and media folders are skipped unless you add one as a root.
The app caches its last scan in `~/Library/Caches/arborist/last-scan.json` (`~/.cache/arborist` on Linux) and shows it on launch while a fresh scan runs.
