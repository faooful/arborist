import XCTest
@testable import ArboristCore

/// D33: header Refresh button, filter alignment, and the scanning state.
final class HeaderRefreshTests: XCTestCase, @unchecked Sendable {
    func testRefreshHitAreaIsAtLeast24AndInsideTheRow() {
        let s = HeaderLayout.frames(count: "36 worktrees", sub: "· 36 stale", filter: "All 40 repos").first { $0.name == "status" }!.rect
        XCTAssertGreaterThanOrEqual(s.w, 24); XCTAssertGreaterThanOrEqual(s.h, 24)
        XCTAssertGreaterThanOrEqual(s.y, 0); XCTAssertLessThanOrEqual(s.y + s.h, HeaderLayout.height)
        XCTAssertEqual(s.x + s.w, HeaderLayout.width)
    }
    func testFilterSharesTheStaleTextBox() {
        let f = HeaderLayout.frames(count: "36 worktrees", sub: "· 36 stale", filter: "All 40 repos")
        let sub = f[1].rect, filter = f[2].rect
        XCTAssertEqual(sub.y, filter.y); XCTAssertEqual(sub.h, filter.h)
        XCTAssertLessThanOrEqual(HeaderLayout.filterButton(f).x + HeaderLayout.filterButton(f).w, HeaderLayout.contentRight)
    }
    func testNoTruncationWithScanningAtWorstCase() {
        XCTAssertEqual(HeaderLayout.truncations(HeaderLayout.worstCase()), 0)
        XCTAssertTrue(HeaderLayout.worstCase().contains { $0.label.hasSuffix("…") })
    }
    func testScanningSub() {
        let r = LeafSample.busy
        let f = "All \(r.repos.count) repos"
        XCTAssertEqual(HeaderLayout.sub(r, scanning: false, filter: f), HeaderLayout.sub(r))
        let s = HeaderLayout.sub(r, scanning: true, filter: f)
        XCTAssertTrue(s.hasSuffix("· scanning…"), s)
        XCTAssertEqual(HeaderLayout.truncations(HeaderLayout.measures(count: HeaderLayout.count(r), sub: s, filter: f)), 0)
        // The screenshot's case still fits in full; a worst case falls back to "…".
        XCTAssertEqual(HeaderLayout.truncations(HeaderLayout.measures(count: "36 worktrees", sub: "· 36 stale · scanning…", filter: "All 40 repos")), 0)
    }
    func testRefreshClick() {
        XCTAssertEqual(HeaderLayout.refreshClick(scanning: false, queued: false), .rescan)
        XCTAssertEqual(HeaderLayout.refreshClick(scanning: true, queued: false), .queue)
        XCTAssertEqual(HeaderLayout.refreshClick(scanning: true, queued: true), .alreadyQueued)
        XCTAssertTrue(HeaderLayout.refreshHelp(status: "34/40 repos", scanning: true, queued: false).contains("34/40"))
    }
}
