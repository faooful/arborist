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
        let rep = HoverSweep.Report(HoverSweep.run(map, path: HoverSweep.path(in: map, rows: 5, perRow: 30),
                                                   space: LeafSVG.cardSpace(map)))
        XCTAssertEqual(rep.mismatches, 0, rep.summary)
        XCTAssertEqual(rep.cardClipped, 0, rep.summary)
    }

    /// The real CLI with --filter: 0 mismatches and no clipped cards.
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
        XCTAssertEqual(r.cardClipped, 0, r.summary)
        XCTAssertGreaterThan(r.hoveredCount, 0)
        let shown = Set((a.worktrees + b.worktrees).map(\.path))
        for f in r.frames { if let h = f.hovered { XCTAssertTrue(shown.contains(h), h) } }
    }
}

/// D19: the hover card is placed against the whole popover and always fits.
final class CardPlacementTests: XCTestCase, @unchecked Sendable {
    let bounds = Pt(480, 560), size = LeafSVG.cardSlot

    func inside(_ o: Pt) -> Bool { Rect(x: o.x, y: o.y, w: size.x, h: size.y).inside(width: bounds.x, height: bounds.y) }

    func testBelowWhenThereIsRoom() {
        let leaf = Rect(x: 100, y: 60, w: 40, h: 30)
        let o = CardPlacement.place(leaf: leaf, size: size, in: bounds)
        XCTAssertGreaterThanOrEqual(o.y, leaf.y + leaf.h)
        XCTAssertTrue(inside(o))
    }

    func testFlipsAboveNearTheBottom() {
        let leaf = Rect(x: 200, y: 470, w: 60, h: 40)   // no room below, nor beside (card is 264 wide)
        let o = CardPlacement.place(leaf: leaf, size: size, in: bounds)
        XCTAssertLessThanOrEqual(o.y + size.y, leaf.y)
        XCTAssertTrue(inside(o))
    }

    func testClampsAtTheEdges() {
        for leaf in [Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 470, y: 0, w: 10, h: 10), Rect(x: 0, y: 550, w: 10, h: 10),
                     Rect(x: 470, y: 550, w: 10, h: 10), Rect(x: -50, y: 200, w: 30, h: 30), Rect(x: 460, y: 300, w: 60, h: 20)] {
            let o = CardPlacement.place(leaf: leaf, size: size, in: bounds)
            XCTAssertGreaterThanOrEqual(o.x, CardPlacement.margin - 0.001, "\(leaf)")
            XCTAssertGreaterThanOrEqual(o.y, CardPlacement.margin - 0.001, "\(leaf)")
            XCTAssertLessThanOrEqual(o.x + size.x, bounds.x - CardPlacement.margin + 0.001, "\(leaf)")
            XCTAssertLessThanOrEqual(o.y + size.y, bounds.y - CardPlacement.margin + 0.001, "\(leaf)")
        }
    }

    func testAlwaysFitsOnAGrid() {
        for x in stride(from: -20.0, through: 480, by: 23) {
            for y in stride(from: -20.0, through: 560, by: 23) {
                for (w, h) in [(8.0, 8.0), (60.0, 40.0), (200.0, 150.0)] {
                    XCTAssertTrue(inside(CardPlacement.place(leaf: Rect(x: x, y: y, w: w, h: h), size: size, in: bounds)), "\(x),\(y)")
                }
            }
        }
    }

    func testKeepsCurrentWhileItFits() {
        let cur = Pt(200, 300)
        XCTAssertEqual(CardPlacement.place(leaf: Rect(x: 20, y: 20, w: 30, h: 30), size: size, in: bounds, current: cur), cur)
    }

    /// The slot covers the tallest card, including the app's Remove row.
    func testSlotCoversEveryRow() {
        let r = LeafSample.busy
        for ref in WorktreeList.sorted(r) {
            XCTAssertLessThanOrEqual(LeafSVG.cardHeight(HoverCard(ref)) + LeafSVG.appCardExtra, LeafSVG.cardSlot.y + 0.001)
        }
    }

    /// The busy map in the real popover space: the card is never clipped, also with the map scaled.
    func testSweepNeverClipsTheCard() {
        let r = LeafSample.busy
        let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        for space in [LeafSVG.cardSpace(map),
                      CardSpace(mapOrigin: Pt(16, 52), size: Pt(480, 560), transform: .fit(map, into: Pt(448, 400)))] {
            let rep = HoverSweep.Report(HoverSweep.run(map, path: HoverSweep.path(in: map, rows: 9, perRow: 40),
                                                       transform: space.transform, space: space))
            XCTAssertEqual(rep.cardClipped, 0, rep.summary)
            XCTAssertEqual(rep.mismatches, 0, rep.summary)
            XCTAssertTrue(rep.frames.contains { $0.cardRect != nil })
        }
    }

    /// Without a space (old map-only anchoring) a card taller than the map would be reported clipped.
    func testClippedIsDetected() {
        let r = LeafSample.busy
        let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        let tiny = CardSpace(mapOrigin: Pt(0, 0), size: Pt(map.width, 100))
        let rep = HoverSweep.Report(HoverSweep.run(map, path: HoverSweep.path(in: map), space: tiny))
        XCTAssertGreaterThan(rep.cardClipped, 0)
    }
}
