import Foundation

/// Example scan in the H8 spirit (worktree-first, D12), used for the Linux snapshot and tests.
/// Dates are relative to `now` so renders are stable.
public enum LeafSample {
    static func gb(_ v: Double) -> Int64 { Int64(v * 1e9) }
    public static let now = Date(timeIntervalSince1970: 1_793_700_000)   // fixed "now" for renders
    public static let freeBytes = gb(118)
    public static let totalBytes = gb(1000)
    static let home = "/Users/joseph"

    enum S { case dirty(Int), unpushed(Int), merged, gone, clean }

    static func wt(_ repo: String, _ branch: String, main: Bool = false, src: Double, deps: Double, _ s: S,
                   days: Double, _ subject: String, at path: String? = nil) -> Worktree {
        let p = path ?? (main ? "\(home)/code/\(repo)" : "\(home)/conductor/workspaces/\(repo)/\(branch.replacingOccurrences(of: "/", with: "-"))")
        var w = Worktree(path: p, isMain: main, branch: branch, head: "4f1c2e9a0b", lastCommitDate: now.addingTimeInterval(-days * 86400),
                         dirty: false, unpushedCommits: nil, hasUpstream: true, stale: false, staleReasons: [],
                         size: SizeSplit(rebuildable: gb(deps), source: gb(src)),
                         removeCommand: main ? nil : "git -C \(home)/code/\(repo) worktree remove \(p)")
        w.lastCommitSubject = subject
        w.upstream = "origin/" + branch
        w.ahead = 0; w.behind = 0; w.unpushedCommits = 0; w.uncommittedFiles = 0
        switch s {
        case .dirty(let n): w.dirty = true; w.uncommittedFiles = n; w.ahead = 1; w.unpushedCommits = 1
        case .unpushed(let n): w.ahead = n; w.unpushedCommits = n
        case .merged: w.stale = true; w.staleReasons = [.merged]; w.behind = 3
        case .gone: w.stale = true; w.staleReasons = [.upstreamGone]; w.upstream = nil; w.ahead = nil; w.behind = nil; w.unpushedCommits = nil; w.hasUpstream = false
        case .clean: break
        }
        return w
    }

    public static var scan: ScanResult {
        let pm = "property-management", farm = "farm", arb = "arborist"
        let repos = [
            Repo(name: pm, path: "\(home)/code/\(pm)", defaultBranch: "main", worktrees: [
                wt(pm, "main", main: true, src: 2.1, deps: 7.3, .clean, days: 1, "Merge pull request #212"),
                wt(pm, "feat-t5b-handover", src: 0.6, deps: 5.6, .dirty(4), days: 0.2, "Handover form: tenant step"),
                wt(pm, "qa1103-forms", src: 0.5, deps: 4.3, .unpushed(2), days: 2, "QA fixes for 11/03"),
                wt(pm, "fix-inventory-overlap", src: 0.4, deps: 3.5, .merged, days: 19, "Fix inventory overlap"),
                wt(pm, "spike-ledger", src: 0.1, deps: 0, .gone, days: 41, "Ledger spike"),
            ]),
            Repo(name: farm, path: "\(home)/code/\(farm)", defaultBranch: "main", worktrees: [
                wt(farm, "main", main: true, src: 3.4, deps: 9.1, .clean, days: 3, "Bump engine"),
                wt(farm, "expedition-roam", src: 1.2, deps: 6.0, .dirty(11), days: 0.5, "Roaming camera"),
                wt(farm, "r8/oil", src: 0.9, deps: 4.5, .merged, days: 26, "Oil shader"),
                wt(farm, "r7/terrain", src: 0.8, deps: 3.3, .merged, days: 33, "Terrain LOD"),
            ]),
            Repo(name: arb, path: "\(home)/code/\(arb)", defaultBranch: "main", worktrees: [
                wt(arb, "main", main: true, src: 0.3, deps: 1.9, .clean, days: 0.1, "Progressive scan (D11)"),
                wt(arb, "worktree-first", src: 0.2, deps: 1.4, .dirty(9), days: 0.05, "Worktree-first map", at: "/private/tmp/arborist-worktree-first"),
            ]),
            Repo(name: "drift", path: "\(home)/code/drift", defaultBranch: "main", worktrees: [
                wt("drift", "main", main: true, src: 1.6, deps: 3.6, .unpushed(1), days: 6, "Tide tables"),
            ]),
            Repo(name: "notes", path: "\(home)/Documents/notes", defaultBranch: "main", worktrees: [
                wt("notes", "main", main: true, src: 0.05, deps: 0, .clean, days: 90, "Weekly notes"),
            ]),
        ]
        return ScanResult(scannedAt: now, roots: ["~", "/tmp"], volume: VolumeInfo(path: home, freeBytes: freeBytes, totalBytes: totalBytes),
                          repos: repos, caches: [CacheEntry(name: "pnpm", path: nil, bytes: gb(12.1)), CacheEntry(name: "npm", path: nil, bytes: gb(7.6)),
                                                 CacheEntry(name: "Homebrew", path: nil, bytes: gb(2.2))], skippedPaths: 0)
    }

    public static var groups: [LeafGroup] { LeafLayout.groups(from: scan) }
}
