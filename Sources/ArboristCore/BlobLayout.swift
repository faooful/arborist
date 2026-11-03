import Foundation

/// Pure geometry for the app's blob view, kept in Core so it is unit-tested on Linux.
public struct Blob: Equatable, Sendable {
    public var id: String
    public var label: String
    public var bytes: Int64
    public var kind: Kind
    public var x: Double, y: Double, r: Double
    public enum Kind: String, Sendable { case project, rebuildable, caches, free }
}

public enum BlobLayout {
    /// Area is proportional to bytes. Places largest first, each new blob at the first spot on an
    /// outward spiral that doesn't overlap, then scales everything to fit `width` x `height`.
    public static func layout(_ items: [(id: String, label: String, bytes: Int64, kind: Blob.Kind)],
                              width: Double, height: Double, gap: Double = 0.04) -> [Blob] {
        let sorted = items.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
        guard let maxBytes = sorted.first?.bytes else { return [] }
        var placed: [Blob] = []
        for it in sorted {
            let r = max(0.12, (Double(it.bytes) / Double(maxBytes)).squareRoot())
            var b = Blob(id: it.id, label: it.label, bytes: it.bytes, kind: it.kind, x: 0, y: 0, r: r)
            if !placed.isEmpty {
                var t = 0.0
                while true {
                    let d = 0.05 * t
                    b.x = d * cos(t) * 1.4; b.y = d * sin(t) // wider than tall
                    if placed.allSatisfy({ hypot($0.x - b.x, $0.y - b.y) >= $0.r + b.r + gap }) { break }
                    t += 0.1
                }
            }
            placed.append(b)
        }
        // Fit to the canvas.
        let minX = placed.map { $0.x - $0.r }.min()!, maxX = placed.map { $0.x + $0.r }.max()!
        let minY = placed.map { $0.y - $0.r }.min()!, maxY = placed.map { $0.y + $0.r }.max()!
        let s = min(width / (maxX - minX), height / (maxY - minY))
        let ox = (width - (maxX - minX) * s) / 2, oy = (height - (maxY - minY) * s) / 2
        return placed.map { var b = $0; b.x = ox + (b.x - minX) * s; b.y = oy + (b.y - minY) * s; b.r *= s; return b }
    }

    /// Closed outline for an organic blob: a circle wobbled by two low harmonics seeded by `seed`.
    public static func outline(cx: Double, cy: Double, r: Double, seed: Int, points: Int = 96, wobble: Double = 0.07) -> [(Double, Double)] {
        let s = Double(seed % 997) * 0.37
        return (0..<points).map { i in
            let a = Double(i) / Double(points) * 2 * .pi
            let k = 1 + wobble * sin(3 * a + s) + wobble * 0.6 * sin(5 * a + 2.3 * s)
            return (cx + r * k * cos(a), cy + r * k * sin(a))
        }
    }

    /// Items for the blob view: top projects by source size, one rebuildable blob, one caches blob, and free space.
    public static func items(from r: ScanResult, maxProjects: Int = 7) -> [(id: String, label: String, bytes: Int64, kind: Blob.Kind)] {
        var out: [(id: String, label: String, bytes: Int64, kind: Blob.Kind)] = []
        let byTotal = r.repos.sorted { $0.size.source > $1.size.source }
        for repo in byTotal.prefix(maxProjects) { out.append((repo.path, repo.name, repo.size.source, .project)) }
        let rest = byTotal.dropFirst(maxProjects).reduce(Int64(0)) { $0 + $1.size.source }
        if rest > 0 { out.append(("other", "Other projects", rest, .project)) }
        let t = r.totals
        out.append(("rebuildable", "Rebuildable", t.projectsRebuildable, .rebuildable))
        out.append(("caches", "Caches", t.caches, .caches))
        if let v = r.volume { out.append(("free", "Free", v.freeBytes, .free)) }
        return out
    }
}
