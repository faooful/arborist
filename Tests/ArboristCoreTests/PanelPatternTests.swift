import XCTest
@testable import ArboristCore

/// D25: the panel pattern: no tooltip, a resting panel with no blank space, a legend that fits, and
/// leaf → leaf value swaps with no transition.
final class PanelPatternTests: XCTestCase, @unchecked Sendable {
    private func busy() -> (ScanResult, LeafMap) {
        let r = LeafSample.busy
        return (r, LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees))
    }

    func testRestRowsFillTheSlot() {
        let slot = Rect(x: 0, y: 0, w: PopoverLayout.mapWidth, h: PopoverLayout.stripHeight)
        let frames = RestLayout.frames(in: slot, legend: RestLayout.legendLabels(ready: 3, showAll: false))
        XCTAssertLessThanOrEqual(RestLayout.emptyGap(frames, in: slot), RestLayout.maxEmptyGap)
        XCTAssertEqual(RestLayout.grid2Y + RestLayout.gridHeight + RestLayout.gap, slot.h - RestLayout.padding, accuracy: 0.01)
        XCTAssertEqual(StripLayout.overlaps(frames.filter { $0.y > RestLayout.legendY + 1 }, in: slot), 0)
        // The old layout (legend + bar only) leaves ~70 pt blank: the check catches it.
        XCTAssertGreaterThan(RestLayout.emptyGap(Array(frames.prefix(6)), in: slot), 40)
    }

    func testLegendFitsWithShowAllAndBigCounts() {
        let rowRight = RestLayout.padding + StripLayout.inner
        for ready in [0, 7, 1234] { for all in [false, true] {
            let items = RestLayout.legend(RestLayout.legendLabels(ready: ready, showAll: all))
            for i in items {
                let m = LegendMeasure(label: i.label, natural: LeafText.width(i.label, size: 11, weight: false), frame: i.text)
                XCTAssertFalse(m.truncated(rowRight: rowRight), "\(i.label) ready \(ready) showAll \(all)")
            }
            XCTAssertFalse(items.map(\.label).contains { $0.hasPrefix("Caches") }, "Caches moved to the grid")
        } }
        XCTAssertTrue(LegendMeasure(label: "x", natural: 50, frame: Rect(x: 0, y: 0, w: 40, h: 1)).truncated(rowRight: 400))
        XCTAssertTrue(LegendMeasure(label: "x", natural: 10, frame: Rect(x: 395, y: 0, w: 10, h: 1)).truncated(rowRight: 400))
    }

    func testSummaryUsesRealValues() {
        let (r, _) = busy()
        let c = Dictionary(uniqueKeysWithValues: RestSummary.cells(r).map { ($0.label, $0.value) })
        XCTAssertEqual(c.count, 8)
        XCTAssertEqual(c["Worktrees"], "\(r.worktreeCount) in \(r.repos.count) repos")
        XCTAssertEqual(c["Caches"], Format.bytes(r.totals.caches))
        let ready = r.repos.flatMap(\.worktrees).filter(CleanupSafety.isReady)
        XCTAssertTrue(c["Ready to clean"]!.hasPrefix("\(ready.count) · "))
    }

    func testTransitionOnlyBetweenRestAndDetails() {
        XCTAssertEqual(PanelTransition.between(nil, "a"), .crossfade)
        XCTAssertEqual(PanelTransition.between("a", nil), .crossfade)
        XCTAssertEqual(PanelTransition.between("a", "b"), .none)
        XCTAssertEqual(PanelTransition.between(nil, "a", reduceMotion: true), .none)
    }

    func testSweepPanelChecksAreZero() {
        let (r, map) = busy()
        var prev: String?
        let rep = HoverSweep.Report(HoverSweep.run(map, space: LeafSVG.popoverSpace(map)) { _, t, _ in
            defer { prev = t.strip }
            return LeafSVG.drawn(r, map: map, hover: t.hovered, pinned: t.pinned, now: LeafSample.now, previousStrip: .some(prev))
        })
        XCTAssertEqual(rep.idleEmptyGapViolations + rep.legendTruncations + rep.hoverTransitions, 0, rep.summary)
        XCTAssertGreaterThan(rep.hoverSwaps, 5); XCTAssertGreaterThan(rep.restSwaps, 0); XCTAssertGreaterThan(rep.idleFrames, 0)
        XCTAssertLessThanOrEqual(rep.maxIdleEmptyGap, RestLayout.maxEmptyGap)
    }

    func testReportCountsPanelViolations() {
        var a = HoverSweep.Frame(frame: 0, x: 0, y: 0, t: 0, hovered: "a", strip: "a")
        var b = a; b.frame = 1; b.hovered = "b"; b.strip = "b"; b.transition = .crossfade
        var idle = HoverSweep.Frame(frame: 2, x: 0, y: 0, t: 0, hovered: nil)
        idle.idleEmptyGap = 100; idle.legendTruncated = 2; idle.transition = .crossfade
        a.transition = .none
        let rep = HoverSweep.Report([a, b, idle])
        XCTAssertEqual(rep.hoverTransitions, 1); XCTAssertEqual(rep.hoverSwaps, 1); XCTAssertEqual(rep.restSwaps, 1)
        XCTAssertEqual(rep.idleEmptyGapViolations, 1); XCTAssertEqual(rep.legendTruncations, 2)
    }
}
