import XCTest
@testable import ArboristCore

final class LeafLayoutTests: XCTestCase {
    func testLayoutIsDeterministic() {
        let a = LeafLayout.layout(LeafSample.groups), b = LeafLayout.layout(LeafSample.groups)
        XCTAssertEqual(a, b)
        XCTAssertEqual(LeafSVG.popover(a, freeBytes: 1, totalBytes: 2), LeafSVG.popover(b, freeBytes: 1, totalBytes: 2))
        let c = LeafLayout.layout(LeafSample.groups, seed: "another seed")
        XCTAssertNotEqual(a.leaves.map(\.centroid), c.leaves.map(\.centroid), "seed changes the map")
    }

    func testEveryItemGetsALeafInsideTheMap() {
        let m = LeafLayout.layout(LeafSample.groups)
        XCTAssertEqual(m.leaves.count, LeafSample.groups.flatMap(\.items).count)
        XCTAssertEqual(m.staleCount, 3)
        for l in m.leaves {
            let (x0, y0, x1, y1) = Geo.bbox(l.outline)
            XCTAssertGreaterThan(x0, -4); XCTAssertGreaterThan(y0, -4)
            XCTAssertLessThan(x1, m.width + 4); XCTAssertLessThan(y1, m.height + 4)
        }
    }

    func testAreasTrackBytes() {
        let m = LeafLayout.layout(LeafSample.groups)
        let farm = m.leaves.first { $0.group == "farm" && $0.item.kind == .deps }!   // 14.0 G
        let drift = m.leaves.first { $0.group == "drift" }!                          // 5.2 G
        XCTAssertGreaterThan(Geo.area(farm.outline), Geo.area(drift.outline) * 1.6)
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
        XCTAssertGreaterThanOrEqual(Geo.area(tiny.outline), LeafLayout.minLeaf * LeafLayout.minLeaf * 0.5)
    }

    func testTinyItemsFoldIntoOther() {
        let items = [LeafItem(id: "a", name: "main", bytes: 1000, kind: .main, state: .clean)]
            + (0..<5).map { LeafItem(id: "t\($0)", name: "t\($0)", bytes: 3, kind: .worktree, state: $0 == 0 ? .protected : .stale) }
        let folded = LeafLayout.fold([LeafGroup(name: "g", items: items)], minBytes: 10)[0]
        XCTAssertEqual(folded.items.map(\.name), ["main", "other"])
        let other = folded.items[1]
        XCTAssertEqual(other.foldedCount, 5)
        XCTAssertEqual(other.bytes, 15)
        XCTAssertEqual(other.state, .protected, "protected work inside 'other' keeps it moss")
        let allStale = LeafLayout.fold([LeafGroup(name: "g", items: [items[0], items[2], items[3]])], minBytes: 10)[0]
        XCTAssertEqual(allStale.items.last?.state, .stale)
        XCTAssertEqual(allStale.items.last?.bytes, 10, "padded to the minimum")
    }

    func testMinBytesScalesWithMap() {
        XCTAssertEqual(LeafLayout.minBytes(total: 1_000_000, width: 100, height: 100, minLeaf: 10), Int64((1_000_000.0 * 100 / (10_000 * 0.82)).rounded(.up)))
    }

    func testGroupsFromScanMapsStates() {
        func wt(_ p: String, main: Bool, dirty: Bool = false, unpushed: Int? = nil, stale: Bool = false) -> Worktree {
            Worktree(path: p, isMain: main, branch: main ? "main" : "f", head: nil, lastCommitDate: nil, dirty: dirty, unpushedCommits: unpushed,
                     hasUpstream: unpushed != nil, stale: stale, staleReasons: stale ? [.merged] : [], size: SizeSplit(rebuildable: 5, source: 10), removeCommand: main ? nil : "git worktree remove \(p)")
        }
        let r = ScanResult(scannedAt: Date(), roots: [], volume: VolumeInfo(path: "/", freeBytes: 1000, totalBytes: 2000),
                           repos: [Repo(name: "app", path: "/a", defaultBranch: "main", worktrees: [wt("/a", main: true, dirty: true), wt("/b", main: false, unpushed: 2), wt("/c", main: false), wt("/d", main: false, stale: true)])],
                           caches: [CacheEntry(name: "npm", path: "/n", bytes: 7)], skippedPaths: 0)
        let g = LeafLayout.groups(from: r)
        XCTAssertEqual(g.map(\.name), ["app", "Caches", "free"])
        XCTAssertEqual(g[0].items.map(\.state), [.protected, .protected, .clean, .stale, .deps])
        XCTAssertEqual(g[0].items.map(\.kind), [.main, .worktree, .worktree, .worktree, .deps])
        XCTAssertEqual(g[0].items.last?.bytes, 20, "rebuildable summed per repo")
        XCTAssertEqual(g[1].items.first?.kind, .cache)
    }
}

final class LeafStageTests: XCTestCase {
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
