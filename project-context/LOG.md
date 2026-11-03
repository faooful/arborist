# Log

| Date | Change |
|---|---|
| 2026-11-03 | Repo created (private). v1 PR: DevspaceCore scanner, `devspace` CLI with JSON, SwiftUI window + menu bar app in the Kanso style, low-space alert, scan-root settings, unit + git integration tests. Core/CLI built and tested on Linux (Swift 6.0.3); app compiled only as a Linux stub, untested on Mac. |
| 2026-11-03 | Scope change: menu bar popover only (D7). Removed the main window and blob view; popover holds free space, list, caches, worktree actions; plain styling pending Dara. Still compiled only as a Linux stub. |
| 2026-11-03 | Renamed to Arborist (D8): ArboristApp/Arborist.app, `arborist` CLI, ArboristCore, ~/.config/arborist/config.json, bundle id com.faooful.arborist. Repo renamed to faooful/arborist. |
| 2026-11-03 | H8 leaves (D9) and wilting menu bar leaf (D10), stacked on #1: leaf layout ported to ArboristCore (deterministic, min leaf size, fold to 'other'), SVG renderer + `arborist render`/`render-stages`, popover redrawn in H8, Clear N copies remove commands, config gains leafStages/showFreeText. 22 tests pass on Linux. Shots: project-context/shots/h8-linux.png, leaf-stages.png. App still not compiled on Mac. |
| 2026-11-03 | Scan fix (D11): progressive scan events + "12/34 repos", one-walk bulk directory listing (getattrlistbulk on macOS, readdir/fstatat on Linux), last-scan cache shown on launch, 180 s timeout with Retry, Sendable warnings fixed. Linux CLI on /workspace (90 repos, 254 worktrees): ~32.3 s → ~19.2 s. 30 tests pass. App not compiled on Mac. |
| 2026-11-03 | Worktree-first map (D12): one leaf per worktree grouped by repo, rebuildable inner shade, caches line, branch-first labels, status precedence, hover lift/dim/card + List highlight, List sorted by state then age, discovery from ~ and /tmp via gitdir links and `worktree list`, 2 git calls per worktree. 43 tests pass on Linux. Shots: project-context/shots/worktree-first.png, worktree-first-hover.png. App not compiled on Mac. |

