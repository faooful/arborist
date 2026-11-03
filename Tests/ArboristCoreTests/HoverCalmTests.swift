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
                // D20: the switch lands once the corridor's grace and the dwell have passed.
                rest(&t, at: b.centroid, in: map, from: 1)
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

    func testFarPointKeepsHoverWithinTheGrace() throws {
        let a = try XCTUnwrap(map.leaves.first)
        var t = HoverTracker()
        t.move(to: a.centroid, in: map, at: 0)
        // A point that hits nothing doesn't clear at once: only after the grace (D16).
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
        XCTAssertGreaterThan(hoverChanges, 10, "the sweep crossed many leaves (D20 holds the card in the corridor)")
        XCTAssertLessThanOrEqual(moves, 4, "card stays anchored across the sweep")
        // The first row (top half) keeps one slot the whole way.
        XCTAssertEqual(Set(origins.prefix(14).map { "\($0.x),\($0.y)" }).count, 1)
        // D16: hover matches the ground truth everywhere (cleared in far gaps after the grace).
        XCTAssertTrue(frames.allSatisfy { !$0.isMismatch })
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
        rest(&t, at: p, in: m, from: 0.02)
        XCTAssertEqual(t.hovered, b.item.id)
        // And the gutter just outside A still belongs to A (nearest edge), not to nothing.
        rest(&t, at: a.centroid, in: m, from: 1)
        rest(&t, at: Pt(100.2, 50), in: m, from: 2)
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
        rest(&t, at: b.centroid, in: map, from: 6); XCTAssertEqual(t.hovered, b.item.id)
        t.reset(); XCTAssertNil(t.hovered); XCTAssertFalse(t.pinned)
    }

    func testFramesJSONWritesNull() throws {
        let frames = HoverSweep.run(map, path: [Pt(-500, -500), nil])
        let s = String(decoding: HoverSweep.json(frames), as: UTF8.self)
        XCTAssertTrue(s.contains("\"hovered\" : null"))
        XCTAssertTrue(s.contains("\"cardShown\" : false"))
    }

    /// D20: rest the pointer at `p` long enough for the corridor's grace and the switch dwell to pass.
    private func rest(_ t: inout HoverTracker, at p: Pt, in m: LeafMap, from t0: Double) {
        t.move(to: p, in: m, at: t0)
        t.move(to: p, in: m, at: t0 + HoverTracker.cardGrace + 0.01)
        t.settle(at: t0 + HoverTracker.cardGrace + HoverTracker.switchDwell + 0.02)
    }
}
