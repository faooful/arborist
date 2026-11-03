import XCTest
@testable import ArboristCore

final class WorktreeParsingTests: XCTestCase, @unchecked Sendable {
    func testStatusV2() {
        let s = GitParsing.parseStatusV2("""
        # branch.oid abc
        # branch.head feat
        # branch.upstream origin/feat
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 a a src/x.swift
        ? new.txt
        """)
        XCTAssertEqual(s.upstream, "origin/feat"); XCTAssertEqual(s.ahead, 2); XCTAssertEqual(s.behind, 1)
        XCTAssertEqual(s.files, 2); XCTAssertFalse(s.upstreamGone)
        let gone = GitParsing.parseStatusV2("# branch.head f\n# branch.upstream origin/f\n")
        XCTAssertTrue(gone.upstreamGone); XCTAssertEqual(gone.files, 0)
        XCTAssertNil(GitParsing.parseStatusV2("# branch.head f\n").upstream)
    }

    func testMainRepoFromGitFile() {
        XCTAssertEqual(GitParsing.mainRepo(fromGitFile: "gitdir: /Users/j/code/app/.git/worktrees/feat\n", relativeTo: "/tmp/feat"), "/Users/j/code/app")
        XCTAssertEqual(GitParsing.mainRepo(fromGitFile: "gitdir: ../app/.git/worktrees/w", relativeTo: "/x/w"), "/x/app")
        XCTAssertNil(GitParsing.mainRepo(fromGitFile: "nonsense", relativeTo: "/x"))
    }
}

final class WorktreeLabelAndListTests: XCTestCase, @unchecked Sendable {
    func testLabelIsBranchThenRepo() {
        XCTAssertEqual(WorktreeLabel.text(branch: "feat-t5b-handover", head: nil, repo: "property-management"), "feat-t5b-handover · property-management")
        XCTAssertEqual(WorktreeLabel.text(branch: nil, head: "abc1234def", repo: "farm"), "detached @abc1234 · farm")
    }

    func testHeadline() {
        let r = LeafSample.scan
        XCTAssertEqual(r.headline, "\(r.worktreeCount) worktrees in \(r.repos.count) repos · \(r.totals.staleWorktrees) stale")
    }

    func testListSortsByStateThenNewest() {
        let list = WorktreeList.sorted(LeafSample.scan)
        let ranks = list.map(\.worktree.status.rank)
        XCTAssertEqual(ranks, ranks.sorted(), "grouped by state: uncommitted, unpushed, merged, stale, clean")
        for (a, b) in zip(list, list.dropFirst()) where a.worktree.status == b.worktree.status {
            if let da = a.worktree.lastCommitDate, let db = b.worktree.lastCommitDate { XCTAssertGreaterThanOrEqual(da, db) }
            else { XCTAssertFalse(a.worktree.lastCommitDate == nil && b.worktree.lastCommitDate != nil, "undated last") }
        }
        XCTAssertEqual(list.first?.worktree.status, .uncommitted)
    }

    func testHoverCard() throws {
        let ref = try XCTUnwrap(WorktreeList.sorted(LeafSample.scan).first { $0.worktree.branch == "feat-t5b-handover" })
        let c = HoverCard(ref, now: LeafSample.now, home: LeafSample.home)
        XCTAssertEqual(c.branch, "feat-t5b-handover")
        XCTAssertEqual(c.pill, "Uncommitted")
        XCTAssertTrue(c.path.hasPrefix("~/"))
        XCTAssertLessThanOrEqual(c.path.count, HoverCard.pathChars)
        XCTAssertEqual(c.changes, "4 files")
        XCTAssertEqual(c.sync, "1 ahead")
        XCTAssertEqual(c.size, "6.2 GB")
        XCTAssertEqual(c.rebuildableShare, 5.6 / 6.2, accuracy: 0.01)
        XCTAssertNotNil(c.removeCommand)
    }

    func testStatusPrecedence() {
        func wt(dirty: Bool = false, unpushed: Int? = nil, reasons: [StaleReason] = []) -> Worktree {
            Worktree(path: "/p", isMain: false, branch: "b", head: nil, lastCommitDate: nil, dirty: dirty, unpushedCommits: unpushed, hasUpstream: true,
                     stale: !reasons.isEmpty, staleReasons: reasons, size: SizeSplit(rebuildable: 0, source: 0), removeCommand: nil)
        }
        XCTAssertEqual(wt(dirty: true, unpushed: 3, reasons: [.merged]).status, .uncommitted)
        XCTAssertEqual(wt(unpushed: 1, reasons: [.merged]).status, .unpushed)
        XCTAssertEqual(wt(reasons: [.merged]).status, .merged)
        XCTAssertEqual(wt().status, .clean)
    }

    func testJSONKeepsOldKeysAndAddsNew() throws {
        let json = String(decoding: try LeafSample.scan.jsonData(), as: UTF8.self)
        for k in ["\"repos\"", "\"worktrees\"", "\"staleReasons\"", "\"removeCommand\"", "\"unpushedCommits\"", "\"caches\"", "\"totals\"", "\"volume\""] {
            XCTAssertTrue(json.contains(k), k)
        }
        for k in ["\"uncommittedFiles\"", "\"lastCommitSubject\"", "\"ahead\""] { XCTAssertTrue(json.contains(k), k) }
    }
}

/// Discovery across the machine, against real git.
final class DiscoveryTests: XCTestCase, @unchecked Sendable {
    var base = ""
    let fm = FileManager.default
    override func setUpWithError() throws {
        guard Shell.run(["git", "--version"]) != nil else { throw XCTSkip("git not installed") }
        base = fm.temporaryDirectory.appendingPathComponent("arborist-disc-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
    }
    override func tearDown() {
        _ = Shell.run(["chmod", "-R", "u+rwx", base])
        try? fm.removeItem(atPath: base)
    }
    func g(_ dir: String, _ a: String...) { _ = Shell.run(["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a) }
    func makeRepo(_ p: String) throws {
        try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        g(p, "init", "-q", "-b", "main")
        try "hi".write(toFile: p + "/a.txt", atomically: true, encoding: .utf8)
        g(p, "add", "."); g(p, "commit", "-qm", "one")
    }

    func testLinkedWorktreeOutsideRootsIsFound() throws {
        try makeRepo(base + "/home/code/app")
        try fm.createDirectory(atPath: base + "/elsewhere", withIntermediateDirectories: true)
        g(base + "/home/code/app", "worktree", "add", "-q", "-b", "far", base + "/elsewhere/far")
        let r = Scanner(config: ArboristConfig(roots: [base + "/home"], lowSpaceThresholdGB: 1, maxDepth: 4)).scan()
        XCTAssertEqual(r.repos.count, 1)
        XCTAssertTrue(r.repos[0].worktrees.contains { $0.branch == "far" }, "found via git worktree list")
        XCTAssertEqual(r.worktreeCount, 2)
    }

    func testWorktreeUnderTmpStyleRootResolvesToItsRepo() throws {
        // A worktree found first (under a /tmp-like root reached through a symlink) still groups under its main repo once.
        try makeRepo(base + "/code/app")
        try fm.createDirectory(atPath: base + "/private/tmp", withIntermediateDirectories: true)
        g(base + "/code/app", "worktree", "add", "-q", "-b", "scratch", base + "/private/tmp/scratch")
        try fm.createSymbolicLink(atPath: base + "/tmp", withDestinationPath: base + "/private/tmp")
        let r = Scanner(config: ArboristConfig(roots: [base + "/tmp", base + "/private/tmp", base + "/code"], lowSpaceThresholdGB: 1, maxDepth: 4)).scan()
        XCTAssertEqual(r.repos.count, 1, "deduped by main repo and resolved roots")
        XCTAssertEqual(r.repos[0].worktrees.count, 2)
        // Only the tmp root: the main repo is still found through the gitdir link.
        let r2 = Scanner(config: ArboristConfig(roots: [base + "/tmp"], lowSpaceThresholdGB: 1, maxDepth: 4)).scan()
        XCTAssertEqual(r2.repos.count, 1)
        XCTAssertTrue(r2.repos[0].worktrees.contains { $0.isMain })
    }

    func testUnreadableFoldersAreSkippedQuietly() throws {
        try makeRepo(base + "/ok/app")
        try fm.createDirectory(atPath: base + "/locked/inner", withIntermediateDirectories: true)
        _ = Shell.run(["chmod", "000", base + "/locked"])
        guard !fm.isReadableFile(atPath: base + "/locked/inner") else { throw XCTSkip("running as root") }
        let r = Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 4)).scan()
        XCTAssertEqual(r.repos.count, 1)
        XCTAssertGreaterThanOrEqual(r.skippedPaths, 1)
    }

    func testSkipsDependencyAndBuildFolders() throws {
        try makeRepo(base + "/proj/app")
        try makeRepo(base + "/proj/node_modules/pkg")
        try makeRepo(base + "/proj/.build/checkouts/dep")
        try makeRepo(base + "/proj/vendor/lib")
        let r = Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 5)).scan()
        XCTAssertEqual(r.repos.map(\.name), ["app"])
    }
}
