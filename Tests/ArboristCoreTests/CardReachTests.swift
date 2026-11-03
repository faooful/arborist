@testable import ArboristCore
import XCTest

/// D20: the card can be reached: it has priority over the leaves under it, a corridor from the leaf to the
/// card holds it for the grace, another leaf takes over only after the dwell, and its buttons get the click.
final class CardReachTests: XCTestCase {
    let map: LeafMap = {
        let r = LeafSample.busy
        return LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }()
    var space: CardSpace { LeafSVG.cardSpace(map) }

    private func tracker(on leaf: Leaf) -> HoverTracker {
        var t = HoverTracker(); t.space = space
        t.move(to: leaf.centroid, in: map, at: 0)
        return t
    }
    private func toMap(_ q: Pt) -> Pt { space.transform.toMap(q - space.mapOrigin) }

    func testCardHasPriorityAndItsButtonsTakeTheClick() throws {
        let a = map.leaves[0]
        var t = tracker(on: a)
        let r = try XCTUnwrap(t.cardRect)
        for (_, b) in HoverCardLayout.buttons(in: r) {
            let p = toMap(b.center)
            t.move(to: p, in: map, at: 1)
            XCTAssertTrue(t.onCard); XCTAssertEqual(t.hovered, a.item.id)
            XCTAssertNil(t.clearAt); XCTAssertNil(t.switchAt)
            XCTAssertFalse(t.click(at: p, in: map), "the click belongs to the card's button")
            XCTAssertFalse(t.pinned)
            XCTAssertEqual(t.cardOpacity, 1, "an engaged card isn't faded")
        }
        // Leaving the card clears after the grace unless the pointer comes back.
        t.exit(at: 2); XCTAssertNil(t.clearAt, "the map's exit is ignored while on the card")
        t.exitCard(at: 2); XCTAssertFalse(t.settle(at: 2.05)); XCTAssertTrue(t.settle(at: 2.1)); XCTAssertNil(t.hovered)
    }

    func testCorridorHoldsTheCardForTheGrace() throws {
        // A leaf whose straight line to its card's button crosses another leaf.
        for a in map.leaves {
            var t = tracker(on: a)
            let path = HoverSweep.reachPath(t, steps: 40)
            guard let k = path.firstIndex(where: { p in map.hit(at: p).map { $0.item.id != a.item.id } ?? false && !(t.cardRect!.contains(space.toPopover(p))) }) else { continue }
            let other = map.hit(at: path[k])!.item.id
            t.move(to: path[k], in: map, at: 1)
            XCTAssertTrue(t.holding); XCTAssertEqual(t.hovered, a.item.id)
            XCTAssertEqual(t.corridorUntil, 1 + HoverTracker.cardGrace)
            t.move(to: path[k], in: map, at: 1.2); XCTAssertEqual(t.hovered, a.item.id, "still within the grace")
            // Past the grace it's an ordinary move: switch after the dwell.
            t.move(to: path[k], in: map, at: 1.3)
            XCTAssertFalse(t.holding); XCTAssertEqual(t.hovered, a.item.id)
            XCTAssertEqual(try XCTUnwrap(t.switchAt), 1.3 + HoverTracker.switchDwell, accuracy: 1e-9)
            XCTAssertTrue(t.settle(at: 1.3 + HoverTracker.switchDwell)); XCTAssertEqual(t.hovered, other)
            return
        }
        XCTFail("no reach path crosses another leaf")
    }

    func testSwitchingLeavesNeedsTheDwell() throws {
        for a in map.leaves {
            var t = tracker(on: a)
            guard let b = map.leaves.first(where: { $0.item.id != a.item.id && map.hit(at: $0.centroid)?.item.id == $0.item.id
                && !t.inCorridor(space.toPopover($0.centroid)) && !(t.cardRect!.contains(space.toPopover($0.centroid))) }) else { continue }
            t.move(to: b.centroid, in: map, at: 1)
            XCTAssertEqual(t.hovered, a.item.id, "no switch on a brush")
            XCTAssertFalse(t.settle(at: 1.1)); XCTAssertEqual(t.hovered, a.item.id)
            // Back on a within the dwell: the switch is dropped.
            t.move(to: a.centroid, in: map, at: 1.05); XCTAssertNil(t.switchAt)
            t.move(to: b.centroid, in: map, at: 2)
            XCTAssertTrue(t.settle(at: 2 + HoverTracker.switchDwell)); XCTAssertEqual(t.hovered, b.item.id)
            return
        }
        XCTFail("no pair outside the corridor")
    }

    func testSweepReachPathEndsOnAButton() throws {
        let frames = HoverSweep.run(map, path: HoverSweep.path(in: map), space: space)
        let r = HoverSweep.Report(frames)
        XCTAssertEqual(r.mismatches, 0, r.summary)
        XCTAssertEqual(r.cardClipped, 0, r.summary)
        XCTAssertEqual(r.cardReachFailures, 0, r.summary)
        let target = try XCTUnwrap(frames.first(where: \.reachTarget))
        XCTAssertNotNil(target.buttonUnderPointer)
        XCTAssertGreaterThan(r.onCardFrames, 0)
        XCTAssertNil(frames.last?.hovered, "leaving from the card clears")
        // The leaf hovered when the reach started is the one whose card's button is reached.
        let start = try XCTUnwrap(frames.firstIndex(where: \.reachTarget)) - 6
        XCTAssertEqual(frames[start].hovered, target.hovered)
    }

    func testHullContainsBothRects() {
        let h = HoverTracker.hull(Rect(x: 0, y: 0, w: 10, h: 10).corners + Rect(x: 50, y: 50, w: 10, h: 10).corners)
        XCTAssertTrue(Geo.inside(h, Pt(30, 30)))
        XCTAssertFalse(Geo.inside(h, Pt(50, 5)))
    }
}
