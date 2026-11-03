# devspace

A small, read-only Mac tool that shows free disk space and how much your dev work uses, with a focus on git worktrees.

- **`devspace` CLI**: `devspace scan --json` for agents, `devspace scan` for people, `devspace free`.
- **DevspaceApp**: a SwiftUI window plus a menu bar item showing free space, a blob map, a checklist of projects and worktrees, and a low-space alert.

It never deletes anything. Per-worktree actions are Reveal in Finder and copying a `git worktree remove` command.

## Build (macOS 13+, Xcode command line tools)

```sh
swift build -c release
.build/release/devspace scan                # human summary
.build/release/devspace scan --json         # JSON
swift run DevspaceApp                       # app, no bundle (notifications fall back to a beep)
scripts/make-app.sh && open Devspace.app    # bundled menu bar app (LSUIElement)
```

Scan roots, depth and the alert threshold live in `~/.config/devspace/config.json` (shared by the CLI and the app). Defaults: `~` and `~/Documents`, depth 4, 20 GB.
