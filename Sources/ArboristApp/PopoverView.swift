#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// The whole app: a 480pt popover under the menu bar item. Worktree-first leaves (D9, D12).
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: String?
    @State private var showList = false
    @State private var copied = false

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
                LeafMapView(map: map, result: r, hovered: $hovered)
            } else {
                Text(model.scanning ? "Looking for repositories and worktrees…" : (model.scanError == nil ? "No scan yet" : "No results"))
                    .font(.system(size: 11)).foregroundColor(Theme.ink2).frame(width: 448, height: 120)
            }
            HStack { Key(); Spacer(); Text(model.result.flatMap { Format.cachesTotal($0.caches) } ?? "").font(.system(size: 11)).foregroundColor(Theme.ink2) }
            FreeBar(free: model.freeBytes ?? 0, total: model.result?.volume?.totalBytes ?? 0)
            HStack(spacing: 8) {
                let n = model.leafMap?.staleCount ?? 0
                Button(copied ? "Copied" : "Clear \(n)") {
                    model.copy(model.staleCommands.joined(separator: "\n"))
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(DarkButtonStyle())
                .disabled(n == 0)
                .help("Read-only: copies \(n) `git worktree remove` commands for the stale worktrees. Nothing is deleted.")
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
            if showList, let r = model.result { Checklist(result: r, hovered: $hovered).frame(maxHeight: 260) }
        }
        .padding(16)
        .frame(width: 480)
        .background(Theme.paper)
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
    @Binding var hovered: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(WorktreeList.sorted(result), id: \.worktree.path) { ref in
                        WorktreeRow(ref: ref, highlighted: hovered == ref.worktree.path)
                            .id(ref.worktree.path)
                            .onHover { inside in
                                if inside { hovered = ref.worktree.path } else if hovered == ref.worktree.path { hovered = nil }
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
            if let cmd = w.removeCommand {
                Button("Copy remove") { model.copy(cmd) }.buttonStyle(.link).foregroundColor(Theme.ink2).help(cmd)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? Theme.line.opacity(0.7) : .clear))
        .contentShape(Rectangle())
        .help(w.path)
    }
}

extension StaleReason {
    var label: String {
        switch self { case .merged: "merged"; case .upstreamGone: "upstream gone"; case .prunable: "folder missing" }
    }
}

#endif
