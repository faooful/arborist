#if os(macOS)
import ArboristCore
import SwiftUI

/// Draws the H8 leaf map from `LeafLayout` geometry. Tap a leaf to select it.
struct LeafMapView: View {
    let map: LeafMap
    let freeBytes: Int64
    @Binding var selection: LeafItem?

    var body: some View {
        Canvas { ctx, _ in
            for leaf in map.leaves { draw(leaf, in: &ctx) }
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
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { p in
            selection = map.leaf(at: Pt(p.x, p.y))?.item
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leaf map of disk use: \(map.leaves.count) leaves, \(map.staleCount) stale. The list below has every item.")
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
        let selected = selection?.id == leaf.item.id
        ctx.fill(shape, with: .color(Color(hex: LeafPalette.fill(st))))
        if leaf.item.kind == .free {
            for q in map.stipple {
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 0.7, y: q.y - 0.7, width: 1.4, height: 1.4)), with: .color(Color(hex: LeafPalette.stipple)))
            }
            label(["Free"], Format.bytes(freeBytes), at: leaf.centroid, dark: false, in: &ctx)
            return
        }
        if st == .stale { ctx.stroke(shape, with: .color(Color(hex: LeafPalette.staleStroke)), lineWidth: 0.4) }
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
        if selected { ctx.stroke(shape, with: .color(Theme.ink), lineWidth: 1.5) }
        label(leaf.labelLines, leaf.showSize ? Format.bytes(leaf.item.bytes) : nil, at: leaf.centroid, dark: LeafPalette.isDark(st), in: &ctx)
    }

    private func label(_ lines: [String], _ size: String?, at c: Pt, dark: Bool, in ctx: inout GraphicsContext) {
        let lc = dark ? Color(hex: LeafPalette.labelOnDark) : Color(hex: "#1c1e21")
        let sc = dark ? Color(hex: LeafPalette.sizeOnDark) : Color(hex: LeafPalette.sizeOnLight)
        let y0 = c.y - Double(lines.count) * 12.5 / 2 + 2
        for (i, line) in lines.enumerated() {
            ctx.draw(Text(line).font(.system(size: 10.5, weight: .medium)).foregroundColor(lc), at: CGPoint(x: c.x, y: y0 + Double(i) * 12.5))
        }
        if let size {
            let y = lines.isEmpty ? c.y : y0 + Double(lines.count) * 12.5
            ctx.draw(Text(size).font(.system(size: 10.5)).foregroundColor(sc), at: CGPoint(x: c.x, y: y))
        }
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
