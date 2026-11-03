@testable import ArboristCore
import XCTest

/// D26: the header fits at 480 with no truncation, and the repo menu is readable (contrast).
final class HeaderMenuTests: XCTestCase, @unchecked Sendable {
    func testWorstCaseHeaderFits() {
        XCTAssertEqual(HeaderLayout.truncations(HeaderLayout.worstCase()), 0)
        let r = LeafSample.busy
        let m = HeaderLayout.measures(count: HeaderLayout.count(r), sub: HeaderLayout.sub(r), filter: "All \(r.repos.count) repos")
        XCTAssertEqual(HeaderLayout.truncations(m), 0)
    }

    func testOldStyleHeaderWouldTruncate() {
        // The pre-D26 headline plus status in one line does not fit the header frames.
        let old = "9999 worktrees in 999 repos · 999 stale  Cached · 999/999 repos"
        let m = [LegendMeasure(label: old, natural: HeaderLayout.w(old, HeaderLayout.countSize), frame: Rect(x: 0, y: 0, w: 300, h: 26))]
        XCTAssertGreaterThan(HeaderLayout.truncations(m), 0)
    }

    func testFilterLabels() {
        XCTAssertEqual(HeaderLayout.filterLabel(selected: ["a", "b"], total: 2), "All 2 repos")
        XCTAssertEqual(HeaderLayout.filterLabel(selected: [], total: 3), "No repos")
        XCTAssertEqual(HeaderLayout.filterLabel(selected: ["api"], total: 3), "api")
        XCTAssertEqual(HeaderLayout.filterLabel(selected: [String(repeating: "W", count: 60)], total: 3), "1 of 3 repos")
        XCTAssertEqual(HeaderLayout.filterLabel(selected: ["a", "b"], total: 3), "2 of 3 repos")
    }

    func testStatusMovedOutOfHeader() {
        XCTAssertEqual(HeaderLayout.status(progress: nil, cached: false), "")
        XCTAssertTrue(HeaderLayout.status(progress: "34/35 repos", cached: true).contains("34/35"))
    }

    func testMenuContrast() {
        XCTAssertEqual(RepoMenuStyle.checks().filter(\.fails).count, 0)
        // inkSoft, the old count colour, fails 4.5:1 on the card.
        XCTAssertGreaterThan(RepoMenuStyle.checks(count: LeafPalette.inkSoft).filter(\.fails).count, 0)
        // A translucent dark popover background fails with the light palette's names.
        XCTAssertGreaterThan(RepoMenuStyle.checks(background: "#3a3a3a").filter(\.fails).count, 0)
    }

    func testRepoMenuDrawnInSVG() {
        let r = LeafSample.busy
        let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        let rows = RepoMenuRow.rows(r.repos, filter: RepoFilter())
        let svg = LeafSVG.popover(r, map: map, filterLabel: "All \(r.repos.count) repos", menu: rows)
        XCTAssertTrue(svg.contains(RepoMenuStyle.background))
        XCTAssertTrue(svg.contains(try XCTUnwrap(r.repos.first).name))
        XCTAssertFalse(LeafSVG.popover(r, map: map).contains("⌥-click"))
    }
}
