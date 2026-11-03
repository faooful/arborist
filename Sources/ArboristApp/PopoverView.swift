#if os(macOS)
import AppKit
import ArboristCleanup
import ArboristCore
import SwiftUI

/// D24: the one shared slot below the map, a fixed 448 × stripHeight. At rest it shows `content` (legend and
/// storage bar); on hover or pin the leaf details crossfade in (0.2 s, none with Reduce Motion) in the same
/// rect. Never empty, never resized. Its own view so pointer moves don't re-render the whole popover.
struct SharedSlot<Content: View>: View {
    @EnvironmentObject var hover: HoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let result: ScanResult?
    @ViewBuilder var content: Content

    var body: some View {
        let shown = result != nil && hover.visible.strip.flatMap { id in result.flatMap { WorktreeList.find($0, path: id) } } != nil
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(.top, StripLayout.padding)
                .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
                .opacity(shown ? 0 : 1)
                .allowsHitTesting(!shown)
                .accessibilityHidden(shown)
            if let r = result { DetailStrip(result: r) }
        }
        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
        .animation(reduceMotion || hover.instant ? nil : .easeInOut(duration: PopoverLayout.stripFade), value: shown)
        .reportFrame(SlotFrameKey.self)
        .onPreferenceChange(SlotFrameKey.self) { hover.drawnSlotFrame = $0.first }
    }
}

/// D24: the slot's and the footer buttons' frames as drawn (popover coordinates), for the sweep.
struct SlotFrameKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                // "40 worktrees in 34 repos · 5 stale"
                let parts = (model.result?.headline ?? "— worktrees").split(separator: " ", maxSplits: 2).map(String.init)
                Text(parts.prefix(2).joined(separator: " ")).font(.system(size: 22, weight: .regular)).foregroundColor(Theme.ink)
                if parts.count > 2 { Text(parts[2]).font(.system(size: 13)).foregroundColor(Theme.ink2) }
                if let all = model.scanned?.repos, !all.isEmpty {
                    RepoFilterButton(repos: all).padding(.leading, 6)
                }
                Spacer()
                Text(statusText).font(.system(size: 11.5)).foregroundColor(Theme.ink2)
                    .accessibilityLabel(statusText)
            }
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
                HStack { Key(); Spacer(minLength: 4); Text(model.result.flatMap { Format.cachesTotal($0.caches) } ?? "").font(.system(size: 11)).foregroundColor(Theme.ink2).lineLimit(1).layoutPriority(-1) }
                FreeBar(free: model.freeBytes ?? 0, total: model.result?.volume?.totalBytes ?? 0)
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
                Spacer()
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
        // D22: the tooltip sits above everything, placed against the whole popover; it never takes hit-testing.
        .overlay(alignment: .topLeading) {
            if let r = model.result, !model.filterHidesEverything, !model.nothingMatches { TooltipOverlay(result: r) }
        }
        // Esc unpins (D22). A hidden cancel button, since the map itself rarely has key focus in the popover.
        .background {
            Button("") { model.hover.unpin() }.keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background {
            if #available(macOS 14.0, *) { SettingsActionBridge() }
        }
        .background(GeometryReader { g in
            Color.clear.onAppear { model.hover.popoverSize = Pt(g.size.width, g.size.height) }
                .onChange(of: g.size) { s in model.hover.popoverSize = Pt(s.width, s.height) }
        })
        .sheet(item: Binding(get: { model.pendingCleanup.map(CleanupBatch.init) }, set: { if $0 == nil { model.pendingCleanup = nil } })) { batch in
            CleanupConfirmSheet(items: batch.items)
        }
    }

    /// "12/34 repos" while scanning, "Cached · refreshing" for a cached scan, else "Arborist".
    private var statusText: String {
        if let p = model.progressLabel { return model.resultIsCached ? "Cached · \(p)" : p }
        if model.resultIsCached { return "Cached" }
        return "Arborist"
    }

}

/// One legend line, three dots (D13).
/// The legend, as state filters (D21): click toggles a state, ⌥-click shows only it, inactive items are dimmed.
/// "Ready to clean (N)" is exactly Clear N's set (CleanupSafety). "Show all" appears when any are off.
struct Key: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = model.states
        HStack(spacing: 9) {
            ForEach(StateKey.allCases, id: \.self) { k in
                Button { tap(k) } label: {
                    HStack(spacing: 4) {
                        dot(k)
                        Text(k == .ready ? "\(short(k)) (\(readyCount))" : short(k))
                            .fontWeight(s.isActive(k) && !s.isAll ? .semibold : .regular)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(s.isActive(k) && !s.isAll ? Theme.line : Color.clear))
                    .opacity(s.isAll || s.isActive(k) ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle(kind: .link, height: nil))
                .help(k == .ready ? "Exactly what Clear would remove. ⌥-click: only this." : "\(k.title). Click to toggle, ⌥-click: only this.")
                .accessibilityLabel("\(k.title)\(k == .ready ? ", \(readyCount)" : ""), \(s.isActive(k) ? "shown" : "hidden")")
            }
            if !s.isAll {
                Button("Show all") { set(.all) }.buttonStyle(HoverButtonStyle(kind: .link, height: nil))
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

struct FreeBar: View {
    let free: Int64, total: Int64
    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Color(hex: LeafPalette.barFill))
                        .frame(width: total > 0 ? g.size.width * (1 - Double(free) / Double(total)) : 0)
                }
            }.frame(height: 6)
            HStack {
                Text(Format.bytes(free)).fontWeight(.medium).foregroundColor(Theme.ink) + Text(" free").foregroundColor(Theme.ink2)
                Spacer()
                Text("of \(Format.bytes(total))").foregroundColor(Theme.ink2)
            }.font(.system(size: 11))
        }
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

/// Lists exactly what will be removed. Cancel is the default (Return/Escape); Remove has no shortcut.
struct CleanupConfirmSheet: View {
    @EnvironmentObject var model: AppModel
    let items: [CleanupItem]

    var body: some View {
        let total = items.reduce(Int64(0)) { $0 + ($1.kind == .remove ? $1.bytes : 0) }
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
                            Text(i.kind == .pruneOnly ? "prune only" : Format.bytes(i.bytes))
                                .font(.system(size: 11)).monospacedDigit().foregroundColor(Theme.ink2)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            Divider()
            HStack {
                Text("Frees about \(Format.bytes(total))").font(.system(size: 11.5, weight: .medium))
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingCleanup = nil }
                    .keyboardShortcut(.defaultAction)
                Button(items.count == 1 ? "Remove" : "Remove \(items.count)", role: .destructive) { model.confirmCleanup(items) }
            }
        }
        .padding(16)
        .frame(width: 420)
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
                Button("Done") { model.cleanupResults = nil }.buttonStyle(HoverButtonStyle(kind: .link))
            }
            ForEach(Array(results.enumerated()), id: \.offset) { _, o in
                Text(o.summary).font(.system(size: 10.5)).foregroundColor(Theme.ink2).lineLimit(1)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let repos: [Repo]
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Text(model.filter.label(repos)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 11.5)).foregroundColor(Theme.ink2)
            .frame(maxWidth: 140, alignment: .leading)
        }
        .buttonStyle(HoverButtonStyle(kind: .link))
        .accessibilityLabel("Repo filter: \(model.filter.label(repos))")
        .popover(isPresented: $open, arrowEdge: .bottom) { menu }
    }

    private func set(_ f: RepoFilter) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.setFilter(f) }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("All") { var f = model.filter; f.selectAll(); set(f) }
                Button("None") { var f = model.filter; f.selectNone(repos); set(f) }
                Spacer()
                Text("⌥-click: only").font(.system(size: 10)).foregroundColor(Theme.ink2)
            }
            .buttonStyle(HoverButtonStyle(kind: .link)).font(.system(size: 11))
            if repos.count > RepoFilter.searchThreshold {
                TextField("Search repos", text: $query).textFieldStyle(.roundedBorder).font(.system(size: 11))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(RepoFilter.matching(repos, query: query), id: \.path) { repo in
                        Button {
                            var f = model.filter
                            if NSEvent.modifierFlags.contains(.option) { f.only(repo.path, among: repos) } else { f.toggle(repo.path) }
                            set(f)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: model.filter.includes(repo) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(model.filter.includes(repo) ? Theme.ink : Theme.ink2)
                                Text(repo.name).lineLimit(1).truncationMode(.middle).foregroundColor(Theme.ink)
                                Spacer()
                                Text("\(repo.worktrees.count)").monospacedDigit().foregroundColor(Theme.ink2)
                            }
                            .font(.system(size: 11.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverButtonStyle(kind: .link, height: nil))
                        .help(repo.path)
                        .accessibilityLabel("\(repo.name), \(repo.worktrees.count) worktrees, \(model.filter.includes(repo) ? "shown" : "hidden")")
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(10)
        .frame(width: 240)
    }
}
#endif
