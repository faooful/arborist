import Foundation

/// D31: a merged pull request for a branch, as `gh pr list --state merged` reports it.
public struct MergedPR: Equatable, Sendable, Decodable {
    public var number: Int
    public var headRefOid: String
    public init(number: Int, headRefOid: String) { self.number = number; self.headRefOid = headRefOid }
}

/// Looks up merged PRs for a branch. nil = unknown (no gh, unauthed, timeout, error): fall back to local rules.
public protocol PRLookup: Sendable {
    func mergedPRs(repo: String, branch: String) -> [MergedPR]?
}

/// `gh pr list` with a short timeout, cached per repo+branch for the process lifetime. Read-only; no tokens
/// are handled here (gh uses its own login). Disabled after the first sign that gh is missing or unauthed.
public final class GHPullRequests: PRLookup, @unchecked Sendable {
    public static let shared = GHPullRequests()
    public var timeout: TimeInterval = 4
    private let lock = NSLock()
    private var cache: [String: [MergedPR]?] = [:]
    private var available: Bool?

    public func mergedPRs(repo: String, branch: String) -> [MergedPR]? {
        let key = repo + "\u{1f}" + branch
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        if available == nil { available = Shell.run(["gh", "auth", "status"], timeout: timeout) != nil }
        let ok = available == true
        lock.unlock()
        guard ok else { return nil }
        let out = Shell.run(["gh", "pr", "list", "--state", "merged", "--head", branch, "--limit", "5",
                             "--json", "headRefOid,mergedAt,number"], cwd: repo, timeout: timeout)
        let prs = out.flatMap { try? JSONDecoder().decode([MergedPR].self, from: Data($0.utf8)) }
        lock.lock(); cache[key] = prs; lock.unlock()
        return prs
    }
}

/// D31: squash/rebase-merge detection, accuracy first. Uses only refs already present (the app never fetches).
public enum SquashMerge {
    /// How many commits of the target's history are searched for an identical tree.
    public static let treeSearchDepth = 200

    /// A note ("PR #12 merged" / "squash-merged") when `tip` was squash- or rebase-merged into `target`, else nil.
    public static func detect(repo: String, branch: String, tip: String, target: String, prs: PRLookup?) -> String? {
        // A branch with no commits of its own isn't a merge (a fresh branch on main).
        guard let own = Shell.git(repo, "rev-list", "--count", "\(target)..\(tip)"), let n = Int(own), n > 0 else { return nil }
        if let list = prs?.mergedPRs(repo: repo, branch: branch) {
            for pr in list where pr.headRefOid == tip
                || Shell.git(repo, "merge-base", "--is-ancestor", tip, pr.headRefOid) != nil {
                return "PR #\(pr.number) merged"
            }
        }
        if patchesUpstream(repo: repo, tip: tip, target: target) || treeInTarget(repo: repo, tip: tip, target: target) {
            return "squash-merged"
        }
        return nil
    }

    /// `git cherry target tip`: every commit is "-" (an equivalent patch is in target). Handles rebase merges.
    static func patchesUpstream(repo: String, tip: String, target: String) -> Bool {
        guard let out = Shell.git(repo, "cherry", target, tip) else { return false }
        let lines = out.split(separator: "\n")
        return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("-") }
    }

    /// The tip's tree equals some recent target commit's tree, or applying the branch's whole diff (since the
    /// merge base) to target changes nothing. Handles squash merges, where per-commit patches don't match.
    static func treeInTarget(repo: String, tip: String, target: String) -> Bool {
        guard let tree = Shell.git(repo, "rev-parse", "\(tip)^{tree}") else { return false }
        if let trees = Shell.git(repo, "log", "--format=%T", "-n", "\(treeSearchDepth)", target),
           trees.split(separator: "\n").contains(where: { $0 == tree }) { return true }
        // Squash patch-id: the branch's combined diff has a patch-id equal to some target commit's.
        guard let base = Shell.git(repo, "merge-base", target, tip),
              let squashId = patchID(repo: repo, ["diff", base, tip]) else { return false }
        guard let revs = Shell.git(repo, "rev-list", "-n", "\(treeSearchDepth)", "\(base)..\(target)") else { return false }
        return revs.split(separator: "\n").contains { patchID(repo: repo, ["show", "--format=", String($0)]) == squashId }
    }

    static func patchID(repo: String, _ args: [String]) -> String? {
        guard let diff = Shell.run(["git", "-C", repo] + args), !diff.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("arborist-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? (diff + "\n").write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        return Shell.run(["sh", "-c", "git patch-id --stable < \"$1\"", "sh", tmp.path])?.split(separator: " ").first.map(String.init)
    }
}
