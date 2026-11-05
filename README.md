# Arborist

![Arborist's menu-bar panel opening: a leaf map of 76 worktrees across 35 repos, with stale leaves in tan, over a drifting dithered canopy](docs/assets/demo.gif)

Git worktrees pile up. Arborist is a small Mac menu-bar app that shows every worktree as a leaf, tells you which ones are safe to clear, and clears them for you after you confirm. → **[faooful.github.io/arborist](https://faooful.github.io/arborist/)**

- **ArboristApp**: a menu-bar app with no window. The menu-bar leaf wilts as free space runs low. Its popover is a leaf map of your repos, worktrees, deps, caches and free space, with a low-space alert.
- **`arborist` CLI** (read-only): `arborist scan [--json] [--root PATH ...] [--max-depth N]`, `arborist free [--json]`, `arborist config`, plus `render` / `render-stages` for SVG snapshots. It never changes anything; `--json` is for agents.

## What Clear removes (D14, D31)

"Clear N" and "Remove worktree" (from the hover card, or right-click in the List) run `git worktree remove` (no `--force`) and `git worktree prune`, after a confirm sheet. A worktree is Clear-ready only when:

- it isn't the main checkout and isn't locked,
- it's clean: nothing uncommitted, **untracked files included**, and nothing unpushed or ahead,
- **and** its work is finished in at least one of these ways:
  - its branch is merged into the default branch by ancestry,
  - its upstream is gone,
  - it's prunable (the folder is missing), or
  - it was squash- or rebase-merged. Arborist checks for a merged PR on that exact branch with `gh` if it's installed and signed in. Otherwise it checks offline with `git cherry`, a matching tree, or a matching `patch-id` against `origin/<default>`.

Arborist never runs `git fetch`, so results are only as fresh as your last fetch. It re-checks each worktree right before removing it (same head, clean, not ahead). Branches are never deleted. Every removal is logged to `~/.config/arborist/cleanup.log`.

## Build (macOS 13+, Xcode command line tools)

```sh
swift build -c release
.build/release/arborist scan                # human summary
.build/release/arborist scan --json         # JSON
swift run ArboristApp                       # menu bar app, no bundle (notifications fall back to a beep)
scripts/make-app.sh && open Arborist.app   # bundled menu bar app (LSUIElement)
.build/release/arborist render --sample --out map.svg   # H8 leaf map as SVG
scripts/render-shots.sh                     # PNG snapshots (needs Chrome)
```

Scan roots, depth, the alert threshold, the leaf stage multipliers (`leafStages`), `showFreeText` and `scanTimeoutSeconds` (default 600; the app extends it to twice the last full scan, up to 30 min) live in `~/.config/arborist/config.json` (shared by the CLI and the app). Defaults: `~`, `~/go` and `/tmp`, depth 8, 20 GB. Saved configs still on an old default migrate automatically. Linked worktrees anywhere else are found through their repo's `git worktree list`. Under `~`, Library, Desktop, Downloads and media folders are skipped unless you add one as a root.
The app caches its last scan in `~/Library/Caches/arborist/last-scan.json` (`~/.cache/arborist` on Linux) and shows it on launch while a fresh scan runs.
