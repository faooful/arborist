import ArboristCleanup
@testable import ArboristCore
import XCTest

/// D14: the safety rule, re-checks before acting, prune-only, the log, and the CLI's read-only boundary.
/// Uses real git repos in a temp folder.
final class CleanupTests: XCTestCase, @unchecked Sendable {
    let fm = FileManager.default
    var base = ""

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "arborist-cleanup-\(UUID().uuidString)"
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        base = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
    }
    override func tearDownWithError() throws { try? fm.removeItem(atPath: base) }

    @discardableResult
    func g(_ dir: String, _ args: String...) -> String {
        Git().run(["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args)?.out ?? ""
    }
    func write(_ path: String, _ text: String = "x") { try? text.write(toFile: path, atomically: true, encoding: .utf8) }

    var app: String { base + "/code/app" }
    func wt(_ name: String) -> String { base + "/wt/" + name }

    /// main + merged, dirty (merged but with an untracked file), wip (unmerged), locked (merged), gone (folder deleted).
    func makeFixture() throws {
        try fm.createDirectory(atPath: app, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/wt", withIntermediateDirectories: true)
        g(app, "init", "-q", "-b", "main"); write(app + "/a.txt"); g(app, "add", "."); g(app, "commit", "-qm", "one")
        for name in ["merged", "dirty", "wip", "locked", "gone"] {
            g(app, "worktree", "add", "-q", "-b", name, wt(name))
            write(wt(name) + "/\(name).txt"); g(wt(name), "add", "."); g(wt(name), "commit", "-qm", name)
            if name != "wip" { g(app, "merge", "-q", "--no-edit", name) }
        }
        write(wt("dirty") + "/scratch.txt")
        g(app, "worktree", "lock", wt("locked"))
        try fm.removeItem(atPath: wt("gone"))
    }

    func scan() -> ScanResult {
        Scanner(config: ArboristConfig(roots: [base + "/code"], lowSpaceThresholdGB: 1, maxDepth: 4)).scan()
    }
    func worktree(_ r: ScanResult, _ branch: String) -> Worktree? {
        r.repos.flatMap(\.worktrees).first { $0.branch == branch }
    }

    // MARK: predicate

    func testTruthTableOnRealRepos() throws {
        try makeFixture()
        let r = scan()
        XCTAssertEqual(worktree(r, "main").flatMap(Cleanup.blocker), .mainCheckout)
        XCTAssertNil(Cleanup.blocker(try XCTUnwrap(worktree(r, "merged"))))
        XCTAssertEqual(worktree(r, "dirty").flatMap(Cleanup.blocker), .uncommitted(1))
        XCTAssertEqual(worktree(r, "wip").flatMap(Cleanup.blocker), .notStale)
        XCTAssertEqual(worktree(r, "locked").flatMap(Cleanup.blocker), .locked)
        XCTAssertNil(Cleanup.blocker(try XCTUnwrap(worktree(r, "gone"))))
        let plan = Cleanup.plan(r)
        XCTAssertEqual(Set(plan.map(\.branch)), ["merged", "gone"])
        XCTAssertEqual(plan.first { $0.branch == "gone" }?.kind, .pruneOnly)
        XCTAssertFalse(plan.contains { $0.path == app }, "main is never selectable")
    }

    func testTruthTableUnit() {
        func w(main: Bool = false, locked: Bool? = nil, dirty: Bool = false, files: Int? = nil, ahead: Int? = nil,
               reasons: [StaleReason] = [.merged]) -> Worktree {
            var x = Worktree(path: "/p", isMain: main, branch: "b", head: "h", lastCommitDate: nil, dirty: dirty,
                             unpushedCommits: ahead, hasUpstream: ahead != nil, stale: !reasons.isEmpty,
                             staleReasons: reasons, size: SizeSplit(), removeCommand: nil)
            x.locked = locked; x.uncommittedFiles = files; x.ahead = ahead
            return x
        }
        XCTAssertNil(Cleanup.blocker(w()))
        XCTAssertNil(Cleanup.blocker(w(reasons: [.upstreamGone])))
        XCTAssertNil(Cleanup.blocker(w(reasons: [.prunable])))
        XCTAssertEqual(Cleanup.blocker(w(reasons: [])), .notStale)
        XCTAssertEqual(Cleanup.blocker(w(main: true)), .mainCheckout)
        XCTAssertEqual(Cleanup.blocker(w(main: true, reasons: [.prunable])), .mainCheckout)
        XCTAssertEqual(Cleanup.blocker(w(locked: true)), .locked)
        XCTAssertEqual(Cleanup.blocker(w(locked: true, reasons: [.prunable])), .locked)
        XCTAssertEqual(Cleanup.blocker(w(dirty: true, files: 5)), .uncommitted(5))
        XCTAssertEqual(Cleanup.blocker(w(dirty: true, files: 5))?.reason, "5 uncommitted files")
        XCTAssertEqual(Cleanup.blocker(w(ahead: 2)), .unpushed)
        XCTAssertEqual(Cleanup.blocker(w(ahead: 2))?.reason, "Unpushed commits")
        XCTAssertEqual(Cleanup.blocker(w(ahead: 0)), nil)
    }

    // MARK: execute

    func testClearRemovesSafeOnesKeepsBranchesAndPrunes() throws {
        try makeFixture()
        let outcomes = Cleanup.plan(scan()).map { Cleanup.execute($0) }
        XCTAssertEqual(outcomes.filter { if case .removed = $0 { return true }; return false }.map(\.item.branch), ["merged"])
        XCTAssertEqual(outcomes.filter { if case .pruned = $0 { return true }; return false }.map(\.item.branch), ["gone"])
        XCTAssertFalse(fm.fileExists(atPath: wt("merged")))
        for keep in ["dirty", "wip", "locked"] { XCTAssertTrue(fm.fileExists(atPath: wt(keep)), keep) }
        let list = g(app, "worktree", "list", "--porcelain")
        XCTAssertFalse(list.contains(wt("merged")))
        XCTAssertFalse(list.contains(wt("gone")), "prune dropped the missing one")
        let branches = g(app, "branch", "--format=%(refname:short)")
        for b in ["merged", "gone", "dirty", "wip", "locked"] { XCTAssertTrue(branches.contains(b), "branch \(b) kept") }
        XCTAssertTrue(fm.fileExists(atPath: app + "/a.txt"), "main untouched")
    }

    func testRecheckSkipsWhenDirtiedAfterPlan() throws {
        try makeFixture()
        let item = try XCTUnwrap(Cleanup.plan(scan()).first { $0.branch == "merged" })
        write(wt("merged") + "/late.txt")
        XCTAssertEqual(Cleanup.execute(item), .skipped(item, reason: "1 uncommitted file"))
        XCTAssertTrue(fm.fileExists(atPath: wt("merged") + "/late.txt"))
    }

    func testRecheckSkipsOnNewCommitAfterPlan() throws {
        try makeFixture()
        let item = try XCTUnwrap(Cleanup.plan(scan()).first { $0.branch == "merged" })
        write(wt("merged") + "/late.txt"); g(wt("merged"), "add", "."); g(wt("merged"), "commit", "-qm", "late")
        XCTAssertEqual(Cleanup.execute(item), .skipped(item, reason: "New commit since scan"))
        XCTAssertTrue(fm.fileExists(atPath: wt("merged")))
    }

    func testRecheckSkipsWhenLockedAfterPlan() throws {
        try makeFixture()
        let item = try XCTUnwrap(Cleanup.plan(scan()).first { $0.branch == "merged" })
        g(app, "worktree", "lock", wt("merged"))
        XCTAssertEqual(Cleanup.execute(item), .skipped(item, reason: "Locked"))
    }

    func testPruneOnlyNeverRemovesAFolderThatCameBack() throws {
        try makeFixture()
        let item = try XCTUnwrap(Cleanup.plan(scan()).first { $0.kind == .pruneOnly })
        try fm.createDirectory(atPath: wt("gone"), withIntermediateDirectories: true)
        write(wt("gone") + "/.git", "gitdir: \(app)/.git/worktrees/gone\n")
        if case .removed = Cleanup.execute(item) { XCTFail("prune-only must never remove") }
        XCTAssertTrue(fm.fileExists(atPath: wt("gone")))
    }

    func testMainIsSkippedEvenIfForcedIntoAPlan() throws {
        try makeFixture()
        let fake = CleanupItem(repo: "app", repoPath: app, path: app, branch: "main", head: nil, bytes: 0, kind: .remove)
        XCTAssertEqual(Cleanup.execute(fake), .skipped(fake, reason: "Main checkout"))
        XCTAssertTrue(fm.fileExists(atPath: app + "/a.txt"))
    }

    // MARK: log

    func testLogLineFormat() throws {
        let i = CleanupItem(repo: "app", repoPath: "/r", path: "/w/feat x", branch: "feat-x", head: "h", bytes: 1234, kind: .remove)
        let date = Date(timeIntervalSince1970: 1_793_714_400) // 2026-11-03 14:00 UTC
        let tz = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(CleanupLog.line(.removed(i), at: date, timeZone: tz), "2026-11-03T09:00:00-05:00\tremoved\t1234\tapp\tfeat-x\t/w/feat x")
        XCTAssertEqual(CleanupLog.line(.pruned(i), at: date, timeZone: tz), "2026-11-03T09:00:00-05:00\tpruned\t0\tapp\tfeat-x\t/w/feat x")
        XCTAssertNil(CleanupLog.line(.skipped(i, reason: "x"), at: date))
        let url = URL(fileURLWithPath: base + "/cfg/cleanup.log")
        CleanupLog.append([.removed(i), .skipped(i, reason: "x")], to: url, at: date)
        CleanupLog.append([.pruned(i)], to: url, at: date)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2)
    }

    // MARK: boundary

    /// The CLI must not link the remover: in Package.swift the `arborist` target depends only on ArboristCore,
    /// and no CLI source imports ArboristCleanup.
    func testCLICannotReachTheRemover() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pkg = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let line = try XCTUnwrap(pkg.split(separator: "\n").first { $0.contains(".executableTarget(name: \"arborist\"") })
        XCTAssertFalse(line.contains("ArboristCleanup"), "CLI target must not depend on ArboristCleanup")
        let core = try XCTUnwrap(pkg.split(separator: "\n").first { $0.contains(".target(name: \"ArboristCore\"") })
        XCTAssertFalse(core.contains("ArboristCleanup"))
        let cli = root.appendingPathComponent("Sources/arborist")
        for f in try fm.contentsOfDirectory(atPath: cli.path) {
            let s = try String(contentsOf: cli.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(s.contains("ArboristCleanup"), f)
            XCTAssertFalse(s.contains("\"remove\""), f)
        }
        // Nothing in Core runs `worktree remove` either; only the cleanup module does.
        let coreDir = root.appendingPathComponent("Sources/ArboristCore")
        let e = fm.enumerator(atPath: coreDir.path)!
        while let f = e.nextObject() as? String {
            guard f.hasSuffix(".swift") else { continue }
            let s = try String(contentsOf: coreDir.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(s.contains("\"worktree\", \"remove\""), f)
        }
    }
}
