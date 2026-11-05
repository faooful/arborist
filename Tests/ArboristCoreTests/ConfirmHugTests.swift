import XCTest
@testable import ArboristCore

/// D30: the confirm hugs short lists and caps (then scrolls) long ones.
final class ConfirmHugTests: XCTestCase, @unchecked Sendable {
    func testSingleRowHugs() {
        let h = ConfirmLayout.estimatedListHeight(rows: 1)
        XCTAssertEqual(ConfirmLayout.listHeight(content: h), h)
        XCTAssertFalse(ConfirmLayout.scrolls(content: h))
        XCTAssertLessThan(ConfirmLayout.heightBound(rows: 1), ConfirmLayout.chromeHeight + ConfirmLayout.listMaxHeight / 2)
    }
    func testLongListCapsAndScrolls() {
        let h = ConfirmLayout.estimatedListHeight(rows: 12)
        XCTAssertEqual(ConfirmLayout.listHeight(content: h), ConfirmLayout.listMaxHeight)
        XCTAssertTrue(ConfirmLayout.scrolls(content: h))
        XCTAssertEqual(ConfirmLayout.heightBound(rows: 12), ConfirmLayout.heightBound(rows: 40))
    }
    func testHeightGrowsWithRowsUntilCap() {
        let b = (1...12).map { ConfirmLayout.heightBound(rows: $0) }
        XCTAssertEqual(b, b.sorted())
        XCTAssertEqual(ConfirmLayout.listHeight(content: 0), 0)
    }
}
