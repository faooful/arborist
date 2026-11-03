import Foundation

/// The H8 example data, used for the Linux snapshot and tests.
public enum LeafSample {
    static func gb(_ v: Double) -> Int64 { Int64(v * 1e9) }
    static func item(_ name: String, _ g: Double, _ kind: LeafKind, _ st: LeafState) -> LeafItem {
        LeafItem(id: name + "-\(g)", name: name, bytes: gb(g), kind: kind, state: st, path: "/Users/joseph/code/" + name,
                 removeCommand: kind == .worktree ? "git worktree remove /Users/joseph/code/\(name)" : nil)
    }
    public static let freeBytes = gb(118)
    public static let totalBytes = gb(1000)
    public static var groups: [LeafGroup] {
        [
            LeafGroup(name: "property-mgmt", items: [item("main", 9.4, .main, .protected), item("feat-t5b-handover", 6.2, .worktree, .protected),
                                                     item("qa1103-forms", 4.8, .worktree, .clean), item("fix-inventory-overlap", 3.9, .worktree, .stale),
                                                     item("node_modules", 11.2, .deps, .deps)]),
            LeafGroup(name: "farm", items: [item("main", 9.1, .main, .protected), item("expedition-roam", 7.2, .worktree, .protected),
                                            item("r8/oil", 5.4, .worktree, .stale), item("r7/terrain", 4.1, .worktree, .stale), item("node_modules", 14.0, .deps, .deps)]),
            LeafGroup(name: "arborist", items: [item("main", 4.6, .main, .protected), item("v1-scanner", 2.9, .worktree, .clean), item(".build", 3.8, .deps, .deps)]),
            LeafGroup(name: "drift", items: [item("main", 5.2, .main, .clean)]),
            LeafGroup(name: "Caches", items: [item("pnpm", 12.1, .cache, .clean), item("npm", 7.6, .cache, .clean)]),
            LeafGroup(name: "free", items: [LeafItem(id: "free", name: "Free", bytes: gb(118 * 0.42), kind: .free, state: .free)]),
        ]
    }
}
