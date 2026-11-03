#if os(macOS)
import DevspaceCore
import SwiftUI

/// Organic blobs sized by bytes; Free is drawn as nested contour lines.
struct BlobView: View {
    let result: ScanResult

    var body: some View {
        Canvas { ctx, size in
            let blobs = BlobLayout.layout(BlobLayout.items(from: result), width: size.width, height: size.height)
            var projectIndex = 0
            for (i, b) in blobs.enumerated() {
                let seed = abs(b.id.hashValue)
                if b.kind == .free {
                    for k in 0..<6 {
                        let rr = b.r * (1 - Double(k) * 0.15)
                        ctx.stroke(path(b, r: rr, seed: seed), with: .color(Theme.ink3.opacity(0.9 - Double(k) * 0.1)), lineWidth: 1)
                    }
                } else {
                    let fill: Color
                    switch b.kind {
                    case .project: fill = Theme.projectShades[min(projectIndex, Theme.projectShades.count - 1)]; projectIndex += 1
                    case .rebuildable: fill = Theme.rebuildable
                    default: fill = Theme.caches
                    }
                    ctx.fill(path(b, r: b.r, seed: seed &+ i), with: .color(fill))
                }
                guard b.r > 26 else { continue }
                let dark = b.kind == .project && projectIndex <= 4
                let color = dark ? Theme.paper : Theme.ink
                ctx.draw(Text(b.label).font(.system(size: 11, weight: .medium)).foregroundColor(color),
                         at: CGPoint(x: b.x, y: b.y - 7))
                ctx.draw(Text(Format.bytes(b.bytes)).font(.system(size: 11)).foregroundColor(color.opacity(0.75)),
                         at: CGPoint(x: b.x, y: b.y + 8))
            }
        }
        .accessibilityLabel("Space map: projects, rebuildable files, caches and free space, sized by bytes")
    }

    private func path(_ b: Blob, r: Double, seed: Int) -> Path {
        let pts = BlobLayout.outline(cx: b.x, cy: b.y, r: r, seed: seed)
        var p = Path()
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }
}
#endif
