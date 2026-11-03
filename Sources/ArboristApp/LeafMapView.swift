#if os(macOS)
import ArboristCore
import SwiftUI

/// Draws the worktree leaf map (D12) from `LeafLayout` geometry.
/// Hover lifts and outlines a leaf, dims the rest and shows its card; click reveals it.
/// `hovered` is shared with the List so the matching row lights up too.
struct LeafMapView: View {
    @EnvironmentObject var model: AppModel
    let map: LeafMap
    let result: ScanResult
    @Binding var hovered: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for leaf in map.leaves where leaf.item.id != hovered { draw(leaf, in: &ctx, dim: hovered != nil, lifted: false) }
                if let h = hovered, let leaf = map.leaves.first(where: { $0.item.id == h }) { draw(leaf, in: &ctx, dim: false, lifted: true) }
                for g in map.groupLabels {
                    let t = Text(g.name).font(.system(size: 10.5, weight: .medium)).foregroundColor(Theme.ink3)
                    if g.vertical {
                        var c = ctx
                        c.translateBy(x: g.at.x, y: g.at.y)
                        c.rotate(by: .degrees(-90))
                        c.draw(t, at: .zero)
                    } else {
                        ctx.draw(t, at: CGPoint(x: g.at.x, y: g.at.y - 3))
                    }
                }
            }
            .frame(width: map.width, height: map.height)
            if let h = hovered, let leaf = map.leaves.first(where: { $0.item.id == h }), let ref = WorktreeList.find(result, path: h) {
                let card = HoverCard(ref)
                let size = Pt(LeafSVG.cardWidth, LeafSVG.cardHeight(card))
                let o = LeafSVG.cardOrigin(near: leaf.centroid, size: size, in: Pt(map.width, map.height))
                HoverCardView(card: card)
                    .frame(width: size.x, height: size.y, alignment: .topLeading)
                    .offset(x: o.x, y: o.y)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: map.width, height: map.height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hovered = map.leaf(at: Pt(p.x, p.y))?.item.id
            case .ended: hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { p in
            if let item = map.leaf(at: Pt(p.x, p.y))?.item, let path = item.path { model.reveal(path) }
        }
        .contextMenu {
            if let h = hovered, let ref = WorktreeList.find(result, path: h) {
                Button("Reveal in Finder") { model.reveal(ref.worktree.path) }
                if let cmd = ref.worktree.removeCommand { Button("Copy `git worktree remove`") { model.copy(cmd) } }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Worktree map: \(result.headline). The list has every worktree.")
    }

    private func path(_ pts: [Pt]) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.x, y: f.y))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
        p.closeSubpath()
        return p
    }

    private func draw(_ leaf: Leaf, in parent: inout GraphicsContext, dim: Bool, lifted: Bool) {
        var ctx = parent
        if dim { ctx.opacity = LeafPalette.dimOthers }
        if lifted {
            ctx.translateBy(x: 0, y: -1.5)
            ctx.addFilter(.shadow(color: .black.opacity(0.22), radius: 4, x: 0, y: 3))
        }
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
        if lifted { ctx.stroke(shape, with: .color(Color(hex: LeafPalette.hoverStroke)), lineWidth: 1.6) }
        label(leaf, dark: LeafPalette.isDark(st), in: &ctx)
    }

    private func label(_ leaf: Leaf, dark: Bool, in ctx: inout GraphicsContext) {
        let lines = leaf.labelLines, c = leaf.centroid
        let lc = dark ? Color(hex: LeafPalette.labelOnDark) : Color(hex: "#1c1e21")
        let sc = dark ? Color(hex: LeafPalette.sizeOnDark) : Color(hex: LeafPalette.sizeOnLight)
        let y0 = c.y - Double(lines.count + (leaf.subLabel == nil ? 0 : 1)) * 12.5 / 2 + 2
        for (i, line) in lines.enumerated() {
            ctx.draw(Text(line).font(.system(size: 10.5, weight: .medium)).foregroundColor(lc), at: CGPoint(x: c.x, y: y0 + Double(i) * 12.5))
        }
        if leaf.showSize {
            let y = lines.isEmpty ? c.y : y0 + Double(lines.count) * 12.5
            ctx.draw(Text(Format.bytes(leaf.item.bytes)).font(.system(size: 10.5)).foregroundColor(sc), at: CGPoint(x: c.x, y: y))
        }
        if let sub = leaf.subLabel {
            ctx.draw(Text(sub).font(.system(size: 10.5)).italic().foregroundColor(sc), at: CGPoint(x: c.x, y: y0 + Double(lines.count + 1) * 12.5))
        }
    }
}

/// The hover card: same fields and order as the SVG render (`HoverCard.lines`).
struct HoverCardView: View {
    let card: HoverCard
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: LeafPalette.dot(card.status))).frame(width: 7, height: 7)
                Text(card.branch).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                Text("· " + card.status.word).font(.system(size: 12)).foregroundColor(Theme.ink2)
            }
            Group {
                Text(card.repo)
                Text(card.path).font(.system(size: 10.5)).truncationMode(.middle)
                Text(card.lastCommit)
                Text(card.tracking)
                Text(card.uncommitted)
                Text(card.size)
            }
            .font(.system(size: 11)).foregroundColor(Theme.ink2).lineLimit(1)
            Text(card.action).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.ink).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: LeafPalette.cardFill)).shadow(color: .black.opacity(0.1), radius: 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: LeafPalette.cardStroke), lineWidth: 0.8))
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
