@testable import ArboristCore
import XCTest

/// D15: drawing and hit-testing share one MapTransform, so every leaf is hit where it is drawn.
final class MapTransformTests: XCTestCase {
    let map: LeafMap = {
        let r = LeafSample.busy
        return LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }()

    /// View sizes the map can get, plus the popover itself: 480 wide, 16 pt padding, map below a 52 pt header.
    var cases: [(view: Pt, origin: Pt)] {
        [(Pt(448, 400), Pt(0, 0)), (Pt(448, 300), Pt(0, 0)), (Pt(300, 300), Pt(0, 0)),
         (Pt(640, 360), Pt(0, 0)), (Pt(220, 500), Pt(0, 0)),
         (Pt(448, 448 * map.height / map.width), Pt(16, 52))]
    }

    /// A point inside the leaf: its centroid, or the first inside point on a grid over its bounding box.
    func interior(_ l: Leaf) -> Pt? {
        if Geo.inside(l.outline, l.centroid) { return l.centroid }
        let (x0, y0, x1, y1) = Geo.bbox(l.outline)
        for i in 1..<20 { for j in 1..<20 {
            let p = Pt(x0 + (x1 - x0) * Double(i) / 20, y0 + (y1 - y0) * Double(j) / 20)
            if Geo.inside(l.outline, p) { return p }
        } }
        return nil
    }

    func testEveryLeafHitsItselfUnderTheRealViewTransform() throws {
        for (view, origin) in cases {
            let t = MapTransform.fit(map, into: view, origin: origin)
            for leaf in map.leaves {
                let q = try XCTUnwrap(interior(leaf), "\(leaf.item.id) has an interior")
                let onScreen = t.toView(q) // where the drawing puts this point
                XCTAssertEqual(map.hit(view: onScreen, t)?.item.id, leaf.item.id, "\(leaf.item.id) in \(view)+\(origin)")
                // And through the tracker, the path real pointer events take.
                var h = HoverTracker()
                h.move(to: t.toMap(onScreen), in: map, at: 0)
                XCTAssertEqual(h.hovered, leaf.item.id)
            }
        }
    }

    func testRoundTrip() {
        for (view, origin) in cases {
            let t = MapTransform.fit(map, into: view, origin: origin)
            for p in [Pt(0, 0), Pt(map.width, map.height), Pt(123.4, 56.7), Pt(-10, 900)] {
                let back = t.toMap(t.toView(p))
                XCTAssertEqual(back.x, p.x, accuracy: 1e-9); XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
                let v = t.toView(t.toMap(p))
                XCTAssertEqual(v.x, p.x, accuracy: 1e-9); XCTAssertEqual(v.y, p.y, accuracy: 1e-9)
            }
        }
    }

    func testAspectFitLetterboxesAndCentres() {
        let t = MapTransform.fit(Pt(448, 400), into: Pt(896, 400))
        XCTAssertEqual(t.scale, 1); XCTAssertEqual(t.dx, 224); XCTAssertEqual(t.dy, 0)
        let u = MapTransform.fit(Pt(448, 400), into: Pt(224, 400), origin: Pt(16, 52))
        XCTAssertEqual(u.scale, 0.5); XCTAssertEqual(u.dx, 16); XCTAssertEqual(u.dy, 52 + 100)
        XCTAssertEqual(MapTransform.fit(map, into: Pt(map.width, map.height)), .identity)
        // y is not flipped: the top of the layout is the top of the view.
        XCTAssertLessThan(u.toView(Pt(0, 0)).y, u.toView(Pt(0, 400)).y)
    }
}

/// D17: fixed popover geometry, and no transform from a collapsed frame.
final class PopoverLayoutTests: XCTestCase {
    func testLayoutConstantsGiveA448x400Map() {
        XCTAssertEqual(PopoverLayout.mapWidth, 448)
        XCTAssertEqual(PopoverLayout.mapHeight, 400)
        XCTAssertEqual(PopoverLayout.width, PopoverLayout.mapWidth + 2 * PopoverLayout.padding)
        for r in [LeafSample.busy, LeafSample.scan] {
            let m = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
            XCTAssertEqual(m.width, 448); XCTAssertEqual(m.height, 400)
            XCTAssertEqual(MapTransform.usable(m, into: Pt(PopoverLayout.mapWidth, PopoverLayout.mapHeight)), .identity)
            // Every leaf is inside the frame, so clipping hides nothing.
            for l in m.leaves { for p in l.outline { XCTAssertTrue(p.x >= 0 && p.y >= 0 && p.x <= 448 && p.y <= 400) } }
        }
    }

    func testTransformRejectsZeroAndTinyFrames() {
        let r = LeafSample.busy
        let m = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        for v in [Pt(0, 0), Pt(448, 0), Pt(0, 400), Pt(448, 10), Pt(10, 10), Pt(-5, 400), Pt(.infinity, 400), Pt(.nan, 400)] {
            XCTAssertNil(MapTransform.usable(m, into: v), "\(v)")
        }
        XCTAssertNotNil(MapTransform.usable(m, into: Pt(PopoverLayout.minMapSide, PopoverLayout.minMapSide)))
    }
}
