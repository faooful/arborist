import Foundation

/// Read-only scanner. Never deletes, moves, or writes anything inside scanned folders.
public final class Scanner {
    public let config: ArboristConfig
    public init(config: ArboristConfig = .load()) { self.config = config }

    /// Folders under the home folder that we never walk into unless they are a chosen root:
    /// they are huge, rarely hold repos, or trigger macOS privacy prompts.
    static let skipUnderHome: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "Desktop", "Downloads", "Public"]

    public func scan() -> ScanResult {
        let roots = config.expandedRoots
        var skipped = 0
        let repoRoots = discoverRepos(roots: roots, skipped: &skipped)

        // Resolve worktrees for each repo, de-duplicated by main worktree path.
        var seen = Set<String>()
        var pending: [(name: String, path: String, def: String?, wts: [PorcelainWorktree])] = []
        for dir in repoRoots {
            guard let text = Shell.git(dir, "worktree", "list", "--porcelain") else { continue }
            let wts = GitParsing.parseWorktreeList(text).filter { !$0.bare }
            guard let main = wts.first, !seen.contains(main.path) else { continue }
            seen.insert(main.path)
            pending.append((URL(fileURLWithPath: main.path).lastPathComponent, main.path, defaultBranch(main.path), wts))
        }

        // Measure every worktree in parallel.
        let flat = pending.enumerated().flatMap { (ri, r) in r.wts.enumerated().map { (ri, $0.offset, $0.element) } }
        let jobs = pending
        let out = Collector(count: flat.count)
        // Bounded parallelism keeps open pipes and disk thrash in check.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        for i in flat.indices {
            let (ri, wi, p) = flat[i]
            queue.addOperation {
                var s = 0
                let wt = self.inspect(p, isMain: wi == 0, repoPath: jobs[ri].path, defaultBranch: jobs[ri].def, skipped: &s)
                out.set(i, wt, skipped: s)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        let results = out.results
        let extraSkipped = out.skipped
        skipped += extraSkipped.reduce(0, +)

        var repos: [Repo] = pending.map { Repo(name: $0.name, path: $0.path, defaultBranch: $0.def, worktrees: []) }
        for (i, item) in flat.enumerated() { if let w = results[i] { repos[item.0].worktrees.append(w) } }
        for i in repos.indices {
            let main = repos[i].worktrees.first { $0.isMain }
            let rest = repos[i].worktrees.filter { !$0.isMain }.sorted { $0.size.total > $1.size.total }
            repos[i].worktrees = (main.map { [$0] } ?? []) + rest
        }
        repos.sort { $0.size.total > $1.size.total }

        let caches = Caches.scan(home: ArboristConfig.home, skipped: &skipped)
        return ScanResult(scannedAt: Date(), roots: roots, volume: DiskUsage.volume(for: ArboristConfig.home),
                          repos: repos, caches: caches, skippedPaths: skipped)
    }

    /// Walks roots to `maxDepth`, returning folders containing `.git` (a dir for repos, a file for linked worktrees).
    func discoverRepos(roots: [String], skipped: inout Int) -> [String] {
        let fm = FileManager.default
        let home = ArboristConfig.home
        let rootSet = Set(roots)
        var found: [String] = []
        var visited = Set<String>()
        func walk(_ dir: String, depth: Int) {
            guard visited.insert(dir).inserted else { return }
            if fm.fileExists(atPath: dir + "/.git") { found.append(dir); return }
            guard depth < config.maxDepth else { return }
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { skipped += 1; return }
            for name in items.sorted() {
                if name.hasPrefix(".") || DiskUsage.isRebuildable(name) { continue }
                let child = dir + "/" + name
                if dir == home && Self.skipUnderHome.contains(name) && !rootSet.contains(child) { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue else { continue }
                if let a = try? fm.attributesOfItem(atPath: child), a[.type] as? FileAttributeType == .typeSymbolicLink { continue }
                walk(child, depth: depth + 1)
            }
        }
        for r in roots { walk(r, depth: 0) }
        return found
    }

    func defaultBranch(_ repo: String) -> String? {
        if let r = Shell.git(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD") { return GitParsing.shortRef(r) }
        for b in ["main", "master"] where Shell.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(b)") != nil { return b }
        return nil
    }

    func inspect(_ p: PorcelainWorktree, isMain: Bool, repoPath: String, defaultBranch: String?, skipped: inout Int) -> Worktree {
        var w = Worktree(path: p.path, isMain: isMain, branch: p.detached ? nil : p.branch, head: p.head,
                         lastCommitDate: nil, dirty: false, unpushedCommits: nil, hasUpstream: false,
                         stale: false, staleReasons: [], size: SizeSplit(),
                         removeCommand: isMain ? nil : "git -C \(Shell.quote(repoPath)) worktree remove \(Shell.quote(p.path))")
        if p.prunable || !FileManager.default.fileExists(atPath: p.path) {
            w.staleReasons = [.prunable]; w.stale = true
            w.removeCommand = isMain ? nil : "git -C \(Shell.quote(repoPath)) worktree prune"
            return w
        }
        if let d = Shell.git(p.path, "log", "-1", "--format=%cI") { w.lastCommitDate = ISO8601DateFormatter().date(from: d) }
        w.dirty = GitParsing.isDirty(Shell.git(p.path, "status", "--porcelain") ?? "")

        var upstreamGone = false
        var merged = false
        if let b = w.branch {
            let info = Shell.git(p.path, "for-each-ref", "--format=%(upstream:short)|%(upstream:track)", "refs/heads/\(b)") ?? ""
            let parts = info.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let upstream = parts.first ?? ""
            upstreamGone = !upstream.isEmpty && GitParsing.isUpstreamGone(parts.count > 1 ? parts[1] : "")
            w.hasUpstream = !upstream.isEmpty && !upstreamGone
            if w.hasUpstream, let n = Shell.git(p.path, "rev-list", "--count", "@{u}..HEAD") { w.unpushedCommits = Int(n) }
            if let d = defaultBranch, b != d {
                let target = Shell.git(repoPath, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(d)") != nil ? "origin/\(d)" : d
                let ahead = Shell.git(repoPath, "rev-list", "--count", "\(target)..refs/heads/\(b)")
                let tip = Shell.git(repoPath, "rev-parse", "refs/heads/\(b)")
                let defTip = Shell.git(repoPath, "rev-parse", target)
                // Merged = no commits beyond the default branch. A branch sitting exactly on the default tip
                // counts only if it has moved since it was created (reflog > 1 entry), so a fresh branch isn't stale.
                let moved = (Shell.git(repoPath, "reflog", "--format=%H", "refs/heads/\(b)") ?? "")
                    .split(separator: "\n").count > 1
                merged = ahead == "0" && tip != nil && (tip != defTip || moved)
            }
        }
        w.staleReasons = GitParsing.staleReasons(branch: w.branch, defaultBranch: defaultBranch, isMain: isMain,
                                                 mergedIntoDefault: merged, upstreamGone: upstreamGone, prunable: false)
        w.stale = !w.staleReasons.isEmpty
        w.size = DiskUsage.measureWorktree(p.path, skipped: &skipped)
        return w
    }
}

/// Thread-safe slots for parallel worktree results.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [Worktree?]
    private(set) var skipped: [Int]
    init(count: Int) { results = Array(repeating: nil, count: count); skipped = Array(repeating: 0, count: count) }
    func set(_ i: Int, _ w: Worktree, skipped s: Int) { lock.lock(); results[i] = w; skipped[i] = s; lock.unlock() }
}
