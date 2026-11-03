@testable import ArboristCore
import XCTest

/// D24: one shared slot (legend at rest, details on hover or pin), the map never moves, the footer buttons
/// stay visible, and the details never overlap at any content length.
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
        XCTAssertEqual(idle.slotFrame, hover.slotFrame); XCTAssertEqual(idle.slotFrame, pin.slotFrame)
    }

    func testFixedFramesAreTheSameForEveryLeaf() {
        let (r, map) = busy()
        let all = map.leaves.compactMap { LeafSVG.drawn(r, map: map, hover: $0.item.id, pinned: nil, now: LeafSample.now).stripFrames }
        XCTAssertEqual(all.count, map.leaves.count)
        XCTAssertTrue(all.allSatisfy { StripLayout.fixedPart($0) == StripLayout.fixedPart(all[0]) })
        XCTAssertEqual(StripLayout.fixedPart(all[0]).count, 1 + 4 + 1 + 3, "path, 4 columns, message, 3 buttons")
    }

    func testVerticalRhythm() {
        let rows = ["title", "path", "stats", "message"].map(StripLayout.row) + [StripLayout.buttons(in: Rect(x: 0, y: 0, w: 0, h: 0))[0].rect]
        for i in 1..<rows.count { XCTAssertLessThan(rows[i - 1].y + rows[i - 1].h, rows[i].y, "row \(i) touches the one above") }
        XCTAssertEqual(rows[1].y - (rows[0].y + rows[0].h), StripLayout.gap)
        XCTAssertEqual(rows[2].y - (rows[1].y + rows[1].h), StripLayout.gap)
        XCTAssertEqual(rows[3].y - (rows[2].y + rows[2].h), StripLayout.gap)
        XCTAssertEqual(rows[4].y - (rows[3].y + rows[3].h), StripLayout.messageBelow)
        XCTAssertEqual(rows[4].y + rows[4].h + StripLayout.padding, PopoverLayout.stripHeight)
        // Buttons: left edge on the grid's, consistent spacing, Remove flush right.
        let b = StripLayout.buttons(in: Rect(x: 0, y: 0, w: 0, h: 0)).map(\.rect)
        XCTAssertEqual(b[0].x, StripLayout.columns[0].x)
        XCTAssertEqual(b[1].x - (b[0].x + b[0].w), StripLayout.buttonGap)
        XCTAssertEqual(b[2].x + b[2].w, StripLayout.columns[3].x + StripLayout.columns[3].w)
        XCTAssertGreaterThanOrEqual(b[2].x - (b[1].x + b[1].w), StripLayout.buttonGap)
    }

    func testNoOverlapAtAnyLength() {
        let slot = Rect(x: 16, y: 470, w: PopoverLayout.mapWidth, h: PopoverLayout.stripHeight)
        let lengths = [0, 1, 5, 20, 60, 300]
        for bl in lengths { for rl in lengths { for tl in [0, 5, 40] { for pin in [false, true] {
            let f = StripLayout.frames(in: slot, branch: String(repeating: "W", count: bl), tag: String(repeating: "M", count: tl),
                                       repo: String(repeating: "m", count: rl), pinned: pin)
            XCTAssertEqual(StripLayout.overlaps(f, in: slot), 0, "branch \(bl) repo \(rl) tag \(tl) pinned \(pin)")
        } } } }
        // Short strings keep their natural width; long ones are cut to the frame.
        let short = StripLayout.title(branch: "b", tag: "Clean", repo: "r", pinned: false)
        XCTAssertEqual(short[0].rect.w, LeafText.width("b", size: 12), accuracy: 0.01)
        XCTAssertEqual(LeafSVG.fit(String(repeating: "W", count: 300), 100, 12).last, "…")
        XCTAssertLessThanOrEqual(LeafText.width(LeafSVG.fit(String(repeating: "W", count: 300), 100, 12), size: 12), 100)
    }

    func testOverlapCheckCatchesOverlaps() {
        let slot = Rect(x: 0, y: 0, w: 100, h: 100)
        XCTAssertEqual(StripLayout.overlaps([Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 5, y: 5, w: 10, h: 10)], in: slot), 1)
        XCTAssertEqual(StripLayout.overlaps([Rect(x: 0, y: 0, w: 10, h: 10), Rect(x: 10, y: 0, w: 10, h: 10)], in: slot), 0, "touching is fine")
        XCTAssertEqual(StripLayout.overlaps([Rect(x: 95, y: 0, w: 10, h: 10)], in: slot), 1, "outside the slot")
    }

    func testLayoutCasesCoverEveryLeafAndExtremes() {
        let (r, map) = busy()
        let cases = LayoutCase.all(r, map: map, now: LeafSample.now)
        XCTAssertEqual(cases.count, (map.leaves.count + 6) * 2)
        XCTAssertEqual(cases.map(\.overlaps).reduce(0, +), 0, cases.filter { $0.overlaps > 0 }.map(\.name).joined(separator: ", "))
    }

    func testSlotAndFooterRowFitThePopover() {
        let (_, map) = busy()
        let s = LeafSVG.popoverSpace(map)
        XCTAssertEqual(s.size.y, PopoverLayout.height, "fixed total height")
        XCTAssertFalse(s.clips(s.stripRect)); XCTAssertFalse(s.clips(s.footerRect))
        XCTAssertGreaterThanOrEqual(s.stripRect.y, 52 + PopoverLayout.mapHeight, "never over the map")
        XCTAssertGreaterThan(s.footerRect.y, s.stripRect.y + s.stripRect.h, "footer row below the slot")
        let fb = FooterLayout.buttons(in: s.footerRect).map(\.rect)
        XCTAssertFalse(HoverSweep.footerHidden(fb, slot: s.stripRect, popover: s.size))
        XCTAssertTrue(HoverSweep.footerHidden(Array(fb.dropLast()), slot: s.stripRect, popover: s.size))
        XCTAssertTrue(HoverSweep.footerHidden(fb.map { _ in s.stripRect }, slot: s.stripRect, popover: s.size))
    }

    func testSlotIsNeverEmpty() {
        let (r, map) = busy()
        let idle = LeafSVG.popover(r, map: map, now: LeafSample.now)
        XCTAssertTrue(idle.contains(" free</text>") && idle.contains("Merged / stale"), "legend and storage bar at rest")
        let pinned = LeafSVG.popover(r, map: map, hover: nil, pinned: map.leaves[0].item.id, now: LeafSample.now)
        XCTAssertTrue(pinned.contains("Pinned · Esc") && pinned.contains("Remove worktree"))
        XCTAssertTrue(pinned.contains(">Rescan<") && pinned.contains(">List<"), "footer buttons stay while pinned")
    }

    func testReportCountsViolations() {
        var idle = HoverSweep.Frame(frame: 0, x: 0, y: 0, t: 0, hovered: nil)
        idle.mapFrame = Rect(x: 0, y: 0, w: 1, h: 1); idle.stripHeight = 10; idle.slotFrame = Rect(x: 0, y: 5, w: 1, h: 1)
        var shown = HoverSweep.Frame(frame: 1, x: 0, y: 0, t: 0, hovered: "a", strip: "a")
        shown.mapFrame = Rect(x: 0, y: 1, w: 1, h: 1); shown.stripHeight = PopoverLayout.stripHeight
        shown.stripFrames = [Rect(x: 0, y: 0, w: 1, h: 1), Rect(x: 0, y: 2, w: 1, h: 1)]; shown.slotFrame = idle.slotFrame
        shown.footerHidden = true; shown.overlaps = 2
        var shifted = shown; shifted.frame = 2; shifted.mapFrame = idle.mapFrame; shifted.footerHidden = false; shifted.overlaps = 0
        shifted.stripFrames = [Rect(x: 0, y: 0, w: 1, h: 1), Rect(x: 1, y: 2, w: 1, h: 1)]; shifted.slotFrame = Rect(x: 0, y: 6, w: 1, h: 1)
        let r = HoverSweep.Report([idle, shown, shifted], cases: [LayoutCase(name: "x", overlaps: 1)])
        XCTAssertEqual(r.idleStripViolations, 1)
        XCTAssertEqual(r.mapFrameShifts, 1)
        XCTAssertEqual(r.stripLayoutShifts, 1)
        XCTAssertEqual(r.slotFrameShifts, 1)
        XCTAssertEqual(r.footerHiddenFrames, 1)
        XCTAssertEqual(r.overlaps, 3)
        let back = try! JSONDecoder().decode(HoverSweep.Report.self, from: HoverSweep.json(r))
        XCTAssertEqual(back.overlaps, 3)
    }

    func testSweepIncludesIdleHoverAndPin() {
        let (r, map) = busy()
        let space = LeafSVG.popoverSpace(map)
        let rep = HoverSweep.Report(HoverSweep.run(map, space: space) { _, t, _ in
            LeafSVG.drawn(r, map: map, hover: t.hovered, pinned: t.pinned, now: LeafSample.now)
        }, cases: LayoutCase.all(r, map: map, now: LeafSample.now))
        XCTAssertGreaterThan(rep.idleFrames, 0); XCTAssertGreaterThan(rep.pinnedFrames, 0); XCTAssertGreaterThan(rep.hoveredCount, 40)
        XCTAssertEqual(rep.idleStripViolations + rep.mapFrameShifts + rep.stripLayoutShifts, 0, rep.summary)
        XCTAssertEqual(rep.slotFrameShifts + rep.footerHiddenFrames + rep.overlaps, 0, rep.summary)
        XCTAssertGreaterThan(rep.frames.filter { $0.pinned != nil && $0.footerButtons?.count == 5 }.count, 0)
        XCTAssertEqual(rep.reachFailures + rep.mismatches + rep.stripMismatches + rep.tooltipClipped, 0, rep.summary)
    }
}
