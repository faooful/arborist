import Foundation

/// Which repos the popover shows (D18). Stored as the set of *excluded* repo paths, so repos that
/// disappear drop out quietly and new repos show by default.
public struct RepoFilter: Codable, Equatable, Hashable, Sendable {
    public var excluded: Set<String>

    public init(excluded: Set<String> = []) { self.excluded = excluded }

    public static let all = RepoFilter()
    /// UserDefaults key; the value is an array of repo paths.
    public static let defaultsKey = "arborist.excludedRepoPaths"

    public func includes(_ repoPath: String) -> Bool { !excluded.contains(repoPath) }
    public func includes(_ repo: Repo) -> Bool { includes(repo.path) }

    /// The scan with only the included repos. Everything downstream (layout, counts, Clear, List) uses this.
    public func apply(_ r: ScanResult) -> ScanResult {
        guard !excluded.isEmpty else { return r }
        var out = r
        out.repos = r.repos.filter(includes)
        return out
    }

    // MARK: Editing

    public mutating func selectAll() { excluded = [] }
    public mutating func selectNone(_ repos: [Repo]) { excluded = Set(repos.map(\.path)) }
    public mutating func toggle(_ repoPath: String) {
        if excluded.contains(repoPath) { excluded.remove(repoPath) } else { excluded.insert(repoPath) }
    }
    /// Option-click: only this repo.
    public mutating func only(_ repoPath: String, among repos: [Repo]) {
        excluded = Set(repos.map(\.path).filter { $0 != repoPath })
    }

    /// Only the repos whose name or path matches one of `names` (case-insensitive). For `--filter`.
    public static func only(names: [String], among repos: [Repo]) -> RepoFilter {
        let want = Set(names.map { $0.lowercased() })
        return RepoFilter(excluded: Set(repos.filter { !want.contains($0.name.lowercased()) && !want.contains($0.path.lowercased()) }.map(\.path)))
    }

    /// Drops exclusions for repos that are no longer in the scan.
    public func pruned(to repos: [Repo]) -> RepoFilter {
        RepoFilter(excluded: excluded.intersection(repos.map(\.path)))
    }

    // MARK: Display

    public func selected(_ repos: [Repo]) -> [Repo] { repos.filter(includes) }
    public func isEverything(_ repos: [Repo]) -> Bool { selected(repos).count == repos.count }
    public func isEmpty(_ repos: [Repo]) -> Bool { !repos.isEmpty && selected(repos).isEmpty }

    /// Button label: "All repos", the one repo's name, "N repos", or "No repos".
    public func label(_ repos: [Repo]) -> String {
        let s = selected(repos)
        if s.count == repos.count { return "All repos" }
        if s.isEmpty { return "No repos" }
        if s.count == 1 { return s[0].name }
        return "\(s.count) repos"
    }

    /// Show the search field above this many repos.
    public static let searchThreshold = 10

    /// Menu rows matching `query` (name or path, case-insensitive), in scan order.
    public static func matching(_ repos: [Repo], query: String) -> [Repo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
    }

    // MARK: Persistence

    public static func load(_ defaults: UserDefaults = .standard) -> RepoFilter {
        RepoFilter(excluded: Set(defaults.stringArray(forKey: defaultsKey) ?? []))
    }
    public func save(_ defaults: UserDefaults = .standard) {
        defaults.set(excluded.sorted(), forKey: Self.defaultsKey)
    }
}
