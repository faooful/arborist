import Foundation

/// 2D point for the leaf layout. Plain doubles so it builds and tests on Linux.
public struct Pt: Equatable, Hashable, Sendable {
    public var x: Double, y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static func + (a: Pt, b: Pt) -> Pt { Pt(a.x + b.x, a.y + b.y) }
    static func - (a: Pt, b: Pt) -> Pt { Pt(a.x - b.x, a.y - b.y) }
    static func * (a: Pt, k: Double) -> Pt { Pt(a.x * k, a.y * k) }
    func dot(_ b: Pt) -> Double { x * b.x + y * b.y }
    var length: Double { (x * x + y * y).squareRoot() }
}

/// Seeded PRNG matching h8.js's Park–Miller generator (`s = s*16807 % 2147483647`).
struct ParkMiller {
    var s: Int64
    init(_ seed: Int64) { s = max(1, seed % 2147483647) }
    mutating func next() -> Double { s = (s * 16807) % 2147483647; return Double(s) / 2147483647 }
}

public enum Geo {
    static func signedArea(_ p: [Pt]) -> Double {
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in p.indices { let q = p[(i + 1) % p.count]; a += p[i].x * q.y - q.x * p[i].y }
        return a / 2
    }
    static func area(_ p: [Pt]) -> Double { abs(signedArea(p)) }

    static func centroid(_ p: [Pt]) -> Pt {
        let a = signedArea(p)
        guard abs(a) > 1e-9 else {
            let n = Double(max(p.count, 1))
            return Pt(p.reduce(0) { $0 + $1.x } / n, p.reduce(0) { $0 + $1.y } / n)
        }
        var cx = 0.0, cy = 0.0
        for i in p.indices {
            let q = p[(i + 1) % p.count], k = p[i].x * q.y - q.x * p[i].y
            cx += (p[i].x + q.x) * k; cy += (p[i].y + q.y) * k
        }
        return Pt(cx / (6 * a), cy / (6 * a))
    }

    /// Keeps the part of convex polygon `q` where `(p - o)·n >= 0`.
    static func clipHalf(_ q: [Pt], o: Pt, n: Pt) -> [Pt] {
        var out: [Pt] = []
        for i in q.indices {
            let p = q[i], r = q[(i + 1) % q.count]
            let dp = (p - o).dot(n), dr = (r - o).dot(n)
            if dp >= 0 { out.append(p) }
            if (dp >= 0) != (dr >= 0) { let t = dp / (dp - dr); out.append(p + (r - p) * t) }
        }
        return out
    }

    /// Inward unit normals of each edge of a convex polygon (decided via the centroid, like h8.js).
    static func inwardEdges(_ p: [Pt]) -> [(Pt, Pt)] {
        let c = centroid(p)
        var out: [(Pt, Pt)] = []
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count], e = b - a, l = e.length
            guard l > 1e-6 else { continue }
            var n = Pt(e.y / l, -e.x / l)
            if (c - a).dot(n) < 0 { n = n * -1 }
            out.append((a, n))
        }
        return out
    }

    /// Shrinks a convex polygon by `d`.
    static func inset(_ p: [Pt], _ d: Double) -> [Pt] {
        var q = p
        for (a, n) in inwardEdges(p) { q = clipHalf(q, o: a + n * d, n: n); if q.count < 3 { return [] } }
        return q
    }

    static func clip(_ p: [Pt], to convex: [Pt]) -> [Pt] {
        var q = p
        for (a, n) in inwardEdges(convex) { q = clipHalf(q, o: a, n: n); if q.count < 3 { return [] } }
        return q
    }

    static func chaikin(_ p: [Pt], _ it: Int = 3) -> [Pt] {
        var p = p
        for _ in 0..<it {
            var o: [Pt] = []
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                o.append(a * 0.75 + b * 0.25); o.append(a * 0.25 + b * 0.75)
            }
            p = o
        }
        return p
    }

    static func resample(_ p: [Pt], _ n: Int) -> [Pt] {
        var segs: [(Pt, Pt, Double)] = []
        var total = 0.0
        for i in p.indices { let a = p[i], b = p[(i + 1) % p.count], l = (b - a).length; segs.append((a, b, l)); total += l }
        guard total > 0 else { return p }
        var o: [Pt] = [], si = 0, acc = 0.0
        for k in 0..<n {
            let t = Double(k) / Double(n) * total
            while si < segs.count - 1 && acc + segs[si].2 < t { acc += segs[si].2; si += 1 }
            let (a, b, l) = segs[si]
            o.append(l > 0 ? a + (b - a) * ((t - acc) / l) : a)
        }
        return o
    }

    /// Bows each straight edge slightly outward so cells read as organic.
    static func bowOut(_ p: [Pt]) -> [Pt] {
        let c = centroid(p)
        var o: [Pt] = []
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count], e = b - a, l = e.length
            guard l >= 0.5 else { continue }
            var n = Pt(e.y / l, -e.x / l)
            if (c - a).dot(n) > 0 { n = n * -1 }
            let k = min(0.5, l * 0.015), m = l > 14 ? 2 : 1
            for j in 0..<m { let t = Double(j) / Double(m); o.append(a + e * t + n * (k * sin(.pi * t))) }
        }
        return o
    }

    public static func bbox(_ p: [Pt]) -> (Double, Double, Double, Double) {
        (p.map(\.x).min() ?? 0, p.map(\.y).min() ?? 0, p.map(\.x).max() ?? 0, p.map(\.y).max() ?? 0)
    }

    static func inside(_ p: [Pt], _ q: Pt) -> Bool {
        var c = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y) && q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// Horizontal width of polygon at height y.
    static func chord(_ p: [Pt], y: Double) -> Double {
        var xs: [Double] = []
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            if (a.y > y) != (b.y > y) { xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y)) }
        }
        return xs.count >= 2 ? xs.max()! - xs.min()! : 0
    }
}
