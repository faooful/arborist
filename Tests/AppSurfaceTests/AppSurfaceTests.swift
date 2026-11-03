import ArboristCleanup
import ArboristCore // deliberately NOT @testable: this target sees only what the app sees
import XCTest

/// The macOS app isn't compiled on Linux, so this compiles the ArboristCore/ArboristCleanup calls the app makes
/// (LeafMapView, PopoverView, AppModel) against the public API only. A symbol that isn't public breaks this build
/// on Linux instead of on Joseph's Mac.
final class AppSurfaceTests: XCTestCase, @unchecked Sendable {
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
        var tracker = HoverTracker()
        _ = tracker.pointer(leaf.item.id, at: 0); _ = tracker.settle(at: 1)
        _ = (tracker.strip, tracker.hovered, tracker.clearAt, HoverTracker.leaveDelay, HoverTracker.duration(reduceMotion: true))
        // D15/D22: HoverModel / MouseTracking / the sweep runner / the strip and tooltip.
        tracker.tooltipSize = TooltipPlacement.size
        _ = tracker.move(to: Pt(1, 1), in: map, at: 2); tracker.exit(at: 3); _ = tracker.click(at: Pt(1, 1), in: map); tracker.unpin(); tracker.reset()
        let v: HoverTracker.Visible = tracker.visible
        _ = (v.hovered, v.pinned, v.strip, v.tooltipOrigin, tracker.tooltipOrigin, tracker.tooltipRect, tracker.pinned, tracker.appearance(of: "x").ring)
        let tip = LeafTooltip(card)
        _ = (tip.branch, tip.repo, tip.size, TooltipPlacement.size.x, TooltipPlacement.place(pointer: Pt(1, 1), in: Pt(480, 600)))
        _ = (StripLayout.padding, StripLayout.row, StripLayout.buttons.indices, StripLayout.buttons[0].name, StripLayout.buttons[0].x, StripLayout.buttons[0].w)
        _ = (PopoverLayout.stripHeight, PopoverLayout.stripGap, PopoverLayout.footerHeight, PopoverLayout.stripFade, StripLayout.rows.count, StripLayout.columns, StripLayout.frames(in: Rect(x: 0, y: 0, w: 1, h: 1)), LeafPalette.ring, LeafPalette.ringHover, LeafPalette.ringPinned)
        _ = (LeafMap.hitRadius, map.hit(at: Pt(1, 1)))
        // D24
        let drawn = HoverSweep.Drawn(mapFrame: Rect(x: 0, y: 0, w: 1, h: 1), stripHeight: 0, stripFrames: nil)
        _ = (StripLayout.row("title"), HoverSweep.Step.escape,
             HoverSweep.frame(0, pointer: nil, last: Pt(0, 0), t: 0, tracker: tracker, map: map, drawn: drawn))
        let mt = MapTransform.fit(map, into: Pt(448, 400))
        _ = (MapTransform.usable(map, into: Pt(448, 400)), PopoverLayout.width, PopoverLayout.padding, PopoverLayout.mapWidth, PopoverLayout.mapHeight, PopoverLayout.minMapSide)
        _ = (mt.toView(Pt(1, 1)), mt.toMap(Pt(1, 1)), mt.scale, mt.dx, mt.dy, MapTransform.identity, map.hit(view: Pt(1, 1), mt))
        let frames = HoverSweep.run(map)
        let rep = HoverSweep.Report(frames)
        _ = (rep.summary, rep.mismatches, rep.gapFrames, rep.hoveredCount, HoverSweep.json(rep),
             HoverSweep.frame(0, pointer: nil, last: Pt(0, 0), t: 0, tracker: tracker, map: map, transform: mt, pinTruth: nil, reachTarget: false))
        _ = (LeafPalette.dimOthers, LeafPalette.dot(ref.worktree.status), LeafPalette.pillText(ref.worktree.status),
             LeafPalette.rebuildableOpacity(leaf.item.state), LeafPalette.rebuildableShade, LeafPalette.cardFill, LeafPalette.cardStroke,
             LeafPalette.barFill, LeafPalette.barTrack, LeafPalette.groupLabel, LeafPalette.staleStroke, LeafPalette.fill(.stale),
             LeafText.leafSize, LeafText.groupSize)
        _ = (Format.middle("/a/b", max: 10), Format.cachesTotal(result.caches), Format.bytes(1), WorktreeLabel.branchName("b", head: nil))
        _ = Cleanup.plan(result).first.map { ($0.kind, $0.bytes, $0.branch, $0.repo, $0.path, $0.id) }
        _ = Cleanup.blocker(ref.worktree)?.reason
        _ = Cleanup.item(ref)
        // D18: repo filter.
        let rp = result.repos[0]
        var f = RepoFilter.load(UserDefaults(suiteName: "arborist-surface")!)
        f.toggle(rp.path); f.selectAll(); f.selectNone(result.repos); f.only(rp.path, among: result.repos)
        f.save(UserDefaults(suiteName: "arborist-surface")!)
        _ = (RepoFilter.all, RepoFilter.defaultsKey, RepoFilter.searchThreshold, f.excluded, f.includes(rp), f.includes(rp.path),
             f.apply(result), f.label(result.repos), f.isEmpty(result.repos), f.isEverything(result.repos), f.selected(result.repos),
             f.pruned(to: result.repos), RepoFilter.only(names: ["x"], among: result.repos), RepoFilter.matching(result.repos, query: "a"))
        _ = Cleanup.plan(result, filter: f)
        // D21: legend state filters.
        var st = StateFilter.all; st.toggle(.clean); st.showAll(); st = .only(.ready)
        _ = (st.isAll, st.isActive(.ready), st.readyOnly, st.hidden, st.includes(ref.worktree), StateFilter.parse("ready"), StateKey.allCases.map(\.title))
        let vs = VisibleSet(repos: f, states: st)
        _ = (vs.apply(result), vs.count(.ready, in: result), vs.nothingMatches(result), VisibleSet.atLaunch(), vs.repos, vs.states)
        _ = (Cleanup.plan(result, visible: vs), CleanupSafety.isReady(ref.worktree), CleanupSafety.blocker(ref.worktree), StateKey.colour(ref.worktree))
        // D22: the popover space, the sweep steps and the action seam.
        var sp = PopoverSpace(mapOrigin: Pt(16, 52), size: Pt(480, 600), transform: mt)
        sp.mapOrigin = Pt(0, 0); sp.size = Pt(1, 1); sp.transform = .identity
        _ = (sp.toPopover(Pt(1, 1)), sp.toMap(Pt(1, 1)), sp.stripRect, sp.clips(Rect(x: 0, y: 0, w: 1, h: 1)), LeafSVG.popoverSpace(map), LeafSVG.svgSize(map))
        tracker.space = sp; _ = tracker.space
        let (steps, pin) = HoverSweep.steps(map, space: sp)
        for s in steps { switch s { case .move(let p), .click(let p): _ = (p, HoverSweep.onMap(p, map)); case .leave, .escape: break } }
        _ = (PopoverLayout.height, PopoverLayout.headerHeight, PopoverLayout.footerRowHeight, FooterLayout.names, sp.footerRect,
             StripLayout.named(in: sp.stripRect, branch: "", tag: "", repo: "", pinned: true), StripLayout.fixedPart([]),
             rep.slotFrameShifts, rep.footerHiddenFrames, rep.overlaps, LayoutCase.all(LeafSample.busy, map: map),
             HoverSweep.Drawn(mapFrame: Rect(x: 0, y: 0, w: 1, h: 1), stripHeight: 0, stripFrames: nil, slotFrame: nil, footerButtons: nil))
        _ = (pin, rep.stripMismatches, rep.tooltipClipped, rep.reachFailures, rep.buttonHits, rep.idleStripViolations, rep.mapFrameShifts, rep.stripLayoutShifts)
        _ = (PopoverAction.allCases, PopoverActionOutcome.fired(.list).log, SettingsOpening.steps(osMajor: 14),
             SettingsOpening.shouldBecomeAccessory(otherVisibleWindows: 0))
        for st in SettingsOpening.steps(osMajor: 13) {
            switch st { case .becomeRegular, .activate, .openSettingsAction, .showSettingsSelector, .orderFront, .fallbackWindow: break }
        }
    }
}

@MainActor
final class SurfaceEffects: PopoverActionEffects {
    var isScanning = false
    func openSettings(_ steps: [SettingsOpening.Step]) {}
    func terminate() {}
    func rescan() {}
    func toggleList() {}
}

final class AppActionSurfaceTests: XCTestCase, @unchecked Sendable {
    func testRouterIsPublic() {
        MainActor.assumeIsolated {
            let r = PopoverActionRouter(effects: SurfaceEffects(), dryRunQuit: true, osMajor: 14)
            _ = (r.dryRunQuit, r.osMajor, r.isEnabled(.rescan), r.perform(.list))
        }
    }
}
