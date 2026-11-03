import Foundation

/// Read-only scanner. Never deletes, moves, or writes anything inside scanned folders.
public final class Scanner: Sendable {
    public let config: ArboristConfig
    public init(config: ArboristConfig = .load()) { self.config = config }

    /// Folders under the home folder that we never walk into unless they are a chosen root:
    /// they are huge, rarely hold repos, or trigger macOS privacy prompts.
    static let skipUnderHome: Set<String> = ["Library", "Applications", "Pictures", "Movies", "Music", "Desktop", "Downloads", "Public"]

    /// Blocking full scan. Same result as before progress events existed; the CLI uses this.
    public func scan() -> ScanResult { scan(cancel: nil) { _ in } }

    /// Blocking scan that reports progress as it goes (D11):
    /// `.volume` first (free space, instant), `.discovered(n)` once repos are found, `.repo` as each
    /// repo's worktrees are all measured (in completion order), `.caches`, then `.finished`.
    /// `onEvent` is called from worker threads. When `cancel` is set, workers stop early and the
    /// partial result is returned (callers that timed out ignore it).
    public func scan(cancel: CancelFlag?, onEvent: @escaping @Sendable (ScanEvent) -> Void) -> ScanResult {
        let roots = config.expandedRoots
        let volume = DiskUsage.volume(for: ArboristConfig.home)
        onEvent(.volume(volume))
        var skipped = 0
        let repoRoots = discoverRepos(roots: roots, skipped: &skipped)

        // Resolve worktrees for each repo, de-duplicated by main worktree path. A linked worktree's `.git`
        // file names its main repo, so worktrees of a repo already listed cost no git call (D12).
        var seen = Set<String>()
        var pending: [(name: String, path: String, git: RepoGit, wts: [PorcelainWorktree])] = []
        for found in repoRoots {
            if cancel?.isCancelled == true { break }
            if let m = found.mainRepo, seen.contains(m) { continue }
            guard let text = Shell.git(found.path, "worktree", "list", "--porcelain") else { continue }
            let wts = GitParsing.parseWorktreeList(text).filter { !$0.bare }
            guard let main = wts.first, !seen.contains(main.path) else { continue }
            seen.insert(main.path)
            if let m = found.mainRepo { seen.insert(m) }
            if found.mainRepo == nil { seen.insert(found.path) }
            pending.append((URL(fileURLWithPath: main.path).lastPathComponent, main.path, repoGit(main.path), wts))
        }
        onEvent(.discovered(repos: pending.count))

        // Measure every worktree in parallel; a repo is published when its last worktree finishes.
        let flat = pending.enumerated().flatMap { (ri, r) in r.wts.enumerated().map { (ri, $0.offset, $0.element) } }
        let jobs = pending
        let out = Collector(count: flat.count, perRepo: pending.map { $0.wts.count })
        let shells = pending.map { Repo(name: $0.name, path: $0.path, defaultBranch: $0.git.defaultBranch, worktrees: []) }
        // Bounded parallelism keeps open pipes and disk thrash in check.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        for i in flat.indices {
            let (ri, wi, p) = flat[i]
            queue.addOperation {
                if cancel?.isCancelled == true { return }
                var s = 0
                let wt = self.inspect(p, isMain: wi == 0, repoPath: jobs[ri].path, git: jobs[ri].git,
                                      skipped: &s, cancel: cancel)
                if let (wts, done) = out.set(i, repo: ri, wt, skipped: s) {
                    var repo = shells[ri]
                    repo.worktrees = Self.ordered(wts)
                    onEvent(.repo(repo, done: done, total: shells.count))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        skipped += out.skipped.reduce(0, +)

        var repos = shells
        for (i, item) in flat.enumerated() { if let w = out.results[i] { repos[item.0].worktrees.append(w) } }
        for i in repos.indices { repos[i].worktrees = Self.ordered(repos[i].worktrees) }
        repos.sort { $0.size.total > $1.size.total }

        let caches = cancel?.isCancelled == true ? [] : Caches.scan(home: ArboristConfig.home, skipped: &skipped, cancel: cancel)
        onEvent(.caches(caches))
        let result = ScanResult(scannedAt: Date(), roots: roots, volume: volume,
                                repos: repos, caches: caches, skippedPaths: skipped)
        onEvent(.finished(result))
        return result
    }

    /// Async scan with a deadline. Events arrive on the stream returned by `events(timeout:)`, or
    /// via `onEvent`. Throws `ScanError.timedOut` if the scan doesn't finish in `timeout` seconds;
    /// the worker is told to stop and its late result is dropped.
    public func scan(timeout: TimeInterval, onEvent: @escaping @Sendable (ScanEvent) -> Void = { _ in }) async throws -> ScanResult {
        try await Deadline.run(timeout: timeout) { cancel in
            self.scan(cancel: cancel) { e in if !cancel.isCancelled { onEvent(e) } }
        }
    }

    /// Progress as an AsyncStream. Ends after `.finished`, or with a `.failed` event on timeout.
    public func events(timeout: TimeInterval) -> AsyncStream<ScanEvent> {
        AsyncStream { cont in
            let task = Task {
                do { _ = try await self.scan(timeout: timeout) { cont.yield($0) } }
                catch { cont.yield(.failed(ScanError.describe(error))) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    static func ordered(_ wts: [Worktree]) -> [Worktree] {
        let main = wts.first { $0.isMain }
        let rest = wts.filter { !$0.isMain }.sorted { $0.size.total > $1.size.total }
        return (main.map { [$0] } ?? []) + rest
    }

    /// A folder holding `.git`, and for a linked worktree the main repo its `.git` file points to.
    struct FoundRepo: Equatable { var path: String; var mainRepo: String? }

    /// Roots with `~` expanded and symlinks resolved (so /tmp and /private/tmp are one root); missing ones dropped.
    func resolvedRoots(_ roots: [String]) -> [String] {
        var out: [String] = []
        for r in roots {
            let p = URL(fileURLWithPath: r).resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// Walks roots to `maxDepth`, returning folders containing `.git` (a dir for repos, a file for linked
    /// worktrees). Hidden folders, rebuildable folders and heavy home folders (Library, …) are skipped,
    /// symlinks are not followed, and folders we may not read are skipped quietly (no Full Disk Access).
    func discoverRepos(roots: [String], skipped: inout Int) -> [FoundRepo] {
        let home = ArboristConfig.home
        let resolved = resolvedRoots(roots)
        let rootSet = Set(resolved)
        var found: [FoundRepo] = []
        var visited = Set<String>()
        func walk(_ dir: String, depth: Int) {
            guard visited.insert(dir).inserted else { return }
            guard let entries = DirLister.list(dir) else { skipped += 1; return }
            if let git = entries.first(where: { $0.name == ".git" }) {
                var main: String?
                if git.kind == .file, let text = try? String(contentsOfFile: dir + "/.git", encoding: .utf8) {
                    main = GitParsing.mainRepo(fromGitFile: text, relativeTo: dir)
                }
                found.append(FoundRepo(path: dir, mainRepo: main))
                return
            }
            guard depth < config.maxDepth else { return }
            for e in entries.sorted(by: { $0.name < $1.name }) where e.kind == .dir {
                let name = e.name
                if name.hasPrefix(".") || DiskUsage.isRebuildable(name) || Self.skipAnywhere.contains(name) { continue }
                let child = dir == "/" ? "/" + name : dir + "/" + name
                if dir == home && Self.skipUnderHome.contains(name) && !rootSet.contains(child) { continue }
                walk(child, depth: depth + 1)
            }
        }
        for r in resolved { walk(r, depth: 0) }
        return found
    }

    /// Heavy folders that never hold repos worth listing, at any depth.
    static let skipAnywhere: Set<String> = ["Pods", "vendor", "__pycache__", "site-packages", "bower_components"]

    /// Per-repo git facts, read once and shared by all of the repo's worktrees (D12).
    struct RepoGit: Sendable {
        var defaultBranch: String?
        /// Branches whose commits are all in the default branch, and every branch's tip.
        var merged: Set<String> = []
        var tips: [String: String] = [:]
        var defaultTip: String?
    }

    func repoGit(_ repo: String) -> RepoGit {
        var g = RepoGit(defaultBranch: defaultBranch(repo))
        guard let d = g.defaultBranch else { return g }
        let target = Shell.git(repo, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(d)") != nil ? "origin/\(d)" : d
        g.defaultTip = Shell.git(repo, "rev-parse", "--verify", "--quiet", target)
        for line in (Shell.git(repo, "for-each-ref", "--format=%(refname:short)\u{1f}%(objectname)", "refs/heads") ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            if parts.count == 2 { g.tips[parts[0]] = parts[1] }
        }
        if g.defaultTip != nil {
            g.merged = Set((Shell.git(repo, "for-each-ref", "--merged=\(target)", "--format=%(refname:short)", "refs/heads") ?? "")
                .split(separator: "\n").map(String.init))
        }
        return g
    }

    func defaultBranch(_ repo: String) -> String? {
        if let r = Shell.git(repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD") { return GitParsing.shortRef(r) }
        for b in ["main", "master"] where Shell.git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/\(b)") != nil { return b }
        return nil
    }

    /// Two git calls per worktree (status v2 and log -1); a third (reflog) only for a branch sitting
    /// exactly on the default tip.
    func inspect(_ p: PorcelainWorktree, isMain: Bool, repoPath: String, git: RepoGit, skipped: inout Int, cancel: CancelFlag? = nil) -> Worktree {
        var w = Worktree(path: p.path, isMain: isMain, branch: p.detached ? nil : p.branch, head: p.head,
                         lastCommitDate: nil, dirty: false, unpushedCommits: nil, hasUpstream: false,
                         stale: false, staleReasons: [], size: SizeSplit(),
                         removeCommand: isMain ? nil : "git -C \(Shell.quote(repoPath)) worktree remove \(Shell.quote(p.path))")
        if p.locked { w.locked = true }
        if p.prunable || !FileManager.default.fileExists(atPath: p.path) {
            w.staleReasons = [.prunable]; w.stale = true
            w.removeCommand = isMain ? nil : "git -C \(Shell.quote(repoPath)) worktree prune"
            return w
        }
        if let d = Shell.git(p.path, "log", "-1", "--format=%cI%x1f%s") {
            let parts = d.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            w.lastCommitDate = ISO8601DateFormatter().date(from: parts[0])
            if parts.count > 1, !parts[1].isEmpty { w.lastCommitSubject = parts[1] }
        }
        let st = GitParsing.parseStatusV2(Shell.git(p.path, "status", "--porcelain=v2", "--branch") ?? "")
        w.dirty = st.files > 0
        w.uncommittedFiles = st.files
        w.upstream = st.upstreamGone ? nil : st.upstream
        w.hasUpstream = st.upstream != nil && !st.upstreamGone
        if w.hasUpstream { w.unpushedCommits = st.ahead; w.ahead = st.ahead; w.behind = st.behind }

        var merged = false
        if let b = w.branch, let d = git.defaultBranch, b != d, let tip = git.tips[b], git.merged.contains(b) {
            // Merged = no commits beyond the default branch. A branch sitting exactly on the default tip
            // counts only if it has moved since it was created (reflog > 1 entry), so a fresh branch isn't stale.
            let moved = tip != git.defaultTip || (Shell.git(repoPath, "reflog", "--format=%H", "refs/heads/\(b)") ?? "")
                .split(separator: "\n").count > 1
            merged = moved
        }
        w.staleReasons = GitParsing.staleReasons(branch: w.branch, defaultBranch: git.defaultBranch, isMain: isMain,
                                                 mergedIntoDefault: merged, upstreamGone: st.upstreamGone, prunable: false)
        w.stale = !w.staleReasons.isEmpty
        w.size = DiskUsage.measureWorktree(p.path, skipped: &skipped, cancel: cancel)
        return w
    }
}

/// Thread-safe slots for parallel worktree results, plus per-repo completion tracking.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var results: [Worktree?]
    private(set) var skipped: [Int]
    private var remaining: [Int]
    private var byRepo: [[Worktree]]
    private var reposDone = 0
    init(count: Int, perRepo: [Int]) {
        results = Array(repeating: nil, count: count); skipped = Array(repeating: 0, count: count)
        remaining = perRepo; byRepo = perRepo.map { _ in [] }
    }
    /// Stores one result; returns the repo's worktrees and the done count when this was its last one.
    func set(_ i: Int, repo: Int, _ w: Worktree, skipped s: Int) -> ([Worktree], Int)? {
        lock.lock(); defer { lock.unlock() }
        results[i] = w; skipped[i] = s
        byRepo[repo].append(w)
        remaining[repo] -= 1
        guard remaining[repo] == 0 else { return nil }
        reposDone += 1
        return (byRepo[repo], reposDone)
    }
}
