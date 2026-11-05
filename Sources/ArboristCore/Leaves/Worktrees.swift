import Foundation

/// Worktree-first presentation shared by the app, the SVG renderer and the tests (D12).
public enum WorktreeLabel {
    /// "feat-t5b-handover · property-management". A detached HEAD shows its short hash.
    public static func text(branch: String?, head: String? = nil, repo: String) -> String {
        "\(branchName(branch, head: head)) · \(repo)"
    }
    public static func branchName(_ branch: String?, head: String? = nil) -> String {
        if let branch { return branch }
        if let h = head, h.count >= 7 { return "detached @\(h.prefix(7))" }
        return "detached"
    }
}

/// One worktree with the repo it belongs to.
public struct WorktreeRef: Equatable, Sendable {
    public var worktree: Worktree
    public var repo: String
    public var repoPath: String
    public var label: String { WorktreeLabel.text(branch: worktree.branch, head: worktree.head, repo: repo) }
}

public enum WorktreeList {
    /// Every worktree across all repos, sorted by state (uncommitted, unpushed, merged, stale, clean),
    /// then by age (most recent commit first; unknown dates last), then by label for a stable order.
    public static func sorted(_ r: ScanResult) -> [WorktreeRef] {
        let all = r.repos.flatMap { repo in repo.worktrees.map { WorktreeRef(worktree: $0, repo: repo.name, repoPath: repo.path) } }
        return all.sorted { a, b in
            let ra = a.worktree.status.rank, rb = b.worktree.status.rank
            if ra != rb { return ra < rb }
            let da = a.worktree.lastCommitDate ?? .distantPast, db = b.worktree.lastCommitDate ?? .distantPast
            if da != db { return da > db }
            return a.label < b.label
        }
    }

    /// Exact match first; otherwise by resolved path, because git records worktrees by their real path
    /// (on macOS /tmp and /var/folders are symlinks into /private).
    public static func find(_ r: ScanResult, path: String) -> WorktreeRef? {
        for repo in r.repos { if let w = repo.worktrees.first(where: { $0.path == path }) { return WorktreeRef(worktree: w, repo: repo.name, repoPath: repo.path) } }
        let want = resolved(path)
        for repo in r.repos { if let w = repo.worktrees.first(where: { resolved($0.path) == want }) { return WorktreeRef(worktree: w, repo: repo.name, repoPath: repo.path) } }
        return nil
    }
    static func resolved(_ p: String) -> String { URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path }
}

/// The hover card (D13): a header (branch, state pill, repo, path), a 2×2 stats grid, the commit
/// message and footer buttons. Display strings only; the views lay them out.
public struct HoverCard: Equatable, Sendable {
    public var branch: String
    public var status: WorktreeStatus
    /// "Uncommitted", "Unpushed", "Merged", "Stale", "Clean".
    public var pill: String
    public var repo: String
    /// `~`-shortened and middle-abbreviated to fit; `fullPath` is the tooltip.
    public var path: String
    public var fullPath: String
    public var size: String
    /// 0…1 share of `size` that is rebuildable, for the mini bar; `rebuildable` is its caption.
    public var rebuildableShare: Double
    public var rebuildable: String?
    public var changes: String
    public var sync: String
    public var lastCommit: String
    /// Commit subject wrapped at word boundaries, at most 2 lines.
    public var message: [String]
    public var removeCommand: String?

    public static let pathChars = 38, messageChars = 40

    public init(_ ref: WorktreeRef, now: Date = Date(), home: String = ArboristConfig.home) {
        let w = ref.worktree
        branch = WorktreeLabel.branchName(w.branch, head: w.head)
        status = w.status
        pill = w.status.word.prefix(1).uppercased() + w.status.word.dropFirst()
        repo = ref.repo + (w.isMain ? " · main checkout" : "")
        fullPath = w.path
        path = Format.middle(Format.shortPath(w.path, home: home), max: Self.pathChars)
        size = Format.bytes(w.size.total)
        rebuildableShare = w.size.total > 0 ? min(1, max(0, Double(w.size.rebuildable) / Double(w.size.total))) : 0
        rebuildable = w.size.rebuildable > 0 ? "\(Format.bytes(w.size.rebuildable)) rebuildable" : nil
        let n = w.uncommittedFiles ?? (w.dirty ? 1 : 0)
        changes = Format.files(n)
        sync = Format.sync(ahead: w.ahead, behind: w.behind, hasUpstream: w.upstream != nil,
                           gone: w.staleReasons.contains(.upstreamGone))
            + (w.mergeNote.map { " · \($0)" } ?? "") // D31: "PR #12 merged" / "squash-merged"
        lastCommit = w.lastCommitDate.map { Format.age($0, now: now) } ?? "No commits"
        message = Format.wrap(w.lastCommitSubject ?? "", width: Self.messageChars, maxLines: 2)
        removeCommand = w.isMain ? nil : w.removeCommand
    }

    /// Text in reading order, for accessibility and simple renderers.
    public var lines: [String] {
        ["\(branch) · \(pill)", repo, path, "Size \(size)", "Changes \(changes)", "Sync \(sync)", "Last commit \(lastCommit)"] + message
    }
}

extension Format {
    /// "5 files", "1 file", "None".
    public static func files(_ n: Int) -> String { n == 0 ? "None" : "\(n) file\(n == 1 ? "" : "s")" }

    /// "1 ahead · 766 behind", "2 ahead", "Up to date", "Upstream deleted", "No upstream".
    public static func sync(ahead: Int?, behind: Int?, hasUpstream: Bool, gone: Bool) -> String {
        if gone { return "Upstream deleted" }
        guard hasUpstream, ahead != nil || behind != nil else { return "No upstream" }
        let parts = [(ahead ?? 0, "ahead"), (behind ?? 0, "behind")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Up to date" : parts.joined(separator: " · ")
    }

    /// Shortens in the middle at a path separator where possible: "~/code/very/long/…/repo/branch".
    public static func middle(_ s: String, max n: Int) -> String {
        guard s.count > n, n > 4 else { return s }
        let keepEnd = (n - 1) * 3 / 5, keepStart = n - 1 - keepEnd
        var head = String(s.prefix(keepStart)), tail = String(s.suffix(keepEnd))
        if let i = head.lastIndex(of: "/"), head.distance(from: head.startIndex, to: i) >= keepStart / 2 { head = String(head[...i]) }
        if let i = tail.firstIndex(of: "/"), tail.distance(from: tail.startIndex, to: i) <= keepEnd / 2 { tail = String(tail[i...]) }
        return head + "…" + tail
    }

    /// Wraps at spaces into at most `maxLines` of `width` characters. When text is left over, the last
    /// line ends at a word boundary with "…". A single word longer than a line is cut with "…".
    public static func wrap(_ text: String, width: Int, maxLines: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var lines: [String] = [], cur = "", i = 0
        while i < words.count {
            let w = words[i]
            if cur.isEmpty { cur = w.count > width ? String(w.prefix(width - 1)) + "…" : w; i += 1; continue }
            if cur.count + 1 + w.count <= width { cur += " " + w; i += 1; continue }
            lines.append(cur); cur = ""
            if lines.count == maxLines { break }
        }
        if !cur.isEmpty && lines.count < maxLines { lines.append(cur) }
        if i < words.count, var last = lines.popLast() {
            while last.count + 1 > width, let sp = last.lastIndex(of: " ") { last = String(last[..<sp]) }
            lines.append(last.hasSuffix("…") ? last : last + "…")
        }
        return lines
    }
}

extension Format {
    /// "just now", "5 min ago", "3 h ago", "2 days ago", "5 weeks ago", "4 months ago", "2 years ago".
    public static func age(_ d: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(d))
        func n(_ v: Double, _ unit: String) -> String { let i = Int(v); return "\(i) \(unit)\(i == 1 ? "" : "s") ago" }
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        case ..<(86400 * 14): return n(s / 86400, "day")
        case ..<(86400 * 60): return n(s / (86400 * 7), "week")
        case ..<(86400 * 365): return n(s / (86400 * 30), "month")
        default: return n(s / (86400 * 365), "year")
        }
    }

    /// `/Users/joseph/code/x` -> `~/code/x`.
    public static func shortPath(_ p: String, home: String = ArboristConfig.home) -> String {
        p == home ? "~" : (p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p)
    }

    /// Short footer form (D13): "Caches 7.1 GB". The per-cache list is in the List and the CLI.
    public static func cachesTotal(_ caches: [CacheEntry]) -> String? {
        let t = caches.reduce(Int64(0)) { $0 + max(0, $1.bytes) }
        return t > 0 ? "Caches \(bytes(t))" : nil
    }

    /// "Caches · pnpm 12.1 GB · npm 7.6 GB" (largest first, up to `max`).
    public static func cachesLine(_ caches: [CacheEntry], max: Int = 4) -> String? {
        let c = caches.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !c.isEmpty else { return nil }
        var s = "Caches · " + c.prefix(max).map { "\($0.name) \(bytes($0.bytes))" }.joined(separator: " · ")
        if c.count > max { s += " · +\(c.count - max)" }
        return s
    }
}
