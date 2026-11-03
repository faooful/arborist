#if os(macOS)
import ArboristCleanup
import ArboristCore
import SwiftUI

/// Draws the worktree leaf map (D12, D13).
///
/// Hover (D13): the hovered leaf lifts to 1.03× with a soft shadow and the others fade to 0.88, over
/// ~180 ms ease-in-out. `HoverTracker` debounces gutters so moving between neighbours cross-fades and
/// the card stays up. With Reduce Motion: no scale or lift, a short opacity-only fade.
/// `hovered` is shared with the List, so hovering a row lifts its leaf too.
struct LeafMapView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let map: LeafMap
    let result: ScanResult
    @Binding var hovered: String?
    @State private var tracker = HoverTracker()
    @State private var cardRect: CGRect = .zero

    private var anim: Animation { .easeInOut(duration: HoverTracker.duration(reduceMotion: reduceMotion)) }
    private func now() -> Double { Date().timeIntervalSinceReferenceDate }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LeafCanvas(map: map, only: nil)
                .opacity(hovered == nil ? 1 : LeafPalette.dimOthers)
            if let h = hovered, let leaf = map.leaves.first(where: { $0.item.id == h }) {
                let a = UnitPoint(x: leaf.centroid.x / map.width, y: leaf.centroid.y / map.height)
                LeafCanvas(map: map, only: h)
                    .scaleEffect(reduceMotion ? 1 : LeafPalette.hoverScale, anchor: a)
                    .offset(y: reduceMotion ? 0 : -1)
                    .shadow(color: .black.opacity(reduceMotion ? 0 : 0.16), radius: 5, x: 0, y: 3)
                    .id(h)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let h = hovered, let leaf = map.leaves.first(where: { $0.item.id == h }), let ref = WorktreeList.find(result, path: h) {
                let card = HoverCard(ref)
                let (x0, y0, x1, y1) = Geo.bbox(leaf.outline)
                let size = Pt(LeafSVG.cardWidth, LeafSVG.cardHeight(card) + 26) // + the Remove worktree row (D14)
                let o = LeafSVG.cardOrigin(avoiding: Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0), size: size, in: Pt(map.width, map.height))
                HoverCardView(card: card, ref: ref)
                    .frame(width: size.x, height: size.y, alignment: .topLeading)
                    .offset(x: o.x, y: o.y)
                    .transition(.opacity)
                    .onAppear { cardRect = CGRect(x: o.x, y: o.y, width: size.x, height: size.y) }
                    .onChange(of: h) { _ in cardRect = CGRect(x: o.x, y: o.y, width: size.x, height: size.y) }
                    .onHover { inside in
                        // Pointer on the card keeps it up so its buttons can be clicked.
                        if inside { tracker.pointer(tracker.card, at: now()) }
                    }
            }
            ForEach(map.groupLabels, id: \.name) { g in
                Text(g.name).font(.system(size: LeafText.groupSize, weight: .medium)).foregroundColor(Theme.ink3)
                    .fixedSize().position(x: g.at.x, y: g.at.y - 4)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: map.width, height: map.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p):
                if hovered != nil && cardRect.contains(p) { return }
                point(map.leaf(at: Pt(p.x, p.y))?.item.id)
            case .ended:
                point(nil)
            }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            if let item = map.leaf(at: Pt(p.x, p.y))?.item, let path = item.path { model.reveal(path) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Worktree map: \(result.headline). The list has every worktree.")
    }

    private func point(_ id: String?) {
        if tracker.pointer(id, at: now()) { withAnimation(anim) { hovered = tracker.hovered } }
        if id == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + HoverTracker.leaveDelay + 0.01) {
                if tracker.settle(at: now()) { withAnimation(anim) { hovered = tracker.hovered } }
            }
        }
    }
}

/// All leaves (or just `only`) with their branch labels.
struct LeafCanvas: View {
    let map: LeafMap
    let only: String?

    var body: some View {
        Canvas { ctx, _ in
            for leaf in map.leaves where only == nil || leaf.item.id == only { draw(leaf, in: &ctx) }
        }
        .frame(width: map.width, height: map.height)
    }

    private func path(_ pts: [Pt]) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.x, y: f.y))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
        p.closeSubpath()
        return p
    }

    private func draw(_ leaf: Leaf, in ctx: inout GraphicsContext) {
        let st = leaf.item.state, shape = path(leaf.outline)
        ctx.fill(shape, with: .color(Color(hex: LeafPalette.fill(st))))
        if st == .stale { ctx.stroke(shape, with: .color(Color(hex: LeafPalette.staleStroke)), lineWidth: 0.4) }
        if !leaf.inner.isEmpty {
            ctx.fill(path(leaf.inner), with: .color(Color(hex: LeafPalette.rebuildableShade, opacity: LeafPalette.rebuildableOpacity(st))))
        }
        let (vc, vo) = LeafPalette.vein(st)
        ctx.drawLayer { layer in
            layer.clip(to: shape)
            for v in leaf.veins {
                var p = Path()
                p.move(to: CGPoint(x: v.p0.x, y: v.p0.y))
                p.addQuadCurve(to: CGPoint(x: v.p1.x, y: v.p1.y), control: CGPoint(x: v.c.x, y: v.c.y))
                layer.stroke(p, with: .color(Color(hex: vc, opacity: vo * v.opacity)), style: StrokeStyle(lineWidth: v.width, lineCap: .round))
            }
        }
        if let name = leaf.labelLines.first {
            let lc = LeafPalette.isDark(st) ? Color(hex: LeafPalette.labelOnDark) : Color(hex: "#1c1e21")
            ctx.draw(Text(name).font(.system(size: LeafText.leafSize, weight: .medium)).foregroundColor(lc),
                     at: CGPoint(x: leaf.centroid.x, y: leaf.centroid.y))
        }
    }
}

/// The hover card (D13): header, 2×2 stats, commit message, footer buttons. Same metrics as the SVG.
struct HoverCardView: View {
    @EnvironmentObject var model: AppModel
    let card: HoverCard
    let ref: WorktreeRef

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(card.branch).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text(card.pill).font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: LeafPalette.pillText(card.status)))
                    .padding(.horizontal, 6).frame(height: 14)
                    .background(Capsule().fill(Color(hex: LeafPalette.dot(card.status), opacity: 0.2)))
            }
            Text(card.repo).font(.system(size: 11)).foregroundColor(Theme.ink2).lineLimit(1).padding(.top, 3)
            Text(card.path).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.ink2).lineLimit(1)
                .help(card.fullPath).padding(.top, 2)
            Rectangle().fill(Color(hex: LeafPalette.cardStroke)).frame(height: 0.6).padding(.vertical, 6)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    stat("Size", card.size) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color(hex: LeafPalette.barTrack))
                                Capsule().fill(Color(hex: LeafPalette.barFill)).frame(width: g.size.width * card.rebuildableShare)
                            }
                        }
                        .frame(width: 96, height: 4)
                        .opacity(card.rebuildableShare > 0 ? 1 : 0)
                        .help(card.rebuildable ?? "")
                    }
                    stat("Changes", card.changes) { EmptyView() }
                }
                GridRow {
                    stat("Sync", card.sync) { EmptyView() }
                    stat("Last commit", card.lastCommit) { EmptyView() }
                }
            }
            if !card.message.isEmpty {
                Text(card.message.joined(separator: "\n")).font(.system(size: 11)).foregroundColor(Theme.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            HStack(spacing: 6) {
                Button("Reveal in Finder") { model.reveal(ref.worktree.path) }
                if let cmd = card.removeCommand { Button("Copy remove command") { model.copy(cmd) }.help(cmd) }
            }
            .buttonStyle(SubtleButtonStyle())
            .padding(.top, 8)
            RemoveButton(ref: ref).buttonStyle(SubtleButtonStyle()).padding(.top, 4)
        }
        .padding(10)
        .frame(width: LeafSVG.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: LeafPalette.cardFill)).shadow(color: .black.opacity(0.12), radius: 5, y: 3))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: LeafPalette.cardStroke), lineWidth: 0.6))
    }

    private func stat<Extra: View>(_ label: String, _ value: String, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundColor(Theme.ink2)
            Text(value).font(.system(size: 11.5, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
            extra()
        }
        .frame(width: (LeafSVG.cardWidth - 28) / 2, alignment: .leading)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11)).foregroundColor(Theme.ink)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.line : Color(hex: LeafPalette.background)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: LeafPalette.cardStroke), lineWidth: 0.6))
    }
}

/// Menu bar glyph for a wilt stage, as a template image so it follows light and dark mode.
enum LeafIcon {
    static func image(_ stage: LeafStage) -> NSImage {
        let g = LeafGlyph.glyph(stage)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            func bez(_ pts: [Pt], close: Bool) -> NSBezierPath {
                let b = NSBezierPath()
                for (i, p) in pts.enumerated() {
                    let q = NSPoint(x: p.x * rect.width, y: p.y * rect.height)
                    i == 0 ? b.move(to: q) : b.line(to: q)
                }
                if close { b.close() }
                b.lineCapStyle = .round; b.lineJoinStyle = .round
                return b
            }
            NSColor.black.set()
            let outline = bez(g.outline, close: true)
            if g.filled { outline.fill() } else { outline.lineWidth = 1.1; outline.stroke() }
            let stem = bez(g.stem, close: false); stem.lineWidth = 1.3; stem.stroke()
            if g.filled {
                // Cut the midrib out of the fill so it reads at 18 pt.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let rib = bez(g.midrib, close: false); rib.lineWidth = 0.8; rib.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
#endif
