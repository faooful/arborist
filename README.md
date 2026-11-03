# Arborist

A small, read-only Mac tool that shows free disk space and how much your dev work uses, with a focus on git worktrees.

- **`arborist` CLI**: `arborist scan --json` for agents, `arborist scan` for people, `arborist free`.
- **ArboristApp**: a small menu bar app (no window). The popover shows free space, projects and worktrees, shared caches, and a low-space alert.

It never deletes anything. Per-worktree actions are Reveal in Finder and copying a `git worktree remove` command.

## Build (macOS 13+, Xcode command line tools)

```sh
swift build -c release
.build/release/arborist scan                # human summary
.build/release/arborist scan --json         # JSON
swift run ArboristApp                       # menu bar app, no bundle (notifications fall back to a beep)
scripts/make-app.sh && open Arborist.app    # bundled menu bar app (LSUIElement)
```

Scan roots, depth and the alert threshold live in `~/.config/arborist/config.json` (shared by the CLI and the app). Defaults: `~` and `~/Documents`, depth 4, 20 GB.
