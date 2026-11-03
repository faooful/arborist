import Foundation

/// The legend's states (D21). The first three match the leaf colours; `ready` is exactly what Clear would remove.
public enum StateKey: String, CaseIterable, Codable, Sendable {
    case uncommitted, clean, stale, ready

    /// The leaf colour state of a worktree (same mapping as LeafLayout).
    public static func colour(_ w: Worktree) -> StateKey {
        switch w.status {
        case .uncommitted, .unpushed: .uncommitted
        case .clean: .clean
        case .merged, .stale: .stale
        }
    }
    public var title: String {
        switch self {
        case .uncommitted: "Uncommitted / unpushed"
        case .clean: "Clean"
        case .stale: "Merged / stale"
        case .ready: "Ready to clean"
        }
    }
    /// Parses `--state ready|uncommitted|clean|stale` (also "protected", "unpushed", "merged").
    public static func parse(_ s: String) -> StateKey? {
        switch s.lowercased() {
        case "protected", "unpushed": .uncommitted
        case "merged": .stale
        default: StateKey(rawValue: s.lowercased())
        }
    }
}

/// Which worktree states are shown (D21). Session-only: never persisted, so every launch starts at "all".
/// Colour states are toggled on and off; `ready` is a mode that shows only the worktrees Clear would remove
/// (the `CleanupSafety` predicate), so its count always equals Clear N.
public struct StateFilter: Equatable, Hashable, Sendable {
    public var hidden: Set<StateKey>
    public var readyOnly: Bool

    public init(hidden: Set<StateKey> = [], readyOnly: Bool = false) {
        self.hidden = hidden.subtracting([.ready]); self.readyOnly = readyOnly
    }
    public static let all = StateFilter()

    public var isAll: Bool { hidden.isEmpty && !readyOnly }

    /// The legend item looks selected.
    public func isActive(_ k: StateKey) -> Bool {
        k == .ready ? readyOnly : (!readyOnly && !hidden.contains(k))
    }

    public func includes(_ w: Worktree) -> Bool {
        readyOnly ? CleanupSafety.isReady(w) : !hidden.contains(StateKey.colour(w))
    }

    /// Click: toggle one state. Clicking `ready` turns the ready-only view on or off; clicking a colour while
    /// ready-only is on leaves ready-only and shows just that colour.
    public mutating func toggle(_ k: StateKey) {
        if k == .ready { self = readyOnly ? .all : StateFilter(readyOnly: true); return }
        if readyOnly { self = .only(k); return }
        if hidden.contains(k) { hidden.remove(k) } else { hidden.insert(k) }
    }
    /// Option-click: only this state.
    public static func only(_ k: StateKey) -> StateFilter {
        k == .ready ? StateFilter(readyOnly: true) : StateFilter(hidden: Set(StateKey.allCases).subtracting([k, .ready]))
    }
    public mutating func showAll() { self = .all }

    /// `--state a,b`: the union of those states. `ready` (alone or with others) means ready-only.
    public static func parse(_ list: String) -> StateFilter? {
        let keys = list.split(separator: ",").map { StateKey.parse(String($0)) }
        guard !keys.isEmpty, keys.allSatisfy({ $0 != nil }) else { return nil }
        let set = Set(keys.compactMap { $0 })
        if set.contains(.ready) { return StateFilter(readyOnly: true) }
        return StateFilter(hidden: Set(StateKey.allCases).subtracting(set))
    }
}

/// What the popover shows (D21): repo filter AND state filter. The layout, counts, List and `Cleanup.plan`
/// all take the result of `apply`, so Clear N is always the safe set within what's visible.
public struct VisibleSet: Equatable, Hashable, Sendable {
    public var repos: RepoFilter
    public var states: StateFilter

    public init(repos: RepoFilter = .all, states: StateFilter = .all) { self.repos = repos; self.states = states }

    public func apply(_ r: ScanResult) -> ScanResult {
        var out = repos.apply(r)
        guard !states.isAll else { return out }
        out.repos = out.repos.compactMap { repo in
            var x = repo
            x.worktrees = repo.worktrees.filter(states.includes)
            return x.worktrees.isEmpty ? nil : x
        }
        return out
    }

    /// Legend count for a state within the repo filter (ignoring the state filter), so "Ready to clean (N)"
    /// equals Clear N whenever ready-only or no state filter is on.
    public func count(_ k: StateKey, in r: ScanResult) -> Int {
        repos.apply(r).repos.reduce(0) { n, repo in
            n + repo.worktrees.filter { k == .ready ? CleanupSafety.isReady($0) : StateKey.colour($0) == k }.count
        }
    }

    /// What a fresh launch shows: the persisted repo filter, every state (the state filter is session-only).
    public static func atLaunch(_ defaults: UserDefaults = .standard) -> VisibleSet {
        VisibleSet(repos: RepoFilter.load(defaults), states: .all)
    }

    /// The scan has worktrees but the filters leave none.
    public func nothingMatches(_ r: ScanResult) -> Bool { r.worktreeCount > 0 && apply(r).worktreeCount == 0 }
}
