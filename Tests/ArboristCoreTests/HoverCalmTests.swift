@testable import ArboristCore
import XCTest

/// D15/D22: nearest-cell hit-testing, the grace period, the pin, and the sweep hook.
final class HoverCalmTests: XCTestCase, @unchecked Sendable {
    let map: LeafMap = {
        let r = LeafSample.busy
        return LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }()

    /// Every gutter point between two adjacent leaves resolves to one of them: hover never goes nil in between.
    func testNoNilBetweenAdjacentLeavesAcrossAGap() throws {
        var checkedGutterPoints = 0
        for a in map.leaves.prefix(30) {
            for b in map.leaves where b.item.id != a.item.id {
                // Adjacent: some vertex of b is within 8 pt of a's edge.
                guard b.outline.contains(where: { Geo.distance($0, toOutline: a.outline) < 8 }) else { continue }
                var t = HoverTracker()
                t.move(to: a.centroid, in: map, at: 0)
                XCTAssertEqual(t.hovered, a.item.id)
                for k in 0...60 {
                    let f = Double(k) / 60
                    let p = Pt(a.centroid.x + (b.centroid.x - a.centroid.x) * f, a.centroid.y + (b.centroid.y - a.centroid.y) * f)
                    if map.leaf(at: p) == nil { checkedGutterPoints += 1 }
                    t.move(to: p, in: map, at: f)
                    XCTAssertNotNil(t.hovered, "nil at \(p) between \(a.item.id) and \(b.item.id)")
                }
                // D22: no corridor or dwell: at b the hover is b at once.
                t.move(to: b.centroid, in: map, at: 1)
                XCTAssertEqual(t.hovered, b.item.id)
                break
            }
        }
        XCTAssertGreaterThan(checkedGutterPoints, 20, "the walk really crossed gutters")
    }

    func testGutterPointsHitTheNearestLeaf() throws {
        let a = try XCTUnwrap(map.leaves.first)
        // A point just outside a's outline, past its first edge's midpoint.
        let v0 = a.outline[0], v1 = a.outline[1]
        let mid = Pt((v0.x + v1.x) / 2, (v0.y + v1.y) / 2)
        let out = Pt(mid.x + (mid.x - a.centroid.x) * 0.03, mid.y + (mid.y - a.centroid.y) * 0.03)
        if map.leaf(at: out) == nil { XCTAssertNotNil(map.hit(at: out)) }
        XCTAssertNil(map.hit(at: Pt(-50, -50)), "far outside the map: nothing")
    }

    func testGraceExpiry() throws {
        let a = try XCTUnwrap(map.leaves.first)
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        t.exit(at: 1)
        XCTAssertFalse(t.settle(at: 1 + HoverTracker.leaveDelay / 2), "within the grace")
        XCTAssertEqual(t.hovered, a.item.id)
        t.move(to: a.centroid, in: map, at: 1.05) // came back: cancels the leave
        XCTAssertFalse(t.settle(at: 5))
        XCTAssertEqual(t.hovered, a.item.id)
        t.exit(at: 6)
        XCTAssertTrue(t.settle(at: 6 + HoverTracker.leaveDelay))
        XCTAssertNil(t.hovered); XCTAssertNil(t.strip)
        XCTAssertLessThanOrEqual(HoverTracker.leaveDelay, 0.1)
    }

    func testFarPointKeepsHoverWithinTheGrace() throws {
        let a = try XCTUnwrap(map.leaves.first)
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        // A point that hits nothing doesn't clear at once: only after the grace (D16).
        t.move(to: Pt(-40, -40), in: map, at: 0.1)
        XCTAssertEqual(t.hovered, a.item.id)
    }

    /// D22: across a serpentine sweep the hover follows the leaf under the pointer every frame.
    func testSweepFollowsThePointer() {
        let frames = HoverSweep.run(map)
        let changes = zip(frames, frames.dropFirst()).filter { $0.hovered != $1.hovered }.count
        XCTAssertGreaterThan(changes, 10)
        XCTAssertTrue(frames.allSatisfy { !$0.isMismatch && !$0.isStripMismatch })
        XCTAssertNil(frames.last?.hovered)
    }

    /// D22: a click pins the strip; hover still moves; clicking it again, empty space or Esc unpins.
    func testClickPinsButHoverStillMoves() throws {
        let a = map.leaves[0], b = try XCTUnwrap(map.leaves.first { Geo.distance($0.centroid, toOutline: a.outline) > 40 })
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        XCTAssertTrue(t.click(at: a.centroid, in: map)); XCTAssertEqual(t.pinned, a.item.id)
        XCTAssertTrue(t.move(to: b.centroid, in: map, at: 0.1))
        XCTAssertEqual(t.hovered, b.item.id, "hover still follows the pointer")
        XCTAssertEqual(t.strip, a.item.id, "the strip keeps the pinned leaf")
        XCTAssertEqual(t.appearance(of: a.item.id).ring, LeafPalette.ringPinned)
        XCTAssertEqual(t.appearance(of: b.item.id).ring, LeafPalette.ringHover)
        t.exit(at: 0.2); XCTAssertTrue(t.settle(at: 5)); XCTAssertNil(t.hovered)
        XCTAssertEqual(t.pinned, a.item.id, "a pin survives leaving the map")
        t.click(at: a.centroid, in: map); XCTAssertNil(t.pinned, "clicking the pinned leaf unpins")
        t.click(at: b.centroid, in: map); XCTAssertEqual(t.pinned, b.item.id, "clicking another leaf moves the pin")
        t.click(at: Pt(-500, -500), in: map); XCTAssertNil(t.pinned, "empty space unpins")
        t.click(at: a.centroid, in: map); t.unpin(); XCTAssertNil(t.pinned, "Esc unpins")
        XCTAssertEqual(t.hovered, a.item.id, "Esc keeps the hover")
        t.reset(); XCTAssertNil(t.hovered); XCTAssertNil(t.pinned)
    }

    func testFramesJSONWritesNull() throws {
        let frames = HoverSweep.run(map)
        let s = String(decoding: HoverSweep.json(frames), as: UTF8.self)
        XCTAssertTrue(s.contains("\"hovered\" : null"))
        XCTAssertFalse(s.contains("tooltip"), "D25: no tooltip fields")
    }
}
