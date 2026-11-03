@testable import ArboristCore
import XCTest

/// D15: nearest-cell hit-testing, the grace period, the stable card anchor, the pin, and the sweep hook.
final class HoverCalmTests: XCTestCase {
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
        XCTAssertNil(t.hovered); XCTAssertNil(t.card); XCTAssertNil(t.cardOrigin)
        XCTAssertLessThanOrEqual(HoverTracker.leaveDelay, 0.1)
    }

    func testStickyInsideTheMap() throws {
        let a = try XCTUnwrap(map.leaves.first)
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        // A point that hits nothing (beyond the hit radius) doesn't clear: only leaving the map does.
        XCTAssertFalse(t.move(to: Pt(-40, -40), in: map, at: 0.1))
        XCTAssertEqual(t.hovered, a.item.id)
    }

    /// Across a full serpentine sweep the card moves to a new corner only a few times, and never between
    /// two consecutive frames twice in a row.
    func testAnchorStaysStableAcrossASweep() {
        let frames = HoverSweep.run(map, path: HoverSweep.path(in: map))
        let shown = frames.filter(\.cardShown)
        let origins = shown.map { Pt($0.cardX!, $0.cardY!) }
        let moves = zip(origins, origins.dropFirst()).filter { $0 != $1 }.count
        let hoverChanges = zip(shown, shown.dropFirst()).filter { $0.hovered != $1.hovered }.count
        XCTAssertGreaterThan(hoverChanges, 20, "the sweep crossed many leaves")
        XCTAssertLessThanOrEqual(moves, 4, "card stays anchored across the sweep")
        // The first row (top half) keeps one slot the whole way.
        XCTAssertEqual(Set(origins.prefix(14).map { "\($0.x),\($0.y)" }).count, 1)
        // No hover is lost inside the map; it clears only after leaving.
        XCTAssertTrue(frames.dropFirst().dropLast().allSatisfy { $0.hovered != nil })
        XCTAssertNil(frames.last?.hovered)
    }

    func testAnchorKeepsCurrentWhenClear() {
        let size = Pt(100, 80), bounds = Pt(448, 400)
        let first = HoverTracker.anchor(current: nil, leaf: Rect(x: 20, y: 20, w: 40, h: 40), size: size, in: bounds)
        XCTAssertEqual(first, Pt(448 - 100 - 6, 400 - 80 - 6), "corner away from the leaf")
        XCTAssertEqual(HoverTracker.anchor(current: first, leaf: Rect(x: 120, y: 30, w: 40, h: 40), size: size, in: bounds), first)
        let moved = HoverTracker.anchor(current: first, leaf: Rect(x: 330, y: 300, w: 40, h: 40), size: size, in: bounds)
        XCTAssertNotEqual(moved, first, "moves only when the leaf comes near")
    }

    /// The lift is drawing only. Two touching squares: with A lifted to 1.03×, its drawing reaches 1.5 pt
    /// into B. A point there hovers B, because hit-testing uses the unscaled layout outlines.
    func testHitTestIgnoresScale() throws {
        let s = LeafPalette.hoverScale
        var a = map.leaves[0], b = map.leaves[1]
        a.outline = [Pt(0, 0), Pt(100, 0), Pt(100, 100), Pt(0, 100)]; a.centroid = Pt(50, 50)
        b.outline = [Pt(100.5, 0), Pt(200, 0), Pt(200, 100), Pt(100.5, 100)]; b.centroid = Pt(150, 50)
        var m = map
        m.leaves = [a, b]
        let p = Pt(101.2, 50)
        let liftedEdge = 50 + 50 * s
        XCTAssertLessThan(p.x, liftedEdge, "p is under A's lifted drawing")
        var t = HoverTracker()
        t.move(to: a.centroid, in: m, at: 0)
        XCTAssertEqual(t.appearance(of: a.item.id, reduceMotion: false).scale, s)
        t.move(to: p, in: m, at: 0.02)
        XCTAssertEqual(t.hovered, b.item.id)
        // And the gutter just outside A still belongs to A (nearest edge), not to nothing.
        t.move(to: a.centroid, in: m, at: 0.03)
        t.move(to: Pt(100.2, 50), in: m, at: 0.04)
        XCTAssertEqual(t.hovered, a.item.id)
    }

    func testClickPinsAndPauseHover() throws {
        let a = map.leaves[0], b = try XCTUnwrap(map.leaves.first { Geo.distance($0.centroid, toOutline: a.outline) > 40 })
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        XCTAssertTrue(t.click(at: a.centroid, in: map)); XCTAssertTrue(t.pinned)
        XCTAssertFalse(t.move(to: b.centroid, in: map, at: 0.1)); XCTAssertEqual(t.card, a.item.id)
        t.exit(at: 0.2); XCTAssertFalse(t.settle(at: 5), "a pinned card stays")
        if let r = t.cardRect { XCTAssertFalse(t.click(at: Pt(r.x + 5, r.y + 5), in: map), "clicks on the pinned card are its own") }
        XCTAssertTrue(t.click(at: a.centroid, in: map)); XCTAssertFalse(t.pinned)
        t.move(to: b.centroid, in: map, at: 6); XCTAssertEqual(t.hovered, b.item.id)
        t.reset(); XCTAssertNil(t.hovered); XCTAssertFalse(t.pinned)
    }

    func testFramesJSONWritesNull() throws {
        let frames = HoverSweep.run(map, path: [Pt(-500, -500), nil])
        let s = String(decoding: HoverSweep.json(frames), as: UTF8.self)
        XCTAssertTrue(s.contains("\"hovered\" : null"))
        XCTAssertTrue(s.contains("\"cardShown\" : false"))
    }
}
