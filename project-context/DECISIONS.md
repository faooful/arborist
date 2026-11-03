# Decisions

**D1. Swift Package, not an Xcode project.** CLI, core and app are SwiftPM targets (tools 5.9, macOS 13+). Builds with `swift build` on the Mac, and Core + CLI build and test on Linux. The app target is wrapped in `#if os(macOS)`; `scripts/make-app.sh` makes the .app bundle.

**D2. Read-only v1.** No deletes anywhere. Worktree rows offer Reveal in Finder and copying `git worktree remove <path>` (or `git worktree prune` for missing folders) for Joseph to run himself. Clean buttons are deferred and need sign-off.

**D3. No Full Disk Access.** We don't ask for it. Under `~` we skip Library, Desktop, Downloads, Pictures, Movies, Music, Applications and Public unless chosen as roots, which avoids privacy prompts. Docker size comes from `docker system df`, not Docker's container folder. Unreadable paths are skipped and counted.

**D4. CLI JSON for agents.** `devspace scan --json` emits the same `ScanResult` the app renders (sorted keys, ISO 8601 dates, totals included).

**D5. Stale rule.** A linked worktree is stale when its branch has no commits beyond the default branch (origin/HEAD, else main/master) and has moved since creation (so fresh branches aren't flagged), when its upstream is `[gone]`, or when git marks it prunable. The main worktree is never stale.

**D7. Menu bar popover only, no window (Joseph, PR #1).** DevspaceApp has no Window/WindowGroup. Everything lives in the `MenuBarExtra` popover (`.menuBarExtraStyle(.window)`): free space, summary, project/worktree list with Reveal and Copy remove command, shared caches, Rescan/Reveal/Settings/Quit. Settings stay a minimal `Settings` scene opened from the popover. Styling is plain pending Dara's popover redesign; the blob view was removed from the app (`BlobLayout` stays in Core, tested, unused for now). The menu bar label stays as free-space text pending Joseph's OK.

**D6. Size split.** Directories named node_modules, .next, dist, target, .venv, DerivedData or .build count as rebuildable; everything else (including .git) is source. Nested repos/worktrees are skipped inside a parent so nothing is counted twice. Sizes are allocated bytes; units are decimal like Finder.
