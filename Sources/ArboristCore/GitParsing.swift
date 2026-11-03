import Foundation

/// One record from `git worktree list --porcelain`.
public struct PorcelainWorktree: Equatable, Sendable {
    public var path: String
    public var head: String?
    public var branch: String?   // short name, e.g. "main"
    public var bare = false
    public var detached = false
    public var prunable = false
    public var locked = false
}

public enum GitParsing {
    /// Parses `git worktree list --porcelain` output. The first record is the main worktree.
    public static func parseWorktreeList(_ text: String) -> [PorcelainWorktree] {
        var result: [PorcelainWorktree] = []
        var cur: PorcelainWorktree?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty {
                if let c = cur { result.append(c) }
                cur = nil
                continue
            }
            let (key, value) = splitFirst(line)
            switch key {
            case "worktree":
                if let c = cur { result.append(c) }
                cur = PorcelainWorktree(path: value)
            case "HEAD": cur?.head = value
            case "branch": cur?.branch = shortRef(value)
            case "bare": cur?.bare = true
            case "detached": cur?.detached = true
            case "prunable": cur?.prunable = true
            case "locked": cur?.locked = true
            default: break
            }
        }
        if let c = cur { result.append(c) }
        return result
    }

    /// `refs/heads/feature/x` -> `feature/x`; `refs/remotes/origin/main` -> `main` when stripping a remote.
    public static func shortRef(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/origin/", "origin/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    /// `%(upstream:track)` is "[gone]" when the upstream branch was deleted.
    public static func isUpstreamGone(_ track: String) -> Bool {
        track.contains("gone")
    }

    /// Any non-empty `git status --porcelain` output means uncommitted or untracked changes.
    public static func isDirty(_ statusPorcelain: String) -> Bool {
        !statusPorcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func splitFirst(_ line: String) -> (String, String) {
        guard let sp = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<sp]), String(line[line.index(after: sp)...]))
    }

    /// Stale rule: merged into the default branch (and has its own commits), upstream gone, or git says prunable.
    public static func staleReasons(branch: String?, defaultBranch: String?, isMain: Bool,
                                    mergedIntoDefault: Bool, upstreamGone: Bool, prunable: Bool) -> [StaleReason] {
        var r: [StaleReason] = []
        if prunable { r.append(.prunable) }
        guard !isMain, let branch else { return r }
        if branch != defaultBranch && mergedIntoDefault { r.append(.merged) }
        if upstreamGone { r.append(.upstreamGone) }
        return r
    }
}
