@testable import ArboristCore
import XCTest

/// D16: in a gap farther than the snap radius from every leaf, hover clears after the 80 ms grace.
final class GapClearTests: XCTestCase {
    let map: LeafMap = {
        let r = LeafSample.busy
        return LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }()

    /// A point on the map farther than the snap radius from every leaf, and a leaf near it.
    func farGap() throws -> (gap: Pt, leaf: Leaf) {
        for gx in stride(from: 5.0, to: map.width, by: 3) {
            for gy in stride(from: 5.0, to: map.height, by: 3) {
                let p = Pt(gx, gy)
                if map.hit(at: p) == nil, let l = map.leaves.min(by: { Geo.distance(p, toOutline: $0.outline) < Geo.distance(p, toOutline: $1.outline) }) {
                    return (p, l)
                }
            }
        }
        throw XCTSkip("no far gap in this layout")
    }

    func testBigGapClearsAfterTheGrace() throws {
        let (gap, leaf) = try farGap()
        var t = HoverTracker()
        t.move(to: leaf.centroid, in: map, at: 0)
        t.move(to: gap, in: map, at: 1)
        XCTAssertEqual(t.hovered, leaf.item.id, "not before the grace")
        XCTAssertNotNil(t.clearAt)
        t.move(to: Pt(gap.x + 0.5, gap.y), in: map, at: 1 + HoverTracker.leaveDelay / 2)
        XCTAssertEqual(t.clearAt, 1 + HoverTracker.leaveDelay, "moving inside the gap doesn't postpone the clear")
        XCTAssertTrue(t.settle(at: 1 + HoverTracker.leaveDelay))
        XCTAssertNil(t.hovered); XCTAssertNil(t.strip)
        // A later move in the gap also applies it without a timer.
        var u = HoverTracker()
        u.move(to: leaf.centroid, in: map, at: 0); u.move(to: gap, in: map, at: 1)
        u.move(to: gap, in: map, at: 1.2)
        XCTAssertNil(u.hovered)
    }

    func testNearGapSnaps() throws {
        // A point just outside a leaf's edge (within the snap radius) but inside no outline.
        for l in map.leaves {
            let v = l.outline[0]
            let p = Pt(v.x + (v.x - l.centroid.x) * 0.04, v.y + (v.y - l.centroid.y) * 0.04)
            guard map.leaf(at: p) == nil, let snap = map.hit(at: p) else { continue }
            var t = HoverTracker()
            t.move(to: snap.centroid, in: map, at: 0)
            t.move(to: p, in: map, at: 1)
            XCTAssertNil(t.clearAt); XCTAssertEqual(t.hovered, snap.item.id)
            XCTAssertFalse(t.settle(at: 5))
            return
        }
        XCTFail("no near-gap point found")
    }

    func testReturningWithinTheGraceCancels() throws {
        let (gap, leaf) = try farGap()
        var t = HoverTracker()
        t.move(to: leaf.centroid, in: map, at: 0)
        t.move(to: gap, in: map, at: 1)
        t.move(to: leaf.centroid, in: map, at: 1 + HoverTracker.leaveDelay / 2)
        XCTAssertNil(t.clearAt)
        XCTAssertFalse(t.settle(at: 9))
        XCTAssertEqual(t.hovered, leaf.item.id)
    }

    func testPinnedSurvivesAFarGap() throws {
        let (gap, leaf) = try farGap()
        var t = HoverTracker()
        t.move(to: leaf.centroid, in: map, at: 0)
        XCTAssertTrue(t.click(at: leaf.centroid, in: map)); XCTAssertEqual(t.pinned, leaf.item.id)
        t.move(to: gap, in: map, at: 1)
        XCTAssertTrue(t.settle(at: 9))
        XCTAssertNil(t.hovered, "D22: the hover clears, the pin holds the strip")
        XCTAssertEqual(t.strip, leaf.item.id)
        t.click(at: leaf.centroid, in: map) // unpin
        XCTAssertNil(t.pinned)
        XCTAssertEqual(t.strip, t.hovered, "unpinned: the strip follows the hover again")
    }

    func testSweepExpectsNullInFarGaps() {
        let r = HoverSweep.Report(HoverSweep.run(map, rows: 7, perRow: 40))
        XCTAssertEqual(r.mismatches, 0, r.summary)
        let far = r.frames.filter { $0.inGap && $0.snappedTo == nil }
        XCTAssertFalse(far.isEmpty)
        XCTAssertTrue(far.allSatisfy { $0.hovered == nil && $0.expected == nil })
    }
}
