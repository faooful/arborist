import Foundation

/// D28: a worktree whose `git worktree remove`/`prune` succeeded leaves the model at once (map, counts,
/// Clear N, Ready, totals and cache all derive from `ScanResult`). A background `git worktree list` of only
/// the affected repos then confirms it; one that is still listed is put back where it was and flagged.
public struct PendingRemoval: Equatable, Sendable {
    public var repoPath: String
    public var worktree: Worktree
    /// Its position in the repo's worktree list, so a rollback restores the same order.
    public var index: Int
    public var path: String { worktree.path }
}

public enum OptimisticRemoval {
    static func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Drops the worktrees at `paths` (only succeeded items: failed/skipped stay). Returns the new scan
    /// and what was dropped, for `confirm`. The main checkout is never dropped.
    public static func apply(_ r: ScanResult, removed paths: [String]) -> (ScanResult, [PendingRemoval]) {
        var out = r, pending: [PendingRemoval] = []
        for ri in out.repos.indices {
            var kept: [Worktree] = []
            for (i, w) in out.repos[ri].worktrees.enumerated() {
                if !w.isMain && paths.contains(where: { same($0, w.path) }) {
                    pending.append(PendingRemoval(repoPath: out.repos[ri].path, worktree: w, index: i))
                } else { kept.append(w) }
            }
            out.repos[ri].worktrees = kept
        }
        return (out, pending)
    }

    /// The repos to re-list: each affected repo once.
    public static func repos(_ pending: [PendingRemoval]) -> [String] {
        var seen: [String] = []
        for p in pending where !seen.contains(p.repoPath) { seen.append(p.repoPath) }
        return seen
    }

    /// `listed` = worktree paths `git worktree list` reports per affected repo (nil when the list failed:
    /// then nothing is decided, everything stays pending). A pending worktree still listed is restored.
    public static func confirm(_ r: ScanResult, pending: [PendingRemoval], listed: [String: [String]?])
        -> (result: ScanResult, confirmed: [String], restored: [String], undecided: [String]) {
        var out = r, confirmed: [String] = [], restored: [String] = [], undecided: [String] = []
        for p in pending.sorted(by: { $0.index < $1.index }) {
            guard let entry = listed[p.repoPath], let paths = entry else { undecided.append(p.path); continue }
            guard paths.contains(where: { same($0, p.path) }) else { confirmed.append(p.path); continue }
            if let ri = out.repos.firstIndex(where: { $0.path == p.repoPath }),
               !out.repos[ri].worktrees.contains(where: { same($0.path, p.path) }) {
                out.repos[ri].worktrees.insert(p.worktree, at: min(p.index, out.repos[ri].worktrees.count))
            }
            restored.append(p.path)
        }
        return (out, confirmed, restored, undecided)
    }

    /// `git worktree list --porcelain` paths for one repo, or nil if git failed.
    public static func list(_ repoPath: String) -> [String]? {
        guard let out = Shell.git(repoPath, "worktree", "list", "--porcelain") else { return nil }
        return GitParsing.parseWorktreeList(out).map(\.path)
    }

    /// Whether a removed path should drop a selection, hover or pin on it.
    public static func clears(_ selected: String?, removed: [PendingRemoval]) -> Bool {
        guard let s = selected else { return false }
        return removed.contains { same($0.path, s) }
    }
}
