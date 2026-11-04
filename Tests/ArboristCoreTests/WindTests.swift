@testable import ArboristCore
import XCTest

/// D29: the breeze spring settles, is idle at rest, the falloff and sway are bounded, and the blow-away
/// trajectory ends past the nearest edge, fully faded.
final class WindTests: XCTestCase, @unchecked Sendable {
    func testSpringSettlesAfterAGust() {
        var s = Spring2D()
        s.push(Pt(Wind.maxImpulse, -Wind.maxImpulse))
        XCTAssertFalse(s.settled)
        var steps = 0
        while !s.settled && steps < 600 { s.advance(1.0 / 60); steps += 1 }
        XCTAssertTrue(s.settled)
        XCTAssertLessThan(Double(steps) / 60, 2.0, "settles within 2 s")
        XCTAssertEqual(s.pos, Pt(0, 0)); XCTAssertEqual(s.vel, Pt(0, 0))
    }

    func testIdleAtRest() {
        var s = Spring2D()
        XCTAssertTrue(s.settled, "a fresh spring is idle: the timeline starts paused")
        for _ in 0..<100 { s.advance(1.0 / 60) }
        XCTAssertEqual(s, Spring2D(), "advancing a settled spring changes nothing")
        XCTAssertEqual(Wind.impulse(from: Pt(10, 10), to: Pt(10, 10), dt: 0.016), Pt(0, 0), "a stopped pointer adds nothing")
    }

    func testSpringBoundedForHugeInput() {
        var s = Spring2D()
        for _ in 0..<50 { s.push(Wind.impulse(from: Pt(0, 0), to: Pt(10_000, 0), dt: 0.001)); s.advance(1.0 / 60) }
        XCTAssertLessThanOrEqual(abs(s.pos.x), 1); XCTAssertLessThanOrEqual(abs(s.pos.y), 1)
    }

    func testFalloffBounded() {
        for d in stride(from: -10.0, through: 400, by: 0.5) {
            let f = Wind.falloff(d)
            XCTAssertGreaterThanOrEqual(f, 0); XCTAssertLessThanOrEqual(f, 1)
        }
        XCTAssertEqual(Wind.falloff(0), 1)
        XCTAssertEqual(Wind.falloff(Wind.radius), 0)
        XCTAssertEqual(Wind.falloff(.infinity), 0)
        XCTAssertGreaterThan(Wind.falloff(20), Wind.falloff(80), "monotone")
    }

    func testSwayBoundedAndZeroWhenFarOrNoPointer() {
        for gx in stride(from: -2.0, through: 2, by: 0.25) {
            for d in [0.0, 30, 90, 200] {
                let s = Wind.sway(leaf: Pt(d, 0), id: "leaf\(d)", pointer: Pt(0, 0), gust: Pt(gx, -gx))
                XCTAssertLessThanOrEqual(abs(s.angle), Wind.maxAngle + 1e-9)
                XCTAssertLessThanOrEqual(abs(s.dx), Wind.maxOffset + 1e-9); XCTAssertLessThanOrEqual(abs(s.dy), Wind.maxOffset + 1e-9)
            }
        }
        XCTAssertTrue(Wind.sway(leaf: Pt(500, 0), id: "x", pointer: Pt(0, 0), gust: Pt(1, 1)) == (0, 0, 0))
        XCTAssertTrue(Wind.sway(leaf: Pt(5, 0), id: "x", pointer: nil, gust: Pt(1, 1)) == (0, 0, 0))
        XCTAssertTrue(Wind.sway(leaf: Pt(5, 0), id: "x", pointer: Pt(0, 0), gust: Pt(0, 0)) == (0, 0, 0))
    }

    func testBlowAwayHeadsToNearestEdgeAndFades() {
        let size = Pt(400, 300)
        XCTAssertEqual(BlowAway.nearestEdge(Pt(20, 150), size: size), Pt(-1, 0))
        XCTAssertEqual(BlowAway.nearestEdge(Pt(390, 150), size: size), Pt(1, 0))
        XCTAssertEqual(BlowAway.nearestEdge(Pt(200, 10), size: size), Pt(0, -1))
        XCTAssertEqual(BlowAway.nearestEdge(Pt(200, 295), size: size), Pt(0, 1))
        let c = Pt(30, 150)
        let start = BlowAway.frame(c, size: size, id: "a", t: 0), end = BlowAway.frame(c, size: size, id: "a", t: 1)
        XCTAssertEqual(start.opacity, 1); XCTAssertEqual(start.dx, 0, accuracy: 1e-9)
        XCTAssertEqual(end.opacity, 0)
        XCTAssertLessThan(c.x + end.dx, 0, "ends past the left edge")
        XCTAssertGreaterThan(abs(end.angle), 90, "tumbles")
        XCTAssertLessThan(BlowAway.frame(c, size: size, id: "a", t: 0.3).dy, 0, "lifts first")
        XCTAssertTrue((0.6...0.8).contains(BlowAway.duration))
        var last = 1.0
        for i in 0...20 { let o = BlowAway.frame(c, size: size, id: "a", t: Double(i) / 20).opacity; XCTAssertLessThanOrEqual(o, last); last = o }
    }
}
