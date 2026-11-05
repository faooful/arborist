import XCTest
@testable import ArboristCore

/// D34: footer icon alignment and the Refresh spin rule.
final class FooterSpinTests: XCTestCase, @unchecked Sendable {
    func testSpinsOnlyWhileScanningAndNeverWithReduceMotion() {
        XCTAssertTrue(RefreshSpin.isSpinning(scanning: true, reduceMotion: false))
        XCTAssertFalse(RefreshSpin.isSpinning(scanning: false, reduceMotion: false))
        XCTAssertFalse(RefreshSpin.isSpinning(scanning: true, reduceMotion: true))
    }
    func testAngleIsClockDrivenAndBounded() {
        let s = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(RefreshSpin.angle(at: s, start: s), 0)
        XCTAssertEqual(RefreshSpin.angle(at: s.addingTimeInterval(0.25), start: s), 90, accuracy: 0.001)
        XCTAssertEqual(RefreshSpin.angle(at: s.addingTimeInterval(1.5), start: s), 180, accuracy: 0.001)
        XCTAssertEqual(RefreshSpin.angle(at: s.addingTimeInterval(-3), start: s), 0)
    }
    func testFooterIconCentres() {
        XCTAssertTrue(FooterIconLayout.aligned([Rect(x: 0, y: 4, w: 14, h: 14), Rect(x: 30, y: 4.4, w: 14, h: 14)]))
        XCTAssertFalse(FooterIconLayout.aligned([Rect(x: 0, y: 4, w: 14, h: 14), Rect(x: 30, y: 6, w: 14, h: 14)]))
        XCTAssertFalse(FooterIconLayout.aligned([]))
    }
}
