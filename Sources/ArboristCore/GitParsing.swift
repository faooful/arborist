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

    /// Parsed `git status --porcelain=v2 --branch` (one call replaces status, for-each-ref and rev-list, D12).
    public struct StatusV2: Equatable, Sendable {
        public var upstream: String?
        public var ahead: Int?
        public var behind: Int?
        public var files = 0
        /// Upstream is configured but its branch no longer exists (git prints no ahead/behind).
        public var upstreamGone: Bool { upstream != nil && ahead == nil }
    }

    public static func parseStatusV2(_ text: String) -> StatusV2 {
        var s = StatusV2()
        for raw in text.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("# branch.upstream ") {
                s.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 { s.ahead = Int(parts[0].dropFirst()); s.behind = Int(parts[1].dropFirst()) }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                s.files += 1
            }
        }
        return s
    }

    /// The main repo a linked worktree belongs to, from its `.git` file
    /// (`gitdir: /path/repo/.git/worktrees/name`). nil for ordinary repos or unexpected layouts.
    public static func mainRepo(fromGitFile text: String, relativeTo dir: String) -> String? {
        guard let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = dir + "/" + gitdir }
        let comps = URL(fileURLWithPath: gitdir).standardizedFileURL.pathComponents
        guard let i = comps.lastIndex(of: "worktrees"), i >= 2, comps[i - 1] == ".git" else { return nil }
        return NSString.path(withComponents: Array(comps[..<(i - 1)]))
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
