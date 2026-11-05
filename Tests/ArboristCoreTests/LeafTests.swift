import XCTest
@testable import ArboristCore

final class LeafLayoutTests: XCTestCase, @unchecked Sendable {
    func testLayoutIsDeterministic() {
        let a = LeafLayout.layout(LeafSample.groups), b = LeafLayout.layout(LeafSample.groups)
        XCTAssertEqual(a, b)
        let r = LeafSample.scan
        XCTAssertEqual(LeafSVG.popover(r, map: a, now: LeafSample.now), LeafSVG.popover(r, map: b, now: LeafSample.now))
        let c = LeafLayout.layout(LeafSample.groups, seed: "another seed")
        XCTAssertNotEqual(a.leaves.map(\.centroid), c.leaves.map(\.centroid), "seed changes the map")
    }

    func testEveryWorktreeGetsALeafInsideTheMap() {
        let r = LeafSample.scan
        let m = LeafLayout.layout(LeafSample.groups, staleCount: r.totals.staleWorktrees)
        XCTAssertEqual(m.leaves.count, r.worktreeCount)
        XCTAssertEqual(Set(m.leaves.map(\.item.id)), Set(r.repos.flatMap(\.worktrees).map(\.path)))
        XCTAssertEqual(m.staleCount, 4)
        for l in m.leaves {
            let (x0, y0, x1, y1) = Geo.bbox(l.outline)
            XCTAssertGreaterThan(x0, -4); XCTAssertGreaterThan(y0, -4)
            XCTAssertLessThan(x1, m.width + 4); XCTAssertLessThan(y1, m.height + 4)
        }
    }

    func testOnlyWorktreeLeavesWithRebuildableInnerShare() {
        let r = LeafSample.scan
        let g = LeafLayout.groups(from: r)
        XCTAssertEqual(g.count, r.repos.count, "one group per repo; no Caches or Free groups")
        let kinds = Set(g.flatMap(\.items).map(\.kind))
        XCTAssertEqual(kinds, [.main, .worktree], "no cache, app data or deps leaves")
        let m = LeafLayout.layout(g)
        for l in m.leaves {
            let share = l.item.rebuildableShare
            if share > 0.02 {
                let ratio = Geo.area(l.inner) / Geo.area(l.outline)
                XCTAssertEqual(ratio, share, accuracy: 0.01, l.item.name)
                XCTAssertTrue(Geo.inside(l.outline, Geo.centroid(l.inner)))
            } else {
                XCTAssertTrue(l.inner.isEmpty)
            }
        }
        let acorn = m.leaves.first { $0.item.name == "acorn-ui" }!
        XCTAssertEqual(acorn.item.rebuildableShare, 0.9, accuracy: 0.001, "5.6 of 6.2 GB, clamped so a rim of source always shows")
    }

    func testAreasGrowWithSizeButSmallWorktreesStayVisible() {
        let m = LeafLayout.layout(LeafSample.groups)
        let rowanMain = m.leaves.first { $0.group == "rowan" && $0.item.kind == .main }!    // 12.5 GB
        let bark = m.leaves.first { $0.item.name == "bark-tests" }!                     // 0.1 GB
        XCTAssertGreaterThan(Geo.area(rowanMain.outline), Geo.area(bark.outline) * 1.5)
        XCTAssertGreaterThan(LeafLayout.weight(bytes: 0), 0)
        XCTAssertLessThan(LeafLayout.weight(bytes: 20_000_000_000) / LeafLayout.weight(bytes: 50_000_000), 10)
    }

    func testMinimumLeafSize() {
        // One huge item and one tiny one: the tiny one is padded up and still gets a usable leaf.
        let g = [LeafGroup(name: "r", items: [
            LeafItem(id: "big", name: "main", bytes: 500_000_000_000, kind: .main, state: .clean),
            LeafItem(id: "tiny", name: "wt", bytes: 1_000, kind: .worktree, state: .stale),
        ])]
        let m = LeafLayout.layout(g)
        let tiny = try! XCTUnwrap(m.leaves.first { $0.item.id == "tiny" })
        let (x0, y0, x1, y1) = Geo.bbox(tiny.outline)
        XCTAssertGreaterThanOrEqual(min(x1 - x0, y1 - y0), LeafLayout.minLeaf * 0.6)
    }

    func testTinyItemsFoldIntoOther() {
        let items = [LeafItem(id: "a", name: "main", bytes: 1000, kind: .main, state: .clean)]
            + (0..<5).map { LeafItem(id: "t\($0)", name: "t\($0)", bytes: 3, kind: .worktree, state: $0 == 0 ? .protected : .stale) }
        let g = LeafLayout.fold([LeafGroup(name: "r", items: items)], minBytes: 10)
        XCTAssertEqual(g[0].items.count, 2)
        let other = g[0].items[1]
        XCTAssertEqual(other.foldedCount, 5)
        XCTAssertEqual(other.state, .protected, "protected wins when folding")
        XCTAssertEqual(other.bytes, 15)
    }

    func testMinBytesScalesWithMap() {
        XCTAssertEqual(LeafLayout.minBytes(total: 1_000_000, width: 100, height: 100), LeafLayout.minBytes(total: 1_000_000, width: 100, height: 100))
        XCTAssertGreaterThan(LeafLayout.minBytes(total: 1_000_000, width: 100, height: 100), LeafLayout.minBytes(total: 1_000_000, width: 400, height: 400))
    }

    func testGroupsFromScanMapsStatusToColour() {
        func wt(_ p: String, main: Bool, dirty: Bool = false, unpushed: Int? = nil, stale: Bool = false) -> Worktree {
            Worktree(path: p, isMain: main, branch: main ? "main" : "f", head: nil, lastCommitDate: nil, dirty: dirty, unpushedCommits: unpushed,
                     hasUpstream: unpushed != nil, stale: stale, staleReasons: stale ? [.merged] : [], size: SizeSplit(rebuildable: 5, source: 10), removeCommand: main ? nil : "git worktree remove \(p)")
        }
        let r = ScanResult(scannedAt: Date(), roots: [], volume: VolumeInfo(path: "/", freeBytes: 1000, totalBytes: 2000),
                           repos: [Repo(name: "app", path: "/a", defaultBranch: "main", worktrees: [wt("/a", main: true, dirty: true), wt("/b", main: false, unpushed: 2), wt("/c", main: false), wt("/d", main: false, stale: true), wt("/e", main: false, dirty: true, stale: true)])],
                           caches: [CacheEntry(name: "npm", path: "/n", bytes: 7)], skippedPaths: 0)
        let g = LeafLayout.groups(from: r)
        XCTAssertEqual(g.map(\.name), ["app"])
        XCTAssertEqual(g[0].items.map(\.state), [.protected, .protected, .clean, .stale, .protected], "uncommitted work beats stale")
        XCTAssertEqual(g[0].items.map(\.status), [.uncommitted, .unpushed, .clean, .merged, .uncommitted])
        XCTAssertEqual(g[0].items.map(\.kind), [.main, .worktree, .worktree, .worktree, .worktree])
        XCTAssertEqual(g[0].items[0].rebuildableBytes, 5)
        XCTAssertEqual(g[0].items[0].repo, "app")
    }
}

final class LeafStageTests: XCTestCase, @unchecked Sendable {
    let gb: Int64 = 1_000_000_000

    func testBoundariesAtDefaultThreshold() {
        // threshold 20 GB: healthy > 60, droop 30…60, wilted 20…30, dry < 20
        func st(_ g: Int64) -> LeafStage { LeafStage.stage(freeBytes: g, thresholdGB: 20) }
        XCTAssertEqual(st(60 * gb + 1), .healthy)
        XCTAssertEqual(st(60 * gb), .droop)
        XCTAssertEqual(st(30 * gb), .droop)
        XCTAssertEqual(st(30 * gb - 1), .wilted)
        XCTAssertEqual(st(20 * gb), .wilted)
        XCTAssertEqual(st(20 * gb - 1), .dry)
        XCTAssertEqual(st(0), .dry)
        XCTAssertEqual(st(500 * gb), .healthy)
    }

    func testCustomMultipliersAndConfig() throws {
        let m = StageMultipliers(healthy: 5, droop: 2, wilted: 1.2)
        XCTAssertEqual(LeafStage.stage(freeBytes: 100 * gb, thresholdGB: 10, multipliers: m), .healthy)
        XCTAssertEqual(LeafStage.stage(freeBytes: 50 * gb, thresholdGB: 10, multipliers: m), .droop)
        XCTAssertEqual(LeafStage.stage(freeBytes: 12 * gb, thresholdGB: 10, multipliers: m), .wilted)
        XCTAssertEqual(LeafStage.stage(freeBytes: 11 * gb, thresholdGB: 10, multipliers: m), .dry)
        // Old config files without the new keys still load, with defaults.
        let old = try JSONDecoder().decode(ArboristConfig.self, from: Data(#"{"roots":["~/code"],"lowSpaceThresholdGB":10,"maxDepth":3}"#.utf8))
        XCTAssertEqual(old.leafStages, .default)
        XCTAssertTrue(old.showFreeText)
        XCTAssertEqual(old.stage(freeBytes: 25 * gb), .droop)
        let custom = try JSONDecoder().decode(ArboristConfig.self, from: Data(#"{"leafStages":{"healthy":4,"droop":2,"wilted":1},"showFreeText":false}"#.utf8))
        XCTAssertEqual(custom.leafStages.healthy, 4)
        XCTAssertFalse(custom.showFreeText)
        XCTAssertEqual(custom.roots, ArboristConfig.defaults.roots)
    }

    func testAccessibilityLabelHasFreeGB() {
        XCTAssertEqual(LeafStage.accessibilityLabel(.wilted, freeBytes: 25 * gb), "Arborist: leaf wilted, 25.0 GB free")
    }

    func testGlyphsAreDistinctAndInBounds() {
        let gs = LeafStage.allCases.map(LeafGlyph.glyph)
        XCTAssertEqual(Set(gs.map { Geo.centroid($0.outline) }).count, 4)
        XCTAssertFalse(gs[3].filled, "dry is outline only")
        for g in gs { for p in g.outline + g.stem { XCTAssert((-0.05...1.05).contains(p.x) && (-0.05...1.05).contains(p.y), "\(p)") } }
    }
}
