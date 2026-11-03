#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// The whole app: a 480pt popover under the menu bar item, in the H8 "leaves" design (D9).
struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    @State private var picked: LeafItem?
    @State private var showList = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(bigNumber).font(.system(size: 30, weight: .light)).foregroundColor(Theme.ink)
                Text("GB free").font(.system(size: 13)).foregroundColor(Theme.ink2)
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
            if let map = model.leafMap {
                LeafMapView(map: map, freeBytes: model.freeBytes ?? 0, selection: $picked)
            } else {
                Text(model.scanning ? "Looking for repositories and worktrees…" : (model.scanError == nil ? "No scan yet" : "No results"))
                    .font(.system(size: 11)).foregroundColor(Theme.ink2).frame(width: 448, height: 120)
            }
            if let item = picked, item.kind != .free { SelectedRow(item: item) }
            Key()
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
            if showList, let r = model.result { Checklist(result: r).frame(maxHeight: 260) }
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

    private var bigNumber: String {
        guard let f = model.freeBytes else { return "—" }
        return String(format: "%.0f", Double(f) / 1e9)
    }
}

/// The tapped leaf, with the v1 read-only actions.
struct SelectedRow: View {
    @EnvironmentObject var model: AppModel
    let item: LeafItem
    var body: some View {
        HStack(spacing: 8) {
            Text(item.foldedCount > 0 ? "other (\(item.foldedCount) small items)" : item.name)
                .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
            Text("\(Format.bytes(item.bytes)) · \(item.state.rawValue)").font(.system(size: 11)).foregroundColor(Theme.ink2)
            Spacer()
            if let p = item.path { Button("Reveal in Finder") { model.reveal(p) } }
            if let cmd = item.removeCommand { Button("Copy remove command") { model.copy(cmd) }.help(cmd) }
        }
        .buttonStyle(.borderless).font(.system(size: 11)).foregroundColor(Theme.ink)
    }
}

struct Key: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ForEach([(LeafState.protected, "Protected"), (.clean, "Clean"), (.stale, "Stale"), (.deps, "Deps"), (.free, "Free")], id: \.1) { st, name in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color(hex: LeafPalette.fill(st))).frame(width: 9, height: 9)
                        Text(name)
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach([(LeafKind.worktree, "Worktree"), (.main, "Main"), (.cache, "Cache"), (.deps, "Deps")], id: \.1) { _, name in
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

/// Quiet checklist: projects (largest first) with worktrees, then shared caches.
struct Checklist: View {
    @EnvironmentObject var model: AppModel
    let result: ScanResult

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let maxBytes = max(1, result.repos.first?.size.total ?? 1)
                ForEach(result.repos, id: \.path) { repo in
                    RepoRow(repo: repo, maxBytes: maxBytes)
                }
                if !result.caches.isEmpty {
                    Text("Shared caches").font(.caption.weight(.semibold)).foregroundColor(Theme.ink3)
                        .padding(.top, 14).padding(.bottom, 4)
                    ForEach(result.caches, id: \.name) { c in
                        Row(selected: model.selection == c.path, title: c.name, detail: nil, bytes: c.bytes, rebuildable: c.bytes, fraction: nil)
                            .onTapGesture { model.selection = c.path }
                            .contextMenu { if let p = c.path { Button("Reveal in Finder") { model.reveal(p) } } }
                    }
                }
            }
        }
    }
}

struct RepoRow: View {
    @EnvironmentObject var model: AppModel
    let repo: Repo
    let maxBytes: Int64
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Row(selected: model.selection == repo.path, title: repo.name,
                detail: repo.worktrees.count > 1 ? "\(repo.worktrees.count) worktrees" : nil,
                bytes: repo.size.total, rebuildable: repo.size.rebuildable,
                fraction: Double(repo.size.total) / Double(maxBytes), disclosure: open)
                .onTapGesture { model.selection = repo.path; open.toggle() }
                .contextMenu { Button("Reveal in Finder") { model.reveal(repo.path) } }
            if open {
                ForEach(repo.worktrees, id: \.path) { w in WorktreeRow(repoPath: repo.path, w: w) }
            }
        }
    }
}

struct WorktreeRow: View {
    @EnvironmentObject var model: AppModel
    let repoPath: String
    let w: Worktree

    var body: some View {
        HStack(spacing: 8) {
            Text(w.branch ?? "detached").font(.system(.body, design: .monospaced)).foregroundColor(w.stale ? Theme.ink3 : Theme.ink)
            Text(flags).font(.caption).foregroundColor(Theme.ink3)
            Spacer()
            Text(Format.bytes(w.size.total)).monospacedDigit().foregroundColor(Theme.ink2)
            Button("Reveal") { model.reveal(w.path) }.buttonStyle(.link).foregroundColor(Theme.ink2)
            if let cmd = w.removeCommand {
                Button("Copy remove command") { model.copy(cmd) }.buttonStyle(.link).foregroundColor(Theme.ink2)
                    .help(cmd)
            }
        }
        .padding(.leading, 30).padding(.vertical, 5)
        .help(w.path)
    }

    private var flags: String {
        var f: [String] = []
        if w.isMain { f.append("main") }
        if let d = w.lastCommitDate { f.append(d.formatted(.relative(presentation: .named))) }
        if w.dirty { f.append("dirty") }
        if let n = w.unpushedCommits, n > 0 { f.append("\(n) unpushed") }
        if !w.hasUpstream && w.branch != nil && !w.isMain { f.append("no upstream") }
        if w.stale { f.append("stale (" + w.staleReasons.map(\.label).joined(separator: ", ") + ")") }
        return f.joined(separator: " · ")
    }
}

extension StaleReason {
    var label: String {
        switch self { case .merged: "merged"; case .upstreamGone: "upstream gone"; case .prunable: "folder missing" }
    }
}

struct Row: View {
    var selected: Bool
    var title: String
    var detail: String?
    var bytes: Int64
    var rebuildable: Int64
    var fraction: Double?
    var disclosure: Bool? = nil

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? Theme.ink : Theme.line)
                Text(title).foregroundColor(Theme.ink)
                if let detail { Text(detail).font(.caption).foregroundColor(Theme.ink3) }
                Spacer()
                if rebuildable > 0 && rebuildable != bytes {
                    Text("\(Format.bytes(rebuildable)) rebuildable").font(.caption).foregroundColor(Theme.ink3)
                }
                Text(Format.bytes(bytes)).monospacedDigit().foregroundColor(Theme.ink)
            }
            if let fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line.opacity(0.5))
                        Capsule().fill(Theme.ink2).frame(width: g.size.width * fraction)
                        Capsule().fill(Theme.ink3.opacity(0.5))
                            .frame(width: g.size.width * fraction * Double(rebuildable) / Double(max(bytes, 1)))
                    }
                }
                .frame(height: 3)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 0.5) }
    }
}
#endif
