#if os(macOS)
import AppKit
import ArboristCleanup
import ArboristCore
import SwiftUI

/// The whole app: a 480pt popover under the menu bar item. Worktree-first leaves (D9, D12).
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var showList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                // "40 worktrees in 34 repos · 5 stale"
                let parts = (model.result?.headline ?? "— worktrees").split(separator: " ", maxSplits: 2).map(String.init)
                Text(parts.prefix(2).joined(separator: " ")).font(.system(size: 22, weight: .regular)).foregroundColor(Theme.ink)
                if parts.count > 2 { Text(parts[2]).font(.system(size: 13)).foregroundColor(Theme.ink2) }
                Spacer()
                Text(statusText).font(.system(size: 11.5)).foregroundColor(Theme.ink2)
                    .accessibilityLabel(statusText)
            }
            if let err = model.scanError {
                HStack(spacing: 8) {
                    Text(err + (model.result != nil ? " Showing the last results." : ""))
                        .font(.system(size: 11)).foregroundColor(Theme.ink)
                    Spacer()
                    Button("Retry") { model.rescan() }.font(.system(size: 11))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: LeafPalette.fill(.stale)).opacity(0.35)))
            }
            if let map = model.leafMap, let r = model.result {
                LeafMapView(map: map, result: r)
            } else {
                Text(model.scanning ? "Looking for repositories and worktrees…" : (model.scanError == nil ? "No scan yet" : "No results"))
                    .font(.system(size: 11)).foregroundColor(Theme.ink2)
                    .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight) // same layout in every state (D17)
            }
            HStack { Key(); Spacer(); Text(model.result.flatMap { Format.cachesTotal($0.caches) } ?? "").font(.system(size: 11)).foregroundColor(Theme.ink2) }
            FreeBar(free: model.freeBytes ?? 0, total: model.result?.volume?.totalBytes ?? 0)
            HStack(spacing: 8) {
                let n = model.clearPlan.count
                Button(model.cleaning ? "Clearing…" : "Clear \(n)") { model.requestClear() }
                    .buttonStyle(DarkButtonStyle())
                    .disabled(n == 0 || model.cleaning)
                    .help("Removes \(n) merged or upstream-gone worktrees with nothing uncommitted or unpushed. Asks first; branches are kept.")
                Button(model.scanning ? "Scanning…" : "Rescan") { model.rescan() }.disabled(model.scanning)
                Button(showList ? "Hide list" : "List") { showList.toggle() }
                Spacer()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundColor(Theme.ink2)
            if showList, let r = model.result { Checklist(result: r).frame(maxHeight: 260) }
            if let results = model.cleanupResults { CleanupResultsView(results: results) }
        }
        .padding(PopoverLayout.padding)
        .frame(width: PopoverLayout.width)
        .fixedSize(horizontal: false, vertical: true) // height = the content's ideal height, never squeezed
        .background(Theme.paper)
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
struct Key: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([(LeafState.protected, "Uncommitted / unpushed"), (.clean, "Clean"), (.stale, "Merged / stale")], id: \.1) { st, name in
                HStack(spacing: 5) {
                    Circle().fill(Color(hex: LeafPalette.fill(st))).frame(width: 8, height: 8)
                    Text(name)
                }
            }
        }
        .font(.system(size: 11)).foregroundColor(Theme.ink2)
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

struct DarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: LeafPalette.button).opacity(configuration.isPressed ? 0.8 : 1)))
            .foregroundColor(Color(hex: LeafPalette.labelOnDark))
    }
}

struct PlainPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(Capsule().fill(configuration.isPressed ? Theme.line : Color.white.opacity(0.6)))
            .overlay(Capsule().stroke(Theme.ink.opacity(0.7), lineWidth: 1))
            .foregroundColor(Theme.ink)
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

    var body: some View {
        let blocker = Cleanup.blocker(ref.worktree)
        Button(blocker.map { "\(title) — \($0.reason)" } ?? title) { model.requestRemove(ref) }
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
                Button("Done") { model.cleanupResults = nil }.buttonStyle(.borderless)
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

#endif
