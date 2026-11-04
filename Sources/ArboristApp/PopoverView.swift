#if os(macOS)
import AppKit
import ArboristCleanup
import ArboristCore
import SwiftUI

/// D24/D25: the one shared slot below the map, a fixed 448 × stripHeight. At rest it shows `content` (the
/// RestPanel: legend, storage bar, summary grid); on hover or selection the leaf details crossfade in (0.2 s,
/// none with Reduce Motion) in the same rect. Leaf → leaf only the values swap (PanelTransition). Never
/// empty, never resized. Its own view so pointer moves don't re-render the whole popover.
struct SharedSlot<Content: View>: View {
    @EnvironmentObject var hover: HoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let result: ScanResult?
    @ViewBuilder var content: Content

    var body: some View {
        let shown = result != nil && hover.visible.strip.flatMap { id in result.flatMap { WorktreeList.find($0, path: id) } } != nil
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) { content }
                .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
                .opacity(shown ? 0 : 1)
                .allowsHitTesting(!shown)
                .accessibilityHidden(shown)
            if let r = result { DetailStrip(result: r) }
        }
        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
        .animation(hover.panelTransition == .crossfade && !hover.instant ? .easeInOut(duration: PopoverLayout.stripFade) : nil, value: shown)
        .reportFrame(SlotFrameKey.self)
        .onPreferenceChange(SlotFrameKey.self) { hover.drawnSlotFrame = $0.first }
        .onPreferenceChange(RestFramesKey.self) { hover.drawnRestFrames = $0.isEmpty ? nil : $0 }
        .onPreferenceChange(LegendKey.self) { hover.drawnLegend = $0.isEmpty ? nil : $0 }
    }
}

/// D24: the slot's and the footer buttons' frames as drawn (popover coordinates), for the sweep.
struct SlotFrameKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
}
/// D25: the resting panel's content frames and legend measures as drawn, for the sweep.
struct RestFramesKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
}
struct LegendKey: PreferenceKey {
    static let defaultValue: [LegendMeasure] = []
    static func reduce(value: inout [LegendMeasure], nextValue: () -> [LegendMeasure]) { value += nextValue() }
}
struct NaturalWidthKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

extension View {
    /// D25: a fixed RestLayout frame (slot-relative), reported to the sweep as drawn.
    func restFrame(_ r: Rect, alignment: Alignment = .topLeading) -> some View {
        frame(width: r.w, height: r.h, alignment: alignment)
            .reportFrame(RestFramesKey.self)
            .padding(EdgeInsets(top: r.y, leading: r.x, bottom: 0, trailing: 0))
    }
}

struct FooterFramesKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
}

extension View {
    /// Reports this view's frame in the popover's coordinate space under `key`.
    func reportFrame<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == [Rect] {
        background(GeometryReader { g in
            let f = g.frame(in: .named(PopoverCoords.name))
            Color.clear.preference(key: key, value: [Rect(x: f.minX, y: f.minY, w: f.width, h: f.height)])
        })
    }
}

/// The whole app: a 480pt popover under the menu bar item. Worktree-first leaves (D9, D12).
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// D28: drawn natural widths of the count and stale texts (closes the gap before "· N stale").
    @State private var headerNaturals: [Double?] = [nil, nil]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // D26: the header from HeaderLayout's fixed frames: count, stale, repo filter, status icon. Each
            // text at its natural width (nothing truncates); the scan status text lives in the footer.
            let hf = headerFrames
            ZStack(alignment: .topLeading) {
                HeaderText(text: hf.count, size: HeaderLayout.countSize, color: Theme.ink, frame: hf.frames[0].rect, alignment: .bottomLeading,
                           onNatural: { n in if headerNaturals[0] != n { headerNaturals[0] = n } })
                if !hf.sub.isEmpty {
                    HeaderText(text: hf.sub, size: HeaderLayout.subSize, color: Theme.ink2, frame: hf.frames[1].rect, alignment: .bottomLeading,
                               onNatural: { n in if headerNaturals[1] != n { headerNaturals[1] = n } })
                }
                if let all = model.scanned?.repos, !all.isEmpty {
                    RepoFilterButton(repos: all, label: hf.filter, textFrame: hf.frames[2].rect)
                        .frame(width: HeaderLayout.filterButton(hf.frames).w, height: 18, alignment: .leading)
                        .padding(EdgeInsets(top: hf.frames[2].rect.y, leading: hf.frames[2].rect.x, bottom: 0, trailing: 0))
                }
                Image(systemName: model.scanning ? "arrow.triangle.2.circlepath" : (model.resultIsCached ? "clock" : "checkmark.circle"))
                    .font(.system(size: 12)).foregroundColor(Theme.ink2)
                    .frame(width: HeaderLayout.statusSide, height: HeaderLayout.statusSide)
                    .help(statusText.isEmpty ? "Up to date" : statusText)
                    .accessibilityLabel(statusText.isEmpty ? "Up to date" : statusText)
                    .padding(EdgeInsets(top: hf.frames[3].rect.y, leading: hf.frames[3].rect.x, bottom: 0, trailing: 0))
            }
            .frame(width: PopoverLayout.mapWidth, alignment: .topLeading)
            .onPreferenceChange(HeaderMeasureKey.self) { model.hover.drawnHeader = $0.isEmpty ? nil : $0 }
            .frame(height: PopoverLayout.headerHeight)
            // D24: the scan error sits over the map's top edge, so the popover's height never changes.
            Group {
                if model.filterHidesEverything {
                    Text("No repos selected")
                        .font(.system(size: 12)).foregroundColor(Theme.ink2)
                        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight) // same box (D17, D18)
                        .transition(.opacity)
                } else if model.nothingMatches {
                    VStack(spacing: 8) {
                        Text("Nothing matches").font(.system(size: 12)).foregroundColor(Theme.ink2)
                        Button("Show all") { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.setStates(.all) } }
                            .buttonStyle(HoverButtonStyle(kind: .link))
                    }
                    .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight) // same box (D17, D21)
                    .transition(.opacity)
                } else if let map = model.leafMap, let r = model.result {
                    LeafMapView(map: map, result: r)
                        .id(model.visible)          // a filter change cross-fades the re-laid-out map (D18)
                        .transition(.opacity)
                } else {
                    Text(model.scanning ? "Looking for repositories and worktrees…" : (model.scanError == nil ? "No scan yet" : "No results"))
                        .font(.system(size: 11)).foregroundColor(Theme.ink2)
                        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight) // same layout in every state (D17)
                }
            }
            .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight)
            .overlay(alignment: .top) {
                if let err = model.scanError {
                    HStack(spacing: 8) {
                        Text(err + (model.result != nil ? " Showing the last results." : ""))
                            .font(.system(size: 11)).foregroundColor(Theme.ink)
                        Spacer()
                        Button("Retry") { model.router.perform(.rescan) }.buttonStyle(HoverButtonStyle(kind: .link))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: LeafPalette.fill(.stale)).opacity(0.35)))
                }
            }
            // D24: one shared slot (legend + storage bar at rest, leaf details on hover or pin), then the
            // footer buttons in their own row, so a pin never hides them. Fixed heights: the map never moves.
            SharedSlot(result: model.leafMap != nil && !model.filterHidesEverything && !model.nothingMatches ? model.result : nil) {
                RestPanel()
            }
            HStack(spacing: 8) {
                let n = model.clearPlan.count
                Button(model.cleaning ? "Clearing…" : "Clear \(n)") { model.requestClear() }
                    .buttonStyle(HoverButtonStyle(kind: .dark))
                    .disabled(n == 0 || model.cleaning)
                    .help("Removes \(n) merged or upstream-gone worktrees with nothing uncommitted or unpushed. Asks first; branches are kept.")
                    .reportFrame(FooterFramesKey.self)
                // D22: Rescan, List, Settings and Quit go through the action router.
                Button(model.scanning ? "Scanning…" : "Rescan") { model.router.perform(.rescan) }
                    .buttonStyle(HoverButtonStyle(kind: .link))
                    .disabled(!model.router.isEnabled(.rescan))
                    .help("Scan every folder again, ignoring the cache")
                    .reportFrame(FooterFramesKey.self)
                Button(model.showList ? "Hide list" : "List") { model.router.perform(.list) }
                    .buttonStyle(HoverButtonStyle(kind: .link))
                    .reportFrame(FooterFramesKey.self)
                // D26: the scan status text, moved here from the header (where it truncated).
                Text(statusText).font(.system(size: 10.5)).foregroundColor(Theme.ink2).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4)
                Button { model.router.perform(.settings) } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(HoverButtonStyle(kind: .icon))
                    .help("Settings")
                    .accessibilityLabel("Settings")
                    .reportFrame(FooterFramesKey.self)
                Button { model.router.perform(.quit) } label: { Image(systemName: "power").font(.system(size: 13)) }
                    .buttonStyle(HoverButtonStyle(kind: .icon))
                    .help("Quit Arborist")
                    .accessibilityLabel("Quit Arborist")
                    .reportFrame(FooterFramesKey.self)
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.ink2)
            .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.footerRowHeight)
            .onPreferenceChange(FooterFramesKey.self) { model.hover.drawnFooterButtons = $0.isEmpty ? nil : $0 }
            if model.showList, let r = model.result { Checklist(result: r).frame(maxHeight: 260) }
            if let results = model.cleanupResults { CleanupResultsView(results: results) }
        }
        .padding(PopoverLayout.padding)
        .frame(width: PopoverLayout.width)
        .fixedSize(horizontal: false, vertical: true) // height = the content's ideal height, never squeezed
        .background(Theme.paper)
        .coordinateSpace(name: PopoverCoords.name)
        // D27: while a confirm is open nothing beneath it (map, panel, footer) takes the pointer.
        .allowsHitTesting(model.pendingCleanup == nil)
        // D26: the repo menu as an opaque in-popover panel over the map; a click outside or Esc closes it.
        .overlay(alignment: .topLeading) {
            if model.repoMenuOpen, let all = model.scanned?.repos, !all.isEmpty {
                let o = RepoMenuLayout.origin(filterButton: HeaderLayout.filterButton(headerFrames.frames))
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { model.repoMenuOpen = false }
                    RepoMenuPanel(repos: all)
                        .padding(EdgeInsets(top: PopoverLayout.padding + o.y, leading: PopoverLayout.padding + o.x, bottom: 0, trailing: 0))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // D26: always the app's light palette, whatever the system appearance (popover, menu, sheet).
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        // Esc closes the repo menu, else clears the selection (D22, D25). A hidden cancel button, since the map itself rarely has key focus in the popover.
        .background {
            Button("") { if model.pendingCleanup != nil { return }; if model.repoMenuOpen { model.repoMenuOpen = false } else { model.hover.unpin() } }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
                .disabled(model.pendingCleanup != nil) // D27: the confirm owns Esc while open
                .accessibilityHidden(true)
        }
        .background {
            if #available(macOS 14.0, *) { SettingsActionBridge() }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { model.hover.popoverSize = Pt(g.size.width, g.size.height) }
                .onChange(of: g.size) { s in model.hover.popoverSize = Pt(s.width, s.height) }
        })
        // D27: the confirm is an in-popover overlay on top of everything (a .sheet on the menu bar popover
        // window didn't take clicks). A dim layer swallows clicks outside it; Esc cancels, Return removes.
        .overlay {
            if let items = model.pendingCleanup {
                ZStack {
                    Color.black.opacity(0.18).contentShape(Rectangle()).onTapGesture {}
                        .accessibilityHidden(true)
                    CleanupConfirmSheet(items: items)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper).shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: LeafPalette.cardStroke), lineWidth: 0.8))
                        .padding(.horizontal, PopoverLayout.padding)
                }
                .environment(\.colorScheme, .light)
                .zIndex(ConfirmLayout.zIndex)
                .onPreferenceChange(ConfirmButtonsKey.self) { f in
                    model.hover.drawnConfirmButtons = f.isEmpty ? nil : f.map { ($0.name, $0.rect) }
                }
            }
        }
    }

    /// D26: "34/35 repos" while scanning, "Cached · 34/35 repos" for a cached scan being refreshed, "Cached", or empty.
    /// D26: the header's texts and fixed frames.
    private var headerFrames: (count: String, sub: String, filter: String, frames: [(name: String, text: String, rect: Rect)]) {
        let c = model.result.map(HeaderLayout.count) ?? "— worktrees", sub = model.result.map(HeaderLayout.sub) ?? ""
        let all = model.scanned?.repos ?? []
        let f = all.isEmpty ? "" : HeaderLayout.filterLabel(model.filter, repos: all)
        return (c, sub, f, HeaderLayout.tightened(HeaderLayout.frames(count: c, sub: sub, filter: f), naturals: headerNaturals))
    }

    private var statusText: String { HeaderLayout.status(progress: model.progressLabel, cached: model.resultIsCached) }

}

/// One legend line, three dots (D13).
/// The legend, as state filters (D21): click toggles a state, ⌥-click shows only it, inactive items are dimmed.
/// "Ready to clean (N)" is exactly Clear N's set (CleanupSafety). "Show all" appears when any are off.
/// D25: the resting panel, never blank: legend, storage bar and labels, and a 2 × 4 summary grid of real
/// values (shown scan), every piece in its RestLayout frame (the CLI's SVG draws the same frames).
struct RestPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let free = model.freeBytes ?? 0, total = model.result?.volume?.totalBytes ?? 0
        let cells = model.result.map(RestSummary.cells) ?? []
        ZStack(alignment: .topLeading) {
            Key()
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Color(hex: LeafPalette.barFill))
                        .frame(width: total > 0 ? g.size.width * (1 - Double(free) / Double(total)) : 0)
                }
            }
            .restFrame(RestLayout.row("bar"))
            HStack {
                Text(Format.bytes(free)).fontWeight(.medium).foregroundColor(Theme.ink) + Text(" free").foregroundColor(Theme.ink2)
                Spacer()
                Text("of \(Format.bytes(total))").foregroundColor(Theme.ink2)
            }
            .font(.system(size: 11)).lineLimit(1)
            .restFrame(RestLayout.row("storage"))
            ForEach(Array(zip(RestLayout.cells, cells).enumerated()), id: \.offset) { _, pair in
                VStack(alignment: .leading, spacing: 1) {
                    Text(pair.1.label).font(.system(size: 10)).foregroundColor(Theme.ink2).lineLimit(1)
                    Text(pair.1.value).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundColor(Theme.ink).lineLimit(1)
                }
                .restFrame(pair.0)
            }
        }
        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
    }
}

/// The legend (D21, D25): state filters on one row, each item in its RestLayout frame. Caches moved to the
/// summary grid so the row fits; each label's natural width is reported against its frame (sweep).
struct Key: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = model.states
        let items = RestLayout.legend(RestLayout.legendLabels(ready: readyCount, showAll: !s.isAll))
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let k: StateKey? = i < StateKey.allCases.count ? StateKey.allCases[i] : nil
                Button { if let k { tap(k) } else { set(.all) } } label: {
                    HStack(spacing: 4) {
                        if let k { dot(k) } else { Color.clear.frame(width: 8, height: 8) }
                        LegendLabel(text: item.label, bold: k.map { s.isActive($0) && !s.isAll } ?? false,
                                    frame: item.text)
                    }
                    .padding(.horizontal, 4)
                    .frame(width: item.item.w, height: item.item.h, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(k.map { s.isActive($0) && !s.isAll } ?? false ? Theme.line : Color.clear))
                    .opacity(k.map { s.isAll || s.isActive($0) } ?? true ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(kind: .link, height: nil))
                .help(k.map { $0 == .ready ? "Exactly what Clear would remove. ⌥-click: only this." : "\($0.title). Click to toggle, ⌥-click: only this." } ?? "Show every state")
                .accessibilityLabel(k.map { "\($0.title)\($0 == .ready ? ", \(readyCount)" : ""), \(s.isActive($0) ? "shown" : "hidden")" } ?? "Show all")
                .restFrame(item.item)
            }
        }
        .font(.system(size: 11)).foregroundColor(Theme.ink2)
        .lineLimit(1)
    }

    private var readyCount: Int { model.scanned.map { model.visible.count(.ready, in: $0) } ?? 0 }

    private func short(_ k: StateKey) -> String {
        switch k { case .uncommitted: "Uncommitted"; case .clean: "Clean"; case .stale: "Stale"; case .ready: "Ready to clean" }
    }

    @ViewBuilder private func dot(_ k: StateKey) -> some View {
        switch k {
        case .uncommitted: Circle().fill(Color(hex: LeafPalette.fill(.protected))).frame(width: 8, height: 8)
        case .clean: Circle().fill(Color(hex: LeafPalette.fill(.clean))).frame(width: 8, height: 8)
        case .stale: Circle().fill(Color(hex: LeafPalette.fill(.stale))).frame(width: 8, height: 8)
        case .ready: Circle().stroke(Color(hex: LeafPalette.staleStroke), lineWidth: 1.5).frame(width: 8, height: 8)
        }
    }

    private func tap(_ k: StateKey) {
        var s = model.states
        if NSEvent.modifierFlags.contains(.option) { s = .only(k) } else { s.toggle(k) }
        set(s)
    }

    private func set(_ s: StateFilter) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.setStates(s) }
    }
}

/// D25: one legend label in its text frame; reports its natural (untruncated) width against the frame.
struct LegendLabel: View {
    let text: String, bold: Bool, frame: Rect
    @State private var natural = 0.0
    var body: some View {
        Text(text).fontWeight(bold ? .semibold : .regular).lineLimit(1)
            .frame(width: frame.w, alignment: .leading)
            .background(Text(text).fontWeight(bold ? .semibold : .regular).fixedSize().hidden()
                .background(GeometryReader { g in Color.clear.preference(key: NaturalWidthKey.self, value: g.size.width) }))
            .onPreferenceChange(NaturalWidthKey.self) { natural = $0 }
            .background(GeometryReader { g in
                let f = g.frame(in: .named(PopoverCoords.name))
                Color.clear.preference(key: LegendKey.self,
                                       value: [LegendMeasure(label: text, natural: natural, frame: Rect(x: f.minX, y: f.minY, w: f.width, h: f.height))])
            })
    }
}

/// Every worktree, sorted by state (uncommitted, unpushed, merged, stale, clean) then newest first.
/// Hovering a row highlights its leaf, and hovering a leaf highlights its row.
struct Checklist: View {
    @EnvironmentObject var model: AppModel
    let result: ScanResult
    @EnvironmentObject var hover: HoverModel

    var body: some View {
        let hovered = hover.hovered
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(WorktreeList.sorted(result), id: \.worktree.path) { ref in
                        WorktreeRow(ref: ref, highlighted: hovered == ref.worktree.path)
                            .id(ref.worktree.path)
                            .onHover { inside in
                                if inside { hover.row(ref.worktree.path) } else if hover.hovered == ref.worktree.path { hover.row(nil) }
                            }
                    }
                }
            }
            .onChange(of: hovered) { h in if let h { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(h) } } }
        }
    }
}

struct WorktreeRow: View {
    @EnvironmentObject var model: AppModel
    let ref: WorktreeRef
    let highlighted: Bool
    private var w: Worktree { ref.worktree }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: LeafPalette.dot(w.status))).frame(width: 7, height: 7)
            Text(WorktreeLabel.branchName(w.branch, head: w.head)).font(.system(size: 11.5, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
            Text(ref.repo + (w.isMain ? " · main" : "")).font(.system(size: 10.5)).foregroundColor(Theme.ink3).lineLimit(1)
            Text(w.status.word).font(.system(size: 10.5)).foregroundColor(Theme.ink2)
            Spacer()
            if let d = w.lastCommitDate { Text(Format.age(d)).font(.system(size: 10.5)).foregroundColor(Theme.ink3) }
            Text(Format.bytes(w.size.total)).font(.system(size: 11)).monospacedDigit().foregroundColor(Theme.ink2)
            Button("Reveal") { model.reveal(w.path) }.buttonStyle(.link).foregroundColor(Theme.ink2)
            RemoveButton(ref: ref, title: "Remove").buttonStyle(.link)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Theme.line.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .help(w.path)
        .contextMenu {
            Button("Reveal in Finder") { model.reveal(w.path) }
            if let cmd = w.removeCommand { Button("Copy remove command") { model.copy(cmd) } }
            Divider()
            RemoveButton(ref: ref, title: "Remove worktree…")
        }
    }
}

/// "Remove worktree": enabled only when `Cleanup.blocker` is nil; otherwise disabled with the reason (D14).
struct RemoveButton: View {
    @EnvironmentObject var model: AppModel
    let ref: WorktreeRef
    var title = "Remove worktree"
    /// The strip has a fixed-width button (D22): the reason goes in the tooltip only.
    var showReason = true

    var body: some View {
        let blocker = Cleanup.blocker(ref.worktree)
        Button(showReason ? (blocker.map { "\(title) — \($0.reason)" } ?? title) : title) { model.requestRemove(ref) }
            .disabled(blocker != nil || model.cleaning || model.cleanupDisabled)
            .help(blocker?.reason ?? "Runs `git worktree remove` (no --force) after you confirm. The branch is kept.")
    }
}

/// Identifiable wrapper so the confirm sheet can be driven by `pendingCleanup`.
struct CleanupBatch: Identifiable {
    let items: [CleanupItem]
    var id: String { items.map(\.id).joined(separator: "|") }
}

/// D27: a confirm button's drawn frame (popover/window coordinates), for `--confirm-check`.
struct ConfirmButtonFrame: View {
    let name: String
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            Color.clear.preference(key: ConfirmButtonsKey.self, value: [NamedRect(name: name, rect: Rect(x: f.minX, y: f.minY, w: f.width, h: f.height))])
        }
    }
}
struct NamedRect: Equatable { let name: String; let rect: Rect }
struct ConfirmButtonsKey: PreferenceKey {
    static let defaultValue: [NamedRect] = []
    static func reduce(value: inout [NamedRect], nextValue: () -> [NamedRect]) { value += nextValue() }
}

/// Lists exactly what will be removed. D27: Esc cancels, Return removes (both buttons clickable).
struct CleanupConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    let items: [CleanupItem]

    /// D27b: every input (click or key) ends here; Remove is synchronous up to `confirmCleanup`.
    private func perform(_ a: ConfirmAction) {
        switch a {
        case .cancel: model.pendingCleanup = nil
        case .remove: model.confirmCleanup(items)
        }
    }

    var body: some View {
        let summary = ConfirmWording.summary(bytes: items.map(\.bytes), pruneOnly: items.map { $0.kind == .pruneOnly })
        VStack(alignment: .leading, spacing: 10) {
            Text(items.count == 1 ? "Remove this worktree?" : "Remove \(items.count) worktrees?")
                .font(.system(size: 13, weight: .semibold))
            Text("Runs `git worktree remove` (no --force) then `git worktree prune`. Branches are kept. Each one is checked again first and skipped if it changed.")
                .font(.system(size: 11)).foregroundColor(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { i in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(i.branch) · \(i.repo)").font(.system(size: 11.5, weight: .medium))
                                Text(Format.middle(i.path, max: 52)).font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.ink2).help(i.path)
                            }
                            Spacer()
                            // D27: a prune-only folder is already gone; no size (it frees nothing).
                            Text(i.kind == .pruneOnly ? ConfirmWording.pruneTag : Format.bytes(i.bytes))
                                .font(.system(size: 11)).monospacedDigit().foregroundColor(Theme.ink2)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            Divider()
            HStack {
                Text(summary).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer()
                // D27b: plain buttons in the shared style that fire on click. No system bezel, no role and no
                // keyboard shortcut on the visible buttons: the `.defaultAction` system button is what ignored
                // clicks. Esc/Return are bound separately (hidden buttons below), all through `perform`.
                Button { perform(.cancel) } label: { Text("Cancel").frame(width: ConfirmLayout.cancelWidth) }
                    .buttonStyle(HoverButtonStyle(kind: .plain, height: ConfirmLayout.buttonHeight))
                    .frame(width: ConfirmLayout.cancelWidth, height: ConfirmLayout.buttonHeight)
                    .background(ConfirmButtonFrame(name: "Cancel"))
                Button { perform(.remove) } label: { Text(items.count == 1 ? "Remove" : "Remove \(items.count)").frame(width: ConfirmLayout.removeWidth - 28) }
                    .buttonStyle(HoverButtonStyle(kind: .dark))
                    .frame(width: ConfirmLayout.removeWidth, height: ConfirmLayout.buttonHeight)
                    .background(ConfirmButtonFrame(name: "Remove"))
            }
        }
        .padding(ConfirmLayout.padding)
        .frame(width: ConfirmLayout.width)
        .background {
            // D27b: the keys, bound apart from the clickable buttons.
            Button("") { perform(ConfirmInput.escape.action) }.keyboardShortcut(.cancelAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            Button("") { perform(ConfirmInput.return.action) }.keyboardShortcut(.defaultAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

/// Results of the last run and space freed. Dismissable.
struct CleanupResultsView: View {
    @EnvironmentObject var model: AppModel
    let results: [CleanupOutcome]

    var body: some View {
        let freed = results.reduce(Int64(0)) { $0 + $1.freed }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Freed \(Format.bytes(freed))").font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button("Done") { model.cleanupResults = nil; model.clearReappeared() }.buttonStyle(HoverButtonStyle(kind: .link))
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, o in
                Text(o.summary).font(.system(size: 10.5)).foregroundColor(Theme.ink2).lineLimit(1)
            }
            // D28: removed, but `git worktree list` still lists it: restored to the map.
            ForEach(model.reappeared, id: \.self) { p in
                Text("Still listed by git, restored: \(Format.middle(p, max: 48))").font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: LeafPalette.ink)).lineLimit(1).help(p)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.line.opacity(0.5)))
    }
}

extension StaleReason {
    var label: String {
        switch self { case .merged: "merged"; case .upstreamGone: "upstream gone"; case .prunable: "folder missing" }
    }
}

/// Header "All repos" button (D18): a small popover with All/None, a search field past 10 repos,
/// and one checkbox per repo with its worktree count. Option-click a repo to show only that one.
struct RepoFilterButton: View {
    @EnvironmentObject var model: AppModel
    let repos: [Repo]
    let label: String
    let textFrame: Rect

    var body: some View {
        Button { model.repoMenuOpen.toggle() } label: {
            HStack(spacing: 3) {
                HeaderText(text: label, size: HeaderLayout.filterSize, color: Theme.ink2, frame: textFrame, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundColor(Theme.ink2)
            }
        }
        .buttonStyle(HoverButtonStyle(kind: .link, height: 18))
        .accessibilityLabel("Repo filter: \(label)")
    }
}

/// D26: the repo filter menu as an opaque panel in the light palette (RepoMenuStyle), drawn inside the
/// popover over the map: readable names, real checkboxes, a selected state, hover rows in the shared style.
struct RepoMenuPanel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let repos: [Repo]
    @State private var query = ""

    private func set(_ f: RepoFilter) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.setFilter(f) }
    }

    var body: some View {
        let rows = RepoFilter.matching(repos, query: query)
        let searching = repos.count > RepoFilter.searchThreshold
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("All") { var f = model.filter; f.selectAll(); set(f) }
                Button("None") { var f = model.filter; f.selectNone(repos); set(f) }
                Spacer()
                Text("⌥-click: only").font(.system(size: 10)).foregroundColor(Color(hex: RepoMenuStyle.hint))
            }
            .buttonStyle(HoverButtonStyle(kind: .link)).foregroundColor(Color(hex: RepoMenuStyle.name))
            .frame(height: RepoMenuLayout.topRow)
            if searching {
                TextField("Search repos", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    .frame(height: RepoMenuLayout.search)
            }
            Rectangle().fill(Color(hex: RepoMenuStyle.stroke)).frame(height: 1).padding(.vertical, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.path) { repo in
                        let on = model.filter.includes(repo)
                        Button {
                            var f = model.filter
                            if NSEvent.modifierFlags.contains(.option) { f.only(repo.path, among: repos) } else { f.toggle(repo.path) }
                            set(f)
                        } label: {
                            HStack(spacing: 6) {
                                ZStack {
                                    if on {
                                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: RepoMenuStyle.selectedCheck))
                                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                    } else {
                                        RoundedRectangle(cornerRadius: 3).stroke(Color(hex: RepoMenuStyle.uncheckedBox), lineWidth: 1)
                                    }
                                }
                                .frame(width: RepoMenuLayout.checkSide, height: RepoMenuLayout.checkSide)
                                Text(repo.name).fontWeight(on ? .medium : .regular).lineLimit(1).truncationMode(.middle)
                                    .foregroundColor(Color(hex: RepoMenuStyle.name))
                                Spacer(minLength: 4)
                                Text("\(repo.worktrees.count)").monospacedDigit().foregroundColor(Color(hex: RepoMenuStyle.count))
                            }
                            .font(.system(size: 11.5))
                            .frame(maxWidth: .infinity, minHeight: RepoMenuLayout.row, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverButtonStyle(kind: .link, height: nil))
                        .help(repo.path)
                        .accessibilityLabel("\(repo.name), \(repo.worktrees.count) worktrees, \(on ? "shown" : "hidden")")
                    }
                }
            }
            .frame(height: CGFloat(min(rows.count, RepoMenuLayout.maxRows)) * RepoMenuLayout.row)
        }
        .padding(RepoMenuLayout.padding)
        .frame(width: RepoMenuLayout.width, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: RepoMenuStyle.background))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: RepoMenuStyle.stroke), lineWidth: 0.8))
        .environment(\.colorScheme, .light)
        .reportFrame(RepoMenuFrameKey.self)
        .onPreferenceChange(RepoMenuFrameKey.self) { model.hover.drawnRepoMenu = $0.first }
    }
}

/// D26: one header text at its natural width in its HeaderLayout frame; reports natural vs frame (sweep).
struct HeaderText: View {
    let text: String, size: Double, color: Color, frame: Rect
    var alignment: Alignment = .leading
    var onNatural: ((Double) -> Void)? = nil
    @State private var natural = 0.0
    var body: some View {
        Text(text).font(.system(size: size)).foregroundColor(color).lineLimit(1)
            .frame(width: frame.w, height: frame.h, alignment: alignment)
            .background(Text(text).font(.system(size: size)).fixedSize().hidden()
                .background(GeometryReader { g in Color.clear.preference(key: NaturalWidthKey.self, value: g.size.width) }))
            .onPreferenceChange(NaturalWidthKey.self) { natural = $0; onNatural?($0) }
            .background(GeometryReader { g in
                let f = g.frame(in: .named(PopoverCoords.name))
                Color.clear.preference(key: HeaderMeasureKey.self,
                                       value: [LegendMeasure(label: text, natural: natural, frame: Rect(x: f.minX, y: f.minY, w: f.width, h: f.height))])
            })
            .padding(EdgeInsets(top: alignment == .leading ? 0 : frame.y, leading: alignment == .leading ? 0 : frame.x, bottom: 0, trailing: 0))
    }
}
struct HeaderMeasureKey: PreferenceKey {
    static let defaultValue: [LegendMeasure] = []
    static func reduce(value: inout [LegendMeasure], nextValue: () -> [LegendMeasure]) { value += nextValue() }
}
struct RepoMenuFrameKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
}
#endif
