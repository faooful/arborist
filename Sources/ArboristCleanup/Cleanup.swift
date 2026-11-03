import ArboristCore
import Foundation

// The only code in Arborist that changes anything on disk (D14). It lives in its own module, which only the
// app links. The `arborist` CLI does not depend on it, so the CLI stays read-only. CleanupTests checks this
// in Package.swift.

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

/// One planned action: remove a worktree folder, or just prune git's record of one whose folder is gone.
public struct CleanupItem: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case remove, pruneOnly = "prune" }
    public var repo: String
    public var repoPath: String
    public var path: String
    public var branch: String
    /// HEAD at scan time. A different HEAD at execute time means a new commit, so the item is skipped.
    public var head: String?
    public var bytes: Int64
    public var kind: Kind
    public var id: String { path }
    public init(repo: String, repoPath: String, path: String, branch: String, head: String?, bytes: Int64, kind: Kind) {
        self.repo = repo; self.repoPath = repoPath; self.path = path; self.branch = branch
        self.head = head; self.bytes = bytes; self.kind = kind
    }
}

public enum CleanupOutcome: Equatable, Sendable {
    case removed(CleanupItem)
    case pruned(CleanupItem)
    case skipped(CleanupItem, reason: String)
    case failed(CleanupItem, message: String)

    public var item: CleanupItem {
        switch self { case .removed(let i), .pruned(let i), .skipped(let i, _), .failed(let i, _): i }
    }
    public var freed: Int64 { if case .removed(let i) = self { return i.bytes }; return 0 }
    public var summary: String {
        switch self {
        case .removed(let i): "Removed \(i.branch) (\(Format.bytes(i.bytes)))"
        case .pruned(let i): "Pruned \(i.branch) (folder was already gone)"
        case .skipped(let i, let r): "Skipped \(i.branch): \(r)"
        case .failed(let i, let m): "Failed \(i.branch): \(m)"
        }
    }
}

public enum Cleanup {
    /// The safety rule (D14). A worktree is clearable only if all of these hold:
    /// - it's not the main checkout and not locked
    /// - it has no uncommitted files and no unpushed commits
    /// - its branch is merged into the default branch, its upstream is gone, or its folder is missing (prune only)
    public static func blocker(_ w: Worktree) -> CleanupBlocker? {
        if w.isMain { return .mainCheckout }
        if w.locked == true { return .locked }
        if w.staleReasons.contains(.prunable) { return nil }
        if w.dirty { return .uncommitted(max(w.uncommittedFiles ?? 1, 1)) }
        if (w.unpushedCommits ?? 0) > 0 || (w.ahead ?? 0) > 0 { return .unpushed }
        if !(w.staleReasons.contains(.merged) || w.staleReasons.contains(.upstreamGone)) { return .notStale }
        return nil
    }

    public static func item(_ w: Worktree, repo: Repo) -> CleanupItem? { item(w, repo: repo.name, repoPath: repo.path) }
    public static func item(_ ref: WorktreeRef) -> CleanupItem? { item(ref.worktree, repo: ref.repo, repoPath: ref.repoPath) }

    public static func item(_ w: Worktree, repo: String, repoPath: String) -> CleanupItem? {
        guard blocker(w) == nil else { return nil }
        return CleanupItem(repo: repo, repoPath: repoPath, path: w.path,
                           branch: WorktreeLabel.branchName(w.branch, head: w.head), head: w.head,
                           bytes: w.size.total, kind: w.staleReasons.contains(.prunable) ? .pruneOnly : .remove)
    }

    /// Everything "Clear N" would do, biggest first.
    public static func plan(_ result: ScanResult) -> [CleanupItem] {
        result.repos.flatMap { r in r.worktrees.compactMap { item($0, repo: r) } }.sorted { $0.bytes > $1.bytes }
    }

    /// Runs one item. Everything is checked again right before acting, and the item is skipped if
    /// anything changed since the scan. Never uses --force and never deletes a branch.
    public static func execute(_ item: CleanupItem, git: Git = Git()) -> CleanupOutcome {
        guard let list = git.run(["-C", item.repoPath, "worktree", "list", "--porcelain"]), list.ok else {
            return .skipped(item, reason: "Can't read the repo's worktree list")
        }
        let entries = GitParsing.parseWorktreeList(list.out)
        guard let idx = entries.firstIndex(where: { same($0.path, item.path) }) else {
            // An earlier removal's prune already dropped a missing folder's record: that's the goal.
            if item.kind == .pruneOnly && !FileManager.default.fileExists(atPath: item.path) { return .pruned(item) }
            return .skipped(item, reason: "No longer a worktree")
        }
        let e = entries[idx]
        if idx == 0 { return .skipped(item, reason: CleanupBlocker.mainCheckout.reason) }
        if e.locked { return .skipped(item, reason: CleanupBlocker.locked.reason) }
        let exists = FileManager.default.fileExists(atPath: item.path)

        switch item.kind {
        case .pruneOnly:
            if exists && !e.prunable { return .skipped(item, reason: "Folder is back; rescan first") }
            guard let p = git.run(["-C", item.repoPath, "worktree", "prune"]), p.ok else {
                return .failed(item, message: "git worktree prune failed")
            }
            return .pruned(item)
        case .remove:
            guard exists else { return .skipped(item, reason: "Folder disappeared; rescan first") }
            if let h = item.head, e.head != h { return .skipped(item, reason: "New commit since scan") }
            guard let s = git.run(["-C", item.path, "status", "--porcelain=v2", "--branch"]), s.ok else {
                return .skipped(item, reason: "Can't read git status")
            }
            let st = GitParsing.parseStatusV2(s.out)
            if st.files > 0 { return .skipped(item, reason: CleanupBlocker.uncommitted(st.files).reason) }
            if (st.ahead ?? 0) > 0 { return .skipped(item, reason: CleanupBlocker.unpushed.reason) }
            guard let r = git.run(["-C", item.repoPath, "worktree", "remove", item.path]) else {
                return .failed(item, message: "Couldn't run git")
            }
            guard r.ok else { return .failed(item, message: r.err.isEmpty ? "git worktree remove failed" : r.err) }
            _ = git.run(["-C", item.repoPath, "worktree", "prune"])
            return .removed(item)
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a == b || URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }
}

/// Runs git with an argument array. No shell, so paths are never interpolated.
public struct Git: Sendable {
    public struct Result: Sendable { public var ok: Bool; public var out: String; public var err: String }
    public var executable: String
    public init(executable: String = "/usr/bin/env") { self.executable = executable }

    public func run(_ args: [String]) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["git"] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let o = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        let e = (try? err.fileHandleForReading.readToEnd()) ?? Data()
        p.waitUntilExit()
        return Result(ok: p.terminationStatus == 0,
                      out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// ~/.config/arborist/cleanup.log gets one tab-separated line per removed or pruned worktree:
/// `2026-11-03T09:40:00-05:00	removed	1234567	mockingbird	feat-x	/Users/joseph/wt/feat-x`
public enum CleanupLog {
    public static var url: URL {
        URL(fileURLWithPath: ArboristConfig.home).appendingPathComponent(".config/arborist/cleanup.log")
    }

    public static func line(_ o: CleanupOutcome, at date: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let action: String
        switch o { case .removed: action = "removed"; case .pruned: action = "pruned"; default: return nil }
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        let i = o.item
        return [f.string(from: date), action, String(o.freed), i.repo, i.branch, i.path].joined(separator: "\t")
    }

    public static func append(_ outcomes: [CleanupOutcome], to url: URL = CleanupLog.url, at date: Date = Date()) {
        let text = outcomes.compactMap { line($0, at: date) }.map { $0 + "\n" }.joined()
        guard !text.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
