import Foundation

/// D28 test fixture (Linux tests and the app's `--remove-trial`): a throwaway git repo with one linked
/// worktree whose branch is merged into main, so `CleanupSafety` calls it ready to clean.
public enum TrialRepo {
    /// Creates `<base>/repo` and the worktree at `worktree` (default `<base>/arborist-trial-remove`).
    /// Returns (repo path, worktree path), or nil if git failed.
    public static func make(in base: String, worktree: String? = nil) -> (repo: String, worktree: String)? {
        let repo = base + "/repo", wt = worktree ?? base + "/arborist-trial-remove"
        try? FileManager.default.removeItem(atPath: wt)
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ dir: String, _ a: String...) -> Bool {
            Shell.run(["git", "-C", dir, "-c", "user.name=Arborist Trial", "-c", "user.email=trial@example.invalid",
                       "-c", "commit.gpgsign=false"] + a) != nil
        }
        guard g(repo, "init", "-q", "-b", "main"),
              (try? "trial\n".write(toFile: repo + "/README", atomically: true, encoding: .utf8)) != nil,
              g(repo, "add", "README"), g(repo, "commit", "-q", "-m", "init"),
              g(repo, "worktree", "add", "-q", "-b", "trial", wt),
              (try? "more\n".write(toFile: wt + "/TRIAL", atomically: true, encoding: .utf8)) != nil,
              g(wt, "add", "TRIAL"), g(wt, "commit", "-q", "-m", "trial work"),
              g(repo, "merge", "-q", "--ff-only", "trial") else { return nil }
        return (repo, wt)
    }
}
