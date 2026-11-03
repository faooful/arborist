@testable import ArboristCore
import XCTest

/// D24: the strip takes no space at rest, the map never moves, and only the strip's values swap.
final class StripIdleTests: XCTestCase, @unchecked Sendable {
    private func busy() -> (ScanResult, LeafMap) {
        let r = LeafSample.busy
        return (r, LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees))
    }

    func testIdleDrawsNoStripAndTheMapStaysPut() {
        let (r, map) = busy()
        let idle = LeafSVG.drawn(r, map: map, hover: nil, pinned: nil, now: LeafSample.now)
        XCTAssertEqual(idle.stripHeight, 0)
        XCTAssertNil(idle.stripFrames)
        XCTAssertFalse(LeafSVG.popover(r, map: map, now: LeafSample.now).contains("Hover a leaf"))
        let a = map.leaves[0].item.id, b = map.leaves[map.leaves.count - 1].item.id
        let hover = LeafSVG.drawn(r, map: map, hover: a, pinned: nil, now: LeafSample.now)
        let pin = LeafSVG.drawn(r, map: map, hover: a, pinned: b, now: LeafSample.now)
        XCTAssertEqual(idle.mapFrame, hover.mapFrame)
        XCTAssertEqual(idle.mapFrame, pin.mapFrame)
        XCTAssertEqual(idle.mapFrame, Rect(x: 16, y: 52, w: PopoverLayout.mapWidth, h: PopoverLayout.mapHeight))
        XCTAssertEqual(hover.stripHeight, PopoverLayout.stripHeight)
    }

    func testStripFramesAreTheSameForEveryLeaf() {
        let (r, map) = busy()
        let all = map.leaves.compactMap { LeafSVG.drawn(r, map: map, hover: $0.item.id, pinned: nil, now: LeafSample.now).stripFrames }
        XCTAssertEqual(all.count, map.leaves.count)
        XCTAssertTrue(all.allSatisfy { $0 == all[0] })
        XCTAssertEqual(HoverSweep.sorted(all[0]), HoverSweep.sorted(StripLayout.frames(in: LeafSVG.popoverSpace(map).stripRect)))
    }

    func testStripFitsTheFooterSlotInsideThePopover() {
        let (_, map) = busy()
        let s = LeafSVG.popoverSpace(map)
        XCTAssertEqual(PopoverLayout.footerHeight, PopoverLayout.stripHeight)
        XCTAssertFalse(s.clips(s.stripRect))
        XCTAssertGreaterThanOrEqual(s.stripRect.y, 52 + PopoverLayout.mapHeight, "never over the map")
        for f in StripLayout.frames(in: s.stripRect) {
            XCTAssertTrue(f.x >= s.stripRect.x && f.x + f.w <= s.stripRect.x + s.stripRect.w + 0.001, "\(f)")
            XCTAssertTrue(f.y >= s.stripRect.y && f.y + f.h <= s.stripRect.y + s.stripRect.h, "\(f)")
        }
        // Rows don't overlap each other or the button row.
        let rows = StripLayout.rows.map(\.rect) + [Rect(x: 0, y: PopoverLayout.stripHeight - StripLayout.padding - StripLayout.row, w: 1, h: StripLayout.row)]
        for (i, a) in rows.enumerated() { for b in rows[(i + 1)...] { XCTAssertLessThanOrEqual(a.y + a.h, b.y) } }
    }

    func testReportCountsViolations() {
        var idle = HoverSweep.Frame(frame: 0, x: 0, y: 0, t: 0, hovered: nil)
        idle.mapFrame = Rect(x: 0, y: 0, w: 1, h: 1); idle.stripHeight = 10
        var shown = HoverSweep.Frame(frame: 1, x: 0, y: 0, t: 0, hovered: "a", strip: "a")
        shown.mapFrame = Rect(x: 0, y: 1, w: 1, h: 1); shown.stripHeight = PopoverLayout.stripHeight; shown.stripFrames = [Rect(x: 0, y: 0, w: 1, h: 1)]
        var shifted = shown; shifted.frame = 2; shifted.mapFrame = idle.mapFrame; shifted.stripFrames = [Rect(x: 1, y: 0, w: 1, h: 1)]
        let r = HoverSweep.Report([idle, shown, shifted])
        XCTAssertEqual(r.idleStripViolations, 1)
        XCTAssertEqual(r.mapFrameShifts, 1)
        XCTAssertEqual(r.stripLayoutShifts, 1)
    }

    func testSweepIncludesIdleHoverAndPin() {
        let (r, map) = busy()
        let space = LeafSVG.popoverSpace(map)
        let rep = HoverSweep.Report(HoverSweep.run(map, space: space) { _, t, _ in
            LeafSVG.drawn(r, map: map, hover: t.hovered, pinned: t.pinned, now: LeafSample.now)
        })
        XCTAssertGreaterThan(rep.idleFrames, 0); XCTAssertGreaterThan(rep.pinnedFrames, 0); XCTAssertGreaterThan(rep.hoveredCount, 40)
        XCTAssertEqual(rep.idleStripViolations + rep.mapFrameShifts + rep.stripLayoutShifts, 0, rep.summary)
        XCTAssertEqual(rep.reachFailures + rep.mismatches + rep.stripMismatches + rep.tooltipClipped, 0, rep.summary)
    }
}
