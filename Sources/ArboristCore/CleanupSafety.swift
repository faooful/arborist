import Foundation

/// Why a worktree can't be cleared. nil from `Cleanup.blocker` means it's safe.
public enum CleanupBlocker: Equatable, Sendable {
    case mainCheckout
    case locked
    case uncommitted(Int)
    case unpushed
    case notStale

    public var reason: String {
        switch self {
        case .mainCheckout: "Main checkout"
        case .locked: "Locked"
        case .uncommitted(let n): n == 1 ? "1 uncommitted file" : "\(n) uncommitted files"
        case .unpushed: "Unpushed commits"
        case .notStale: "Not merged"
        }
    }
}

/// The safety rule (D14), in Core so the "Ready to clean" filter (D21) and `Cleanup.plan` use the very same
/// predicate. Pure: it reads the scan, never the disk. A worktree is clearable only if all of these hold:
/// - it's not the main checkout and not locked
/// - it has no uncommitted files and no unpushed commits
/// - its branch is merged into the default branch, its upstream is gone, its folder is missing (prune only),
///   or (D31) it was squash- or rebase-merged (`SquashMerge`)
public enum CleanupSafety {
    public static func blocker(_ w: Worktree) -> CleanupBlocker? {
        if w.isMain { return .mainCheckout }
        if w.locked == true { return .locked }
        if w.staleReasons.contains(.prunable) { return nil }
        if w.dirty { return .uncommitted(max(w.uncommittedFiles ?? 1, 1)) }
        if (w.unpushedCommits ?? 0) > 0 || (w.ahead ?? 0) > 0 { return .unpushed }
        if !(w.staleReasons.contains(.merged) || w.staleReasons.contains(.upstreamGone)
             || w.staleReasons.contains(.squashMerged)) { return .notStale }
        return nil
    }

    public static func isReady(_ w: Worktree) -> Bool { blocker(w) == nil }
}
