import ArboristCleanup
@testable import ArboristCore
import XCTest

/// D28: a removed worktree leaves the model at once; a confirming `git worktree list` keeps it gone or
/// restores it (rollback). Real git on a throwaway repo, plus pure cases.
final class OptimisticRemovalTests: XCTestCase, @unchecked Sendable {
    var base = ""
    override func setUp() {
        base = NSTemporaryDirectory() + "arborist-d28-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: base) }

    func scan() -> ScanResult { Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3)).scan() }

    func testRealRemovalLeavesModelAndRescanConfirms() throws {
        let t = try XCTUnwrap(TrialRepo.make(in: base))
        let r0 = scan()
        let ref = try XCTUnwrap(WorktreeList.find(r0, path: t.worktree))
        let item = try XCTUnwrap(Cleanup.item(ref), "trial worktree should be ready to clean")
        let ready0 = r0.repos.flatMap(\.worktrees).filter(CleanupSafety.isReady).count
        let plan0 = Cleanup.plan(r0, visible: VisibleSet(repos: .all, states: .all)).count
        let outcome = Cleanup.execute(item)
        XCTAssertTrue(outcome.succeeded, outcome.summary)

        let (r1, pending) = OptimisticRemoval.apply(r0, removed: [outcome.item.path])
        XCTAssertNil(WorktreeList.find(r1, path: t.worktree), "gone from the model right away")
        XCTAssertEqual(r1.worktreeCount, r0.worktreeCount - 1)
        XCTAssertEqual(r1.repos.flatMap(\.worktrees).filter(CleanupSafety.isReady).count, ready0 - 1)
        XCTAssertEqual(Cleanup.plan(r1, visible: VisibleSet(repos: .all, states: .all)).count, plan0 - 1)
        let map = LeafLayout.layout(LeafLayout.groups(from: r1), staleCount: r1.totals.staleWorktrees)
        XCTAssertFalse(map.leaves.contains { OptimisticRemoval.same($0.item.id, t.worktree) })
        XCTAssertEqual(pending.count, 1)

        let listed = Dictionary(uniqueKeysWithValues: OptimisticRemoval.repos(pending).map { ($0, OptimisticRemoval.list($0)) })
        let c = OptimisticRemoval.confirm(r1, pending: pending, listed: listed)
        XCTAssertEqual(c.confirmed.count, 1); XCTAssertEqual(c.restored, []); XCTAssertNil(WorktreeList.find(c.result, path: t.worktree))
    }

    func testRollbackWhenGitStillListsIt() throws {
        let t = try XCTUnwrap(TrialRepo.make(in: base))
        let r0 = scan()
        // Optimistically dropped, but never actually removed: git still lists it.
        let (r1, pending) = OptimisticRemoval.apply(r0, removed: [t.worktree])
        XCTAssertNil(WorktreeList.find(r1, path: t.worktree))
        let listed = Dictionary(uniqueKeysWithValues: OptimisticRemoval.repos(pending).map { ($0, OptimisticRemoval.list($0)) })
        let c = OptimisticRemoval.confirm(r1, pending: pending, listed: listed)
        XCTAssertEqual(c.restored.count, 1)
        XCTAssertEqual(c.result, r0, "restored in the same place")
    }

    func testFailedListDecidesNothingAndMainNeverDropped() {
        let r0 = LeafSample.busy
        let repo = r0.repos[0], main = repo.worktrees.first { $0.isMain }, other = repo.worktrees.first { !$0.isMain }
        let paths = [main?.path, other?.path].compactMap { $0 }
        let (r1, pending) = OptimisticRemoval.apply(r0, removed: paths)
        XCTAssertEqual(pending.map(\.path), other.map { [$0.path] } ?? [])
        if let m = main { XCTAssertNotNil(WorktreeList.find(r1, path: m.path)) }
        let c = OptimisticRemoval.confirm(r1, pending: pending, listed: [repo.path: nil])
        XCTAssertEqual(c.undecided, pending.map(\.path)); XCTAssertEqual(c.result, r1)
        XCTAssertTrue(OptimisticRemoval.clears(other?.path, removed: pending))
        XCTAssertFalse(OptimisticRemoval.clears(nil, removed: pending))
    }

    func testHeaderGapTightened() {
        let f = HeaderLayout.frames(count: "77 worktrees", sub: "· 7 stale", filter: "All 35 repos")
        let t = HeaderLayout.tightened(f, naturals: [f[0].rect.w - 10, f[1].rect.w - 4])
        XCTAssertEqual(t[1].rect.x, f[1].rect.x - 10)
        XCTAssertEqual(t[2].rect.x, f[2].rect.x - 14)
        XCTAssertEqual(t[3].rect.x, f[3].rect.x, "status stays put")
        XCTAssertEqual(HeaderLayout.tightened(f, naturals: [nil, nil]).map(\.rect), f.map(\.rect))
    }
}
