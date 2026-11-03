# Arborist: project context


**Repo:** faooful/arborist (private; renamed from faooful/devspace).
**What:** Mac disk-space tool for Joseph's dev work. Focus is git worktrees, which he creates in large numbers.
**Who:** Joseph Korol. Built by Emily (engineer agent); Cedric (chief of staff) relays approvals and runs it on the work Mac.

## Layout
- `Sources/ArboristCore`: scanner (repo discovery, `git worktree list --porcelain`, per-worktree status, size split, caches, free space), JSON models, blob layout geometry. Platform-neutral; builds and tests on Linux.
- `Sources/arborist`: CLI.
- `Sources/ArboristApp`: SwiftUI menu bar app: MenuBarExtra popover + Settings scene, no window (D7). All code inside `#if os(macOS)`; on Linux the target is a stub.
- `scripts/make-app.sh`: wraps the release binary in `Arborist.app` with `LSUIElement`.

## Rules
- Read-only. No delete, move or clean code paths. Any cleanup feature needs Cedric/Joseph sign-off first.
- No Full Disk Access. Unreadable paths are skipped and counted.
- Visuals: plain for now; Dara is redesigning the popover. Earlier direction was Kanso-style.
- Commits authored and committed as Joseph Korol <joseph.m.korol@gmail.com>. Feature branches and PRs only.
