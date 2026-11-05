import XCTest
@testable import ArboristCore

/// D31: squash/rebase-merged branches count as Clear-ready; gh is optional and stubbed here.
final class SquashMergeTests: XCTestCase, @unchecked Sendable {
    struct StubPRs: PRLookup { var prs: [String: [MergedPR]]
        func mergedPRs(repo: String, branch: String) -> [MergedPR]? { prs[branch] }
    }
    struct NoGH: PRLookup { func mergedPRs(repo: String, branch: String) -> [MergedPR]? { nil } }

    var base = "", repo = ""
    override func setUp() {
        base = NSTemporaryDirectory() + "arborist-squash-\(UUID().uuidString)"
        repo = base + "/repo"
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        g(repo, "init", "-q", "-b", "main"); write(repo, "README", "x"); g(repo, "add", "."); g(repo, "commit", "-q", "-m", "init")
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: base) }

    @discardableResult func g(_ dir: String, _ a: String...) -> String? {
        Shell.run(["git", "-C", dir, "-c", "user.name=T", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false"] + a)
    }
    func write(_ dir: String, _ f: String, _ s: String) { try? (s + "\n").write(toFile: dir + "/" + f, atomically: true, encoding: .utf8) }
    /// A worktree on `branch` with `n` commits of its own.
    func branch(_ b: String, commits n: Int) -> String {
        let wt = base + "/wt-" + b
        g(repo, "worktree", "add", "-q", "-b", b, wt)
        for i in 0..<n { write(wt, "\(b)-\(i)", "\(i)"); g(wt, "add", "."); g(wt, "commit", "-q", "-m", "\(b) \(i)") }
        return wt
    }
    func squashIntoMain(_ b: String) { g(repo, "merge", "-q", "--squash", b); g(repo, "commit", "-q", "-m", "squash \(b)") }
    func mainMovesOn() { write(repo, "other", UUID().uuidString); g(repo, "add", "."); g(repo, "commit", "-q", "-m", "other") }
    func worktree(_ wt: String, prs: PRLookup = NoGH()) -> Worktree {
        let r = Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3), prLookup: prs).scan()
        let all = r.repos.flatMap(\.worktrees)
        return all.first { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: wt).resolvingSymlinksInPath().path }!
    }

    func testSquashMergeWithoutGHIsReady() {
        let wt = branch("feat", commits: 2); mainMovesOn(); squashIntoMain("feat"); mainMovesOn()
        let w = worktree(wt)
        XCTAssertEqual(w.staleReasons, [.squashMerged]); XCTAssertEqual(w.mergeNote, "squash-merged")
        XCTAssertNil(CleanupSafety.blocker(w)); XCTAssertEqual(w.status, .merged)
    }
    func testRebaseMergeWithoutGHIsReady() {
        let wt = branch("reb", commits: 2); mainMovesOn()
        for c in (g(repo, "rev-list", "--reverse", "main..reb") ?? "").split(separator: "\n") { g(repo, "cherry-pick", String(c)) }
        let w = worktree(wt)
        XCTAssertEqual(w.staleReasons, [.squashMerged]); XCTAssertNil(CleanupSafety.blocker(w))
    }
    func testGHMergedPRAtTipIsReady() {
        let wt = branch("pr", commits: 1)
        let tip = g(wt, "rev-parse", "HEAD")!
        let w = worktree(wt, prs: StubPRs(prs: ["pr": [MergedPR(number: 12, headRefOid: tip)]]))
        XCTAssertEqual(w.mergeNote, "PR #12 merged"); XCTAssertNil(CleanupSafety.blocker(w))
    }
    func testGHMergedPRForOtherCommitIsNotReady() {
        let wt = branch("pr2", commits: 1)
        let other = g(repo, "rev-parse", "HEAD")! // main's tip: the local tip isn't an ancestor of it
        let w = worktree(wt, prs: StubPRs(prs: ["pr2": [MergedPR(number: 13, headRefOid: other)]]))
        XCTAssertNil(w.mergeNote); XCTAssertEqual(CleanupSafety.blocker(w), .notStale)
    }
    func testUnmergedCommitLeftIsNotReady() {
        let wt = branch("left", commits: 2); squashIntoMain("left")
        write(wt, "late", "late"); g(wt, "add", "."); g(wt, "commit", "-q", "-m", "late")
        let w = worktree(wt)
        XCTAssertEqual(w.staleReasons, []); XCTAssertEqual(CleanupSafety.blocker(w), .notStale)
    }
    func testDirtySquashMergedIsNotReady() {
        let wt = branch("dirty", commits: 1); squashIntoMain("dirty"); write(wt, "build.out", "junk")
        XCTAssertEqual(CleanupSafety.blocker(worktree(wt)), .uncommitted(1))
    }
    func testAheadOfUpstreamIsNotReady() {
        let remote = base + "/origin.git"
        g(base, "init", "-q", "--bare", "-b", "main", remote)
        g(repo, "remote", "add", "origin", remote); g(repo, "push", "-q", "origin", "main")
        let wt = branch("ahead", commits: 1); g(wt, "push", "-q", "-u", "origin", "ahead")
        write(wt, "more", "more"); g(wt, "add", "."); g(wt, "commit", "-q", "-m", "more")
        squashIntoMain("ahead"); g(repo, "push", "-q", "origin", "main")
        let w = worktree(wt)
        XCTAssertFalse(w.staleReasons.contains(.squashMerged)); XCTAssertEqual(CleanupSafety.blocker(w), .unpushed)
    }
    func testFreshBranchIsNotSquashMerged() {
        let wt = branch("fresh", commits: 0)
        XCTAssertEqual(worktree(wt).staleReasons, [])
    }
}
