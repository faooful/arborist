import ArboristCleanup
@testable import ArboristCore
import Foundation
import XCTest

/// D18: the header repo filter.
final class RepoFilterTests: XCTestCase, @unchecked Sendable {
    let scan = LeafSample.busy
    var repos: [Repo] { scan.repos }
    var a: Repo { repos[0] }
    var b: Repo { repos[1] }

    func testAllNoneOnlyToggle() {
        var f = RepoFilter.all
        XCTAssertEqual(f.apply(scan), scan)
        XCTAssertEqual(f.label(repos), "All repos")
        XCTAssertTrue(f.isEverything(repos))
        f.selectNone(repos)
        XCTAssertTrue(f.apply(scan).repos.isEmpty)
        XCTAssertTrue(f.isEmpty(repos))
        XCTAssertEqual(f.label(repos), "No repos")
        f.toggle(a.path)
        XCTAssertEqual(f.apply(scan).repos.map(\.path), [a.path])
        XCTAssertEqual(f.label(repos), a.name)
        f.toggle(b.path)
        XCTAssertEqual(f.label(repos), "2 repos")
        f.only(b.path, among: repos)
        XCTAssertEqual(f.selected(repos).map(\.path), [b.path])
        f.selectAll()
        XCTAssertEqual(f, .all)
    }

    func testOrderIsKept() {
        var f = RepoFilter.all
        f.toggle(repos[2].path)
        XCTAssertEqual(f.apply(scan).repos.map(\.path), repos.map(\.path).filter { $0 != repos[2].path })
    }

    func testRepoDisappearingDropsOutQuietly() {
        var f = RepoFilter.all
        f.toggle(a.path); f.toggle(b.path)
        var later = scan
        later.repos.removeAll { $0.path == a.path }
        let p = f.pruned(to: later.repos)
        XCTAssertEqual(p.excluded, [b.path])
        XCTAssertEqual(p.apply(later).repos.count, later.repos.count - 1)
    }

    func testNewRepoShowsByDefault() {
        var f = RepoFilter.all
        f.only(a.path, among: repos)
        var later = scan
        var fresh = a; fresh.name = "brand-new"; fresh.path = "/new/brand-new"
        later.repos.append(fresh)
        XCTAssertEqual(Set(f.apply(later).repos.map(\.path)), [a.path, fresh.path])
    }

    func testCountsFollowTheFilter() {
        let f = RepoFilter.only(names: [a.name, b.name], among: repos)
        let r = f.apply(scan)
        XCTAssertEqual(r.worktreeCount, a.worktrees.count + b.worktrees.count)
        XCTAssertEqual(r.repos.count, 2)
        XCTAssertEqual(r.totals.staleWorktrees, ScanResult(scannedAt: scan.scannedAt, roots: [], volume: nil, repos: [a, b], caches: [], skippedPaths: 0).totals.staleWorktrees)
        XCTAssertTrue(r.headline.contains("in 2 repos"), r.headline)
    }

    func testCleanupPlanOnlyHasFilteredWorktrees() throws {
        let all = Cleanup.plan(scan)
        let withStale = try XCTUnwrap(repos.first { r in all.contains { $0.repo == r.name } })
        var f = RepoFilter.all
        f.toggle(withStale.path)
        let plan = Cleanup.plan(scan, filter: f)
        XCTAssertFalse(plan.contains { $0.repo == withStale.name })
        XCTAssertLessThan(plan.count, all.count)
        let shown = Set(f.apply(scan).repos.flatMap { $0.worktrees.map(\.path) })
        for item in plan { XCTAssertTrue(shown.contains(item.path), item.path) }
        f.selectNone(repos)
        XCTAssertTrue(Cleanup.plan(scan, filter: f).isEmpty)
    }

    func testFilterNamesAndSearch() {
        XCTAssertEqual(RepoFilter.only(names: [a.name.uppercased()], among: repos).selected(repos).map(\.path), [a.path])
        XCTAssertEqual(RepoFilter.only(names: [b.path], among: repos).selected(repos).map(\.path), [b.path])
        XCTAssertTrue(RepoFilter.only(names: ["nope"], among: repos).isEmpty(repos))
        XCTAssertEqual(RepoFilter.matching(repos, query: " ").count, repos.count)
        XCTAssertTrue(RepoFilter.matching(repos, query: a.name).contains(a))
    }

    func testPersistence() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "arborist-test-\(UUID().uuidString)"))
        XCTAssertEqual(RepoFilter.load(d), .all)
        RepoFilter(excluded: [a.path]).save(d)
        XCTAssertEqual(RepoFilter.load(d).excluded, [a.path])
    }

    func testLayoutWithSubset() {
        let f = RepoFilter.only(names: [a.name, b.name], among: repos)
        let r = f.apply(scan)
        let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        XCTAssertEqual(map.leaves.count, r.worktreeCount)
        let paths = Set((a.worktrees + b.worktrees).map(\.path))
        for l in map.leaves { XCTAssertTrue(paths.contains(l.item.id), l.item.id) }
        XCTAssertNotNil(MapTransform.usable(map, into: Pt(PopoverLayout.mapWidth, PopoverLayout.mapHeight)))
        let rep = HoverSweep.Report(HoverSweep.run(map, space: LeafSVG.popoverSpace(map), rows: 5, perRow: 30))
        XCTAssertEqual(rep.mismatches, 0, rep.summary)
        XCTAssertEqual(rep.stripMismatches, 0, rep.summary)
        XCTAssertEqual(rep.reachFailures, 0, rep.summary)
    }

    /// The real CLI with --filter: 0 mismatches, no strip mismatches, D25 panel checks 0, the pin holds.
    func testCLISweepWithFilter() throws {
        let bin = try XCTUnwrap(HoverSweepTruthTests.cliBinary())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fsweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["render", "--busy", "--filter", "\(a.name),\(b.name)", "--hover-sweep", dir.path]
        p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let r = try JSONDecoder().decode(HoverSweep.Report.self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))
        XCTAssertEqual(r.mismatches, 0, r.summary)
        XCTAssertEqual(r.stripMismatches, 0, r.summary)
        XCTAssertEqual(r.idleEmptyGapViolations + r.legendTruncations + r.hoverTransitions, 0, r.summary)
        XCTAssertEqual(r.reachFailures, 0, r.summary)
        XCTAssertGreaterThan(r.hoveredCount, 0)
        let shown = Set((a.worktrees + b.worktrees).map(\.path))
        for f in r.frames { if let h = f.hovered { XCTAssertTrue(shown.contains(h), h) } }
    }
}

/// D22: the docked strip and its fixed button frames.
final class StripLayoutTests: XCTestCase, @unchecked Sendable {
    func testStripSitsBelowTheMapInsideThePopover() {
        let s = PopoverSpace(mapOrigin: Pt(16, 52), size: Pt(480, 700))
        XCTAssertEqual(s.stripRect, Rect(x: 16, y: 52 + 400 + PopoverLayout.stripGap, w: 448, h: PopoverLayout.stripHeight))
        for b in StripLayout.buttons(in: s.stripRect) {
            XCTAssertTrue(b.rect.x >= s.stripRect.x && b.rect.x + b.rect.w <= s.stripRect.x + s.stripRect.w, b.name)
            XCTAssertTrue(b.rect.y >= s.stripRect.y && b.rect.y + b.rect.h <= s.stripRect.y + s.stripRect.h, b.name)
            XCTAssertEqual(StripLayout.button(at: b.rect.center, in: s.stripRect), b.name)
        }
        XCTAssertNil(StripLayout.button(at: Pt(0, 0), in: s.stripRect))
    }

    func testReachFailureWhenThePinIsLost() {
        var f = HoverSweep.Frame(frame: 0, x: 0, y: 0, t: 0, hovered: nil, pinned: nil, strip: nil)
        f.reachTarget = true; f.pinTruth = "a"; f.buttonUnderPointer = "Reveal in Finder"
        XCTAssertTrue(f.isReachFailure)
        f.pinned = "a"; f.strip = "a"
        XCTAssertFalse(f.isReachFailure)
    }
}
