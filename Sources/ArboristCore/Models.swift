import Foundation

/// Bytes split into space that tools can regenerate and everything else.
public struct SizeSplit: Codable, Equatable, Sendable {
    public var rebuildable: Int64
    public var source: Int64
    public var total: Int64 { rebuildable + source }
    public init(rebuildable: Int64 = 0, source: Int64 = 0) {
        self.rebuildable = rebuildable
        self.source = source
    }
    enum CodingKeys: String, CodingKey { case rebuildable, source, total }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rebuildable, forKey: .rebuildable)
        try c.encode(source, forKey: .source)
        try c.encode(total, forKey: .total)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rebuildable = try c.decode(Int64.self, forKey: .rebuildable)
        source = try c.decode(Int64.self, forKey: .source)
    }
}

public enum StaleReason: String, Codable, Sendable {
    case merged      // branch fully merged into the default branch
    case upstreamGone // upstream branch was deleted
    case prunable    // git reports the worktree directory is missing
}

public struct Worktree: Codable, Equatable, Sendable {
    public var path: String
    public var isMain: Bool
    public var branch: String?      // nil when detached
    public var head: String?
    public var lastCommitDate: Date?
    public var dirty: Bool
    public var unpushedCommits: Int? // nil when there is no upstream
    public var hasUpstream: Bool
    public var stale: Bool
    public var staleReasons: [StaleReason]
    public var size: SizeSplit
    /// Read-only helper: the command a person could run to remove this worktree. Never executed.
    public var removeCommand: String?
    // Added in D12 (optional, so older JSON and caches still decode).
    /// Subject line of the last commit.
    public var lastCommitSubject: String?
    /// Upstream branch, e.g. "origin/feat-x".
    public var upstream: String?
    /// Commits ahead of / behind the upstream (nil without one).
    public var ahead: Int?
    public var behind: Int?
    /// Changed plus untracked files, from `git status`.
    public var uncommittedFiles: Int?

    /// One word for the worktree's state, most urgent first (D12).
    public var status: WorktreeStatus {
        if dirty { return .uncommitted }
        if (unpushedCommits ?? 0) > 0 { return .unpushed }
        if staleReasons.contains(.merged) { return .merged }
        if stale { return .stale }
        return .clean
    }
}

/// Worktree state as shown on leaves, cards and the list (D12). Uncommitted and unpushed work wins over
/// "merged/stale" so a worktree with work in it is never shown as safe to clear.
public enum WorktreeStatus: String, Codable, Sendable, CaseIterable {
    case uncommitted, unpushed, merged, stale, clean
    public var word: String { rawValue }
    /// Sort rank for the list: work in progress first, then cleanup candidates, then clean.
    public var rank: Int {
        switch self { case .uncommitted: 0; case .unpushed: 1; case .merged: 2; case .stale: 3; case .clean: 4 }
    }
}

public struct Repo: Codable, Equatable, Sendable {
    public var name: String
    public var path: String          // main worktree
    public var defaultBranch: String?
    public var worktrees: [Worktree]
    public var size: SizeSplit {
        worktrees.reduce(SizeSplit()) { SizeSplit(rebuildable: $0.rebuildable + $1.size.rebuildable, source: $0.source + $1.size.source) }
    }
    enum CodingKeys: String, CodingKey { case name, path, defaultBranch, worktrees, size }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        try c.encode(worktrees, forKey: .worktrees)
        try c.encode(size, forKey: .size)
    }
    public init(name: String, path: String, defaultBranch: String?, worktrees: [Worktree]) {
        self.name = name; self.path = path; self.defaultBranch = defaultBranch; self.worktrees = worktrees
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        worktrees = try c.decode([Worktree].self, forKey: .worktrees)
    }
}

public struct CacheEntry: Codable, Equatable, Sendable {
    public var name: String
    public var path: String?
    public var bytes: Int64
}

public struct VolumeInfo: Codable, Equatable, Sendable {
    public var path: String
    public var freeBytes: Int64
    public var totalBytes: Int64
}

public struct ScanResult: Codable, Equatable, Sendable {
    public var scannedAt: Date
    public var roots: [String]
    public var volume: VolumeInfo?
    public var repos: [Repo]          // largest first
    public var caches: [CacheEntry]   // largest first
    public var skippedPaths: Int      // unreadable paths that were skipped

    public var totals: Totals {
        let r = repos.reduce(SizeSplit()) { SizeSplit(rebuildable: $0.rebuildable + $1.size.rebuildable, source: $0.source + $1.size.source) }
        return Totals(projectsSource: r.source, projectsRebuildable: r.rebuildable,
                      caches: caches.reduce(0) { $0 + $1.bytes },
                      staleWorktrees: repos.flatMap(\.worktrees).filter(\.stale).count)
    }
    public struct Totals: Codable, Equatable, Sendable {
        public var projectsSource: Int64
        public var projectsRebuildable: Int64
        public var caches: Int64
        public var staleWorktrees: Int
    }
    enum CodingKeys: String, CodingKey { case scannedAt, roots, volume, repos, caches, skippedPaths, totals }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scannedAt, forKey: .scannedAt)
        try c.encode(roots, forKey: .roots)
        try c.encodeIfPresent(volume, forKey: .volume)
        try c.encode(totals, forKey: .totals)
        try c.encode(repos, forKey: .repos)
        try c.encode(caches, forKey: .caches)
        try c.encode(skippedPaths, forKey: .skippedPaths)
    }
    public init(scannedAt: Date, roots: [String], volume: VolumeInfo?, repos: [Repo], caches: [CacheEntry], skippedPaths: Int) {
        self.scannedAt = scannedAt; self.roots = roots; self.volume = volume; self.repos = repos; self.caches = caches; self.skippedPaths = skippedPaths
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scannedAt = try c.decode(Date.self, forKey: .scannedAt)
        roots = try c.decode([String].self, forKey: .roots)
        volume = try c.decodeIfPresent(VolumeInfo.self, forKey: .volume)
        repos = try c.decode([Repo].self, forKey: .repos)
        caches = try c.decode([CacheEntry].self, forKey: .caches)
        skippedPaths = try c.decode(Int.self, forKey: .skippedPaths)
    }

    public var worktreeCount: Int { repos.reduce(0) { $0 + $1.worktrees.count } }

    /// Header line, e.g. "40 worktrees in 34 repos · 5 stale" (D12).
    public var headline: String {
        let w = worktreeCount, r = repos.count, s = totals.staleWorktrees
        var t = "\(w) worktree\(w == 1 ? "" : "s") in \(r) repo\(r == 1 ? "" : "s")"
        if s > 0 { t += " · \(s) stale" }
        return t
    }

    public func jsonData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }
    public static func decode(_ data: Data) throws -> ScanResult {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ScanResult.self, from: data)
    }
}
