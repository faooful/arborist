#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// The whole app: a small popover under the menu bar item. Plain styling until the popover redesign lands.
struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.freeLabel) free").font(.title2.weight(.semibold))
            Text(summary).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            if let r = model.result {
                Checklist(result: r).frame(maxHeight: 360)
            } else {
                Text(model.scanning ? "Scanning…" : "No scan yet").foregroundColor(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                Button(model.scanning ? "Scanning…" : "Rescan") { model.rescan() }.disabled(model.scanning)
                Button("Reveal in Finder") { model.reveal(model.selection ?? ArboristConfig.home) }
                Spacer()
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(PlainPillStyle())
        }
        .padding(14)
        .frame(width: 420)
    }

    private var summary: String {
        guard let r = model.result else { return "Looking for repositories and worktrees in your scan folders." }
        return Format.summarySentence(r)
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
