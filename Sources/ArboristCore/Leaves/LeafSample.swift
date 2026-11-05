import Foundation

/// Example scan in the H8 spirit (worktree-first, D12), used for the Linux snapshot and tests.
/// Dates are relative to `now` so renders are stable.
public enum LeafSample {
    static func gb(_ v: Double) -> Int64 { Int64(v * 1e9) }
    public static let now = Date(timeIntervalSince1970: 1_793_700_000)   // fixed "now" for renders
    public static let freeBytes = gb(118)
    public static let totalBytes = gb(1000)
    static let home = "/Users/sample"

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
        let orchard = "orchard", rowan = "rowan", arb = "arborist"
        let repos = [
            Repo(name: orchard, path: "\(home)/code/\(orchard)", defaultBranch: "main", worktrees: [
                wt(orchard, "main", main: true, src: 2.1, deps: 7.3, .clean, days: 1, "Merge pull request #212"),
                wt(orchard, "acorn-ui", src: 0.6, deps: 5.6, .dirty(4), days: 0.2, "Shade the canopy edge"),
                wt(orchard, "dew-retry", src: 0.5, deps: 4.3, .unpushed(2), days: 2, "Dew line fixes"),
                wt(orchard, "twig-layout", src: 0.4, deps: 3.5, .merged, days: 19, "Fix twig overlap"),
                wt(orchard, "bark-tests", src: 0.1, deps: 0, .gone, days: 41, "Bark tests"),
            ]),
            Repo(name: rowan, path: "\(home)/code/\(rowan)", defaultBranch: "main", worktrees: [
                wt(rowan, "main", main: true, src: 3.4, deps: 9.1, .clean, days: 3, "Bump the canopy"),
                wt(rowan, "canopy-walk", src: 1.2, deps: 6.0, .dirty(11), days: 0.5, "Walking the canopy"),
                wt(rowan, "r8/sap", src: 0.9, deps: 4.5, .merged, days: 26, "Sap veins"),
                wt(rowan, "r7/moss", src: 0.8, deps: 3.3, .merged, days: 33, "Moss cover"),
            ]),
            Repo(name: arb, path: "\(home)/code/\(arb)", defaultBranch: "main", worktrees: [
                wt(arb, "main", main: true, src: 0.3, deps: 1.9, .clean, days: 0.1, "Progressive scan (D11)"),
                wt(arb, "worktree-first", src: 0.2, deps: 1.4, .dirty(9), days: 0.05, "Worktree-first map", at: "/private/tmp/arborist-worktree-first"),
            ]),
            Repo(name: "nettle", path: "\(home)/code/nettle", defaultBranch: "main", worktrees: [
                wt("nettle", "main", main: true, src: 1.6, deps: 3.6, .unpushed(1), days: 6, "Stem tables"),
            ]),
            Repo(name: "teasel", path: "\(home)/Documents/teasel", defaultBranch: "main", worktrees: [
                wt("teasel", "main", main: true, src: 0.05, deps: 0, .clean, days: 90, "Weekly notes"),
            ]),
        ]
        return ScanResult(scannedAt: now, roots: ["~", "/tmp"], volume: VolumeInfo(path: home, freeBytes: freeBytes, totalBytes: totalBytes),
                          repos: repos, caches: [CacheEntry(name: "pnpm", path: nil, bytes: gb(12.1)), CacheEntry(name: "npm", path: nil, bytes: gb(7.6)),
                                                 CacheEntry(name: "Homebrew", path: nil, bytes: gb(2.2))], skippedPaths: 0)
    }

    public static var groups: [LeafGroup] { LeafLayout.groups(from: scan) }
}

extension LeafSample {
    /// A busy machine (76 worktrees in 35 repos, 0 B prunable /tmp worktrees), for the declutter
    /// snapshots and label-collision tests (D13). Names match the landing-page demo. Deterministic.
    public static var busy: ScanResult {
        let names = ["orchard", "lantern", "tidepool", "quill", "willow-kit", "bramble", "sundial", "copperleaf", "heron-notes",
                     "hollyhock", "fernhill", "foxglove", "tansy", "nettle", "inkwell", "larkspur", "wicker", "saltmarsh",
                     "clover", "burrow", "acorn-cli", "meadowlark", "juniper", "cobble-ui", "mistral-docs", "sedge", "bracken",
                     "hazel", "birchwood", "yarrow", "teasel", "rowan", "sorrel", "mallow", "alder"]
        let counts = [6, 5, 4, 4, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
        let branches = ["fern-sync", "moss-cache", "dew-retry", "old-canopy", "twig-layout", "bark-tests", "acorn-ui",
                        "root-scan", "leaf-hover", "pollen-fix", "sprig-docs", "seedling", "grove-api", "thicket"]
        var seed: UInt64 = 7
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var repos: [Repo] = [], k = 0
        for (i, name) in names.enumerated() {
            var wts = [wt(name, i % 5 == 0 ? "master" : "main", main: true, src: 0.05 + rnd() * (i == 7 ? 4 : 0.9),
                          deps: i == 7 ? 14.8 : rnd() * 1.2, rnd() < 0.35 ? .dirty(Int(rnd() * 9) + 1) : .clean, days: rnd() * 20,
                          i == 7 ? "fix(canopy): keep the shaded leaves when the grove redraws after a long wind change" : "Merge main")]
            for j in 1..<counts[i] {
                k += 1
                let b = branches[k % branches.count] + (k >= branches.count ? "-\(k / branches.count + 1)" : "")
                let r = rnd()
                let st: S = r < 0.3 ? .dirty(Int(rnd() * 12) + 1) : r < 0.42 ? .unpushed(Int(rnd() * 4) + 1) : r < 0.5 ? .merged : .clean
                let tmp = k % 13 == 0
                var w = wt(name, b, src: tmp ? 0 : 0.02 + rnd() * 0.25, deps: tmp ? 0 : rnd() * (i == 1 && j == 1 ? 9 : 0.4), tmp ? .gone : st,
                           days: rnd() * 40, "Work on \(b)", at: tmp ? "/private/tmp/\(name)-\(b.replacingOccurrences(of: "/", with: "-"))" : nil)
                if tmp { w.staleReasons = [.prunable] }
                wts.append(w)
            }
            repos.append(Repo(name: name, path: "\(home)/code/\(name)", defaultBranch: "main", worktrees: wts))
        }
        return ScanResult(scannedAt: now, roots: ["~", "/tmp"], volume: VolumeInfo(path: "/", freeBytes: gb(225), totalBytes: gb(995)),
                          repos: repos, caches: [CacheEntry(name: "npm", path: "\(home)/.npm", bytes: gb(4.0)),
                                                  CacheEntry(name: "pnpm", path: "\(home)/Library/pnpm", bytes: gb(2.0)),
                                                  CacheEntry(name: "Homebrew", path: "\(home)/Library/Caches/Homebrew", bytes: gb(0.832)),
                                                  CacheEntry(name: "Xcode DerivedData", path: nil, bytes: gb(0.221))], skippedPaths: 3)
    }
}
