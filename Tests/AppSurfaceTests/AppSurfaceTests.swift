import ArboristCleanup
import ArboristCore // deliberately NOT @testable: this target sees only what the app sees
import XCTest

/// The macOS app isn't compiled on Linux, so this compiles the ArboristCore/ArboristCleanup calls the app makes
/// (LeafMapView, PopoverView, AppModel) against the public API only. A symbol that isn't public breaks this build
/// on Linux instead of on Joseph's Mac.
final class AppSurfaceTests: XCTestCase {
    func testAppFacingAPIIsPublic() throws {
        let result = LeafSample.busy
        let map = LeafLayout.layout(LeafLayout.groups(from: result), staleCount: result.totals.staleWorktrees)
        let leaf = try XCTUnwrap(map.leaves.first)
        let (x0, y0, x1, y1) = Geo.bbox(leaf.outline)
        XCTAssertLessThanOrEqual(x0, x1); XCTAssertLessThanOrEqual(y0, y1)
        _ = (leaf.centroid.x, leaf.inner.isEmpty, leaf.veins, leaf.item.id, leaf.item.state, leaf.labelLines.first)
        _ = (map.groupLabels, map.width, map.height, map.leaf(at: Pt(leaf.centroid.x, leaf.centroid.y)))
        let ref = try XCTUnwrap(WorktreeList.sorted(result).first)
        _ = WorktreeList.find(result, path: ref.worktree.path)
        let card = HoverCard(ref)
        _ = (card.branch, card.pill, card.status, card.repo, card.path, card.fullPath, card.size, card.rebuildableShare,
             card.rebuildable, card.changes, card.sync, card.lastCommit, card.message, card.removeCommand)
        let size = Pt(LeafSVG.cardWidth, LeafSVG.cardHeight(card) + 26)
        _ = LeafSVG.cardOrigin(avoiding: Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), size: size, in: Pt(map.width, map.height))
        var tracker = HoverTracker()
        _ = tracker.pointer(leaf.item.id, at: 0); _ = tracker.settle(at: 1)
        _ = (tracker.card, tracker.hovered, HoverTracker.leaveDelay, HoverTracker.duration(reduceMotion: true))
        _ = (LeafPalette.dimOthers, LeafPalette.hoverScale, LeafPalette.dot(ref.worktree.status), LeafPalette.pillText(ref.worktree.status),
             LeafPalette.rebuildableOpacity(leaf.item.state), LeafPalette.rebuildableShade, LeafPalette.cardFill, LeafPalette.cardStroke,
             LeafPalette.barFill, LeafPalette.barTrack, LeafPalette.groupLabel, LeafPalette.staleStroke, LeafPalette.fill(.stale),
             LeafText.leafSize, LeafText.groupSize)
        _ = (Format.middle("/a/b", max: 10), Format.cachesTotal(result.caches), Format.bytes(1), WorktreeLabel.branchName("b", head: nil))
        _ = Cleanup.plan(result).first.map { ($0.kind, $0.bytes, $0.branch, $0.repo, $0.path, $0.id) }
        _ = Cleanup.blocker(ref.worktree)?.reason
        _ = Cleanup.item(ref)
    }
}
