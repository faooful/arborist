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

    public static func find(_ r: ScanResult, path: String) -> WorktreeRef? {
        for repo in r.repos { if let w = repo.worktrees.first(where: { $0.path == path }) { return WorktreeRef(worktree: w, repo: repo.name, repoPath: repo.path) } }
        return nil
    }
}

/// The hover card: everything about one worktree in short lines (D12). Read-only actions only.
public struct HoverCard: Equatable, Sendable {
    public var branch: String
    public var repo: String
    public var status: WorktreeStatus
    public var path: String
    public var lastCommit: String
    public var tracking: String
    public var uncommitted: String
    public var size: String
    public var action: String

    public init(_ ref: WorktreeRef, now: Date = Date(), home: String = ArboristConfig.home) {
        let w = ref.worktree
        branch = WorktreeLabel.branchName(w.branch, head: w.head)
        repo = ref.repo + (w.isMain ? " · main checkout" : "")
        status = w.status
        path = Format.shortPath(w.path, home: home)
        if let d = w.lastCommitDate {
            lastCommit = Format.age(d, now: now) + (w.lastCommitSubject.map { " · " + $0 } ?? "")
        } else {
            lastCommit = "no commits"
        }
        if let a = w.ahead, let b = w.behind, let u = w.upstream {
            tracking = "↑\(a) ↓\(b) vs \(u)"
        } else if w.staleReasons.contains(.upstreamGone) {
            tracking = "upstream deleted"
        } else {
            tracking = "no upstream"
        }
        let n = w.uncommittedFiles ?? (w.dirty ? 1 : 0)
        uncommitted = n == 0 ? "no uncommitted files" : "\(n) uncommitted file\(n == 1 ? "" : "s")"
        size = Format.bytes(w.size.total) + (w.size.rebuildable > 0 ? " · \(Format.bytes(w.size.rebuildable)) rebuildable" : "")
        action = w.isMain || w.removeCommand == nil ? "Click: Reveal in Finder" : "Click: Reveal · copy git worktree remove"
    }

    /// Lines in display order (title first).
    public var lines: [String] { ["\(branch) · \(status.word)", repo, path, lastCommit, tracking, uncommitted, size, action] }
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

    /// "Caches · pnpm 12.1 GB · npm 7.6 GB" (largest first, up to `max`).
    public static func cachesLine(_ caches: [CacheEntry], max: Int = 4) -> String? {
        let c = caches.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard !c.isEmpty else { return nil }
        var s = "Caches · " + c.prefix(max).map { "\($0.name) \(bytes($0.bytes))" }.joined(separator: " · ")
        if c.count > max { s += " · +\(c.count - max)" }
        return s
    }
}
