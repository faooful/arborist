import Foundation

/// Leaf kinds (shape) from design H8.
public enum LeafKind: String, Codable, Sendable { case worktree, main, cache, app, deps, free }
/// Leaf states (colour) from design H8.
public enum LeafState: String, Codable, Sendable {
    case protected // uncommitted or unpushed work: moss
    case clean     // sage
    case stale     // dried-leaf tan
    case deps      // rebuildable
    case free
}

public struct LeafItem: Equatable, Sendable {
    public var id: String
    public var name: String
    public var bytes: Int64
    public var kind: LeafKind
    public var state: LeafState
    public var path: String?
    public var removeCommand: String?
    /// Number of real items folded into this one (0 for ordinary leaves).
    public var foldedCount: Int = 0
    public init(id: String, name: String, bytes: Int64, kind: LeafKind, state: LeafState, path: String? = nil, removeCommand: String? = nil) {
        self.id = id; self.name = name; self.bytes = bytes; self.kind = kind; self.state = state; self.path = path; self.removeCommand = removeCommand
    }
}

public struct LeafGroup: Equatable, Sendable {
    public var name: String
    public var items: [LeafItem]
    public var isFree: Bool { items.first?.kind == .free }
    public init(name: String, items: [LeafItem]) { self.name = name; self.items = items }
}

/// Quadratic vein stroke.
public struct Vein: Equatable, Sendable {
    public var p0: Pt, c: Pt, p1: Pt
    public var width: Double, opacity: Double
}

public struct Leaf: Equatable, Sendable {
    public var item: LeafItem
    public var group: String
    public var outline: [Pt]
    public var veins: [Vein]
    public var centroid: Pt
    /// Label lines to draw inside the leaf (empty when it doesn't fit).
    public var labelLines: [String]
    public var showSize: Bool
}

public struct GroupLabel: Equatable, Sendable {
    public var name: String
    public var at: Pt
    public var vertical: Bool
}

public struct LeafMap: Equatable, Sendable {
    public var width: Double, height: Double
    public var leaves: [Leaf]
    public var groupLabels: [GroupLabel]
    public var stipple: [Pt]
    public var staleCount: Int

    public func leaf(at p: Pt) -> Leaf? { leaves.first { Geo.inside($0.outline, p) } }
}

public enum LeafLayout {
    public static let defaultSeed = "arborist"
    /// Minimum leaf edge in points: a leaf's share is at least `minLeaf²` of map area.
    public static let minLeaf = 28.0

    // MARK: Data -> groups

    /// One group per repo (largest first, the rest folded into "other repos"), a Caches group, and Free.
    public static func groups(from r: ScanResult, maxRepos: Int = 5) -> [LeafGroup] {
        var out: [LeafGroup] = []
        func repoItems(_ repo: Repo) -> [LeafItem] {
            var items: [LeafItem] = repo.worktrees.map { w in
                let state: LeafState = w.stale ? .stale : (w.dirty || (w.unpushedCommits ?? 0) > 0 ? .protected : .clean)
                return LeafItem(id: w.path, name: w.isMain ? "main" : (w.branch ?? "detached"), bytes: w.size.source,
                                kind: w.isMain ? .main : .worktree, state: state, path: w.path, removeCommand: w.removeCommand)
            }
            if repo.size.rebuildable > 0 {
                items.append(LeafItem(id: repo.path + "#deps", name: "deps", bytes: repo.size.rebuildable, kind: .deps, state: .deps, path: repo.path))
            }
            return items
        }
        let repos = r.repos.sorted { $0.size.total > $1.size.total }
        for repo in repos.prefix(maxRepos) { out.append(LeafGroup(name: repo.name, items: repoItems(repo))) }
        let rest = repos.dropFirst(maxRepos)
        if !rest.isEmpty {
            out.append(LeafGroup(name: "other repos", items: rest.map { repo in
                let protected = repo.worktrees.contains { $0.dirty || ($0.unpushedCommits ?? 0) > 0 }
                return LeafItem(id: repo.path, name: repo.name, bytes: repo.size.total, kind: .main, state: protected ? .protected : .clean, path: repo.path)
            }))
        }
        if !r.caches.isEmpty {
            out.append(LeafGroup(name: "Caches", items: r.caches.map {
                LeafItem(id: "cache:" + $0.name, name: $0.name, bytes: $0.bytes, kind: .cache, state: .clean, path: $0.path)
            }))
        }
        if let v = r.volume {
            // Free is drawn smaller than its true size (as in H8) so a mostly-empty disk still shows the leaves.
            let used = out.flatMap(\.items).reduce(Int64(0)) { $0 + $1.bytes }
            let shown = used > 0 ? min(v.freeBytes, used * 2 / 3) : v.freeBytes
            var free = LeafItem(id: "free", name: "Free", bytes: shown, kind: .free, state: .free)
            free.foldedCount = 0
            out.append(LeafGroup(name: "free", items: [free]))
        }
        return out.filter { !$0.items.isEmpty }
    }

    // MARK: Folding

    /// Smallest byte value that still gets its own leaf, for a map of `width` x `height`.
    public static func minBytes(total: Int64, width: Double, height: Double, minLeaf: Double = minLeaf) -> Int64 {
        Int64((Double(total) * minLeaf * minLeaf / (width * height * 0.82)).rounded(.up))
    }

    /// Items below `minBytes` are folded into one "other" leaf per group; a lone tiny item is padded up to the minimum.
    public static func fold(_ groups: [LeafGroup], minBytes: Int64) -> [LeafGroup] {
        groups.map { g in
            var g = g
            let small = g.items.filter { $0.bytes < minBytes }
            guard !small.isEmpty else { return g }
            if small.count == 1 {
                g.items = g.items.map { var i = $0; if i.bytes < minBytes { i.bytes = minBytes }; return i }
                return g
            }
            g.items = g.items.filter { $0.bytes >= minBytes }
            let state: LeafState = small.contains { $0.state == .protected } ? .protected
                : (small.allSatisfy { $0.state == .stale } ? .stale : .clean)
            var other = LeafItem(id: g.name + "#other", name: "other", bytes: max(minBytes, small.reduce(0) { $0 + $1.bytes }), kind: .main, state: state)
            other.foldedCount = small.count
            g.items.append(other)
            return g
        }
    }

    // MARK: Layout

    public static func layout(_ input: [LeafGroup], width: Double = 448, height: Double = 400,
                              seed: String = defaultSeed, staleCount: Int? = nil) -> LeafMap {
        let marginX = 14.0, marginY = 15.0
        let total = input.flatMap(\.items).reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return LeafMap(width: width, height: height, leaves: [], groupLabels: [], stipple: [], staleCount: 0) }
        let groups = fold(input, minBytes: minBytes(total: total, width: width, height: height)).filter { !$0.items.isEmpty }

        // Organic outer boundary: a convex superellipse.
        let w = width - marginX, h = height
        var outer: [Pt] = []
        for i in 0..<72 {
            let a = Double(i) / 72 * 2 * .pi, c = cos(a), s = sin(a), e = 0.28
            outer.append(Pt(marginX + w / 2 + (w / 2 - 1) * sgn(c) * pow(abs(c), e),
                            h / 2 + (h / 2 - marginY) * sgn(s) * pow(abs(s), e)))
        }
        var rng = PowerTreemap.Rng(seed: seed)
        let groupCells = PowerTreemap.split(values: groups.map { Double($0.items.reduce(0) { $0 + $1.bytes }) }, clip: outer, rng: &rng)

        var leaves: [Leaf] = [], labels: [GroupLabel] = [], stipple: [Pt] = []
        var cid = 0
        for (gi, g) in groups.enumerated() {
            let gpoly = groupCells[gi]
            guard gpoly.count >= 3 else { continue }
            let gp = Geo.inset(gpoly, 2.6)
            guard gp.count >= 3 else { continue }
            if !g.isFree { labels.append(groupLabel(g.name, gp, height: height)) }
            let cells = PowerTreemap.split(values: g.items.map { Double($0.bytes) }, clip: gpoly, rng: &rng)
            for (ii, item) in g.items.enumerated() {
                var p = Geo.inset(cells[ii], 2.0)
                guard p.count >= 3 else { continue }
                p = Geo.clip(p, to: gp)
                guard p.count >= 3 else { continue }
                if item.kind == .free {
                    let r = Geo.resample(Geo.chaikin(Geo.bowOut(p), 4), 120)
                    let outline = wavy(Geo.resample(r, 240), kind: .free, cid: cid)
                    var s: Int64 = 11
                    let (x0, y0, x1, y1) = Geo.bbox(p), inner = Geo.inset(p, 6)
                    for _ in 0..<60 {
                        s = (s * 16807) % 2147483647; let rx = Double(s) / 2147483647
                        s = (s * 16807) % 2147483647; let ry = Double(s) / 2147483647
                        let q = Pt(x0 + rx * (x1 - x0), y0 + ry * (y1 - y0))
                        if inner.count >= 3 && Geo.inside(inner, q) { stipple.append(q) }
                    }
                    leaves.append(Leaf(item: item, group: g.name, outline: outline, veins: [], centroid: Geo.centroid(p), labelLines: ["Free"], showSize: true))
                    continue
                }
                cid += 1
                leaves.append(shapeLeaf(item, group: g.name, cell: p, cid: cid, mapCentre: Pt(width / 2, height / 2)))
            }
        }
        let stale = staleCount ?? groups.flatMap(\.items).reduce(0) { $0 + ($1.state == .stale ? max(1, $1.foldedCount) : 0) }
        return LeafMap(width: width, height: height, leaves: leaves, groupLabels: labels, stipple: stipple, staleCount: stale)
    }

    static func sgn(_ v: Double) -> Double { v < 0 ? -1 : (v > 0 ? 1 : 0) }

    static func groupLabel(_ name: String, _ gp: [Pt], height: Double) -> GroupLabel {
        let ys = gp.map(\.y), mnY = ys.min()!, mxY = ys.max()!
        let top = mnY < 22, bottom = mxY > height - 22
        if top || bottom {
            let edge = top ? mnY : mxY
            let pts = gp.filter { abs($0.y - edge) < 6 }
            let x = pts.reduce(0) { $0 + $1.x } / Double(max(pts.count, 1))
            return GroupLabel(name: name, at: Pt(x, top ? 10 : height - 3), vertical: false)
        }
        return GroupLabel(name: name, at: Pt(7, (mnY + mxY) / 2), vertical: true)
    }

    // MARK: Leaf shaping (port of h8.js)

    static func shapeLeaf(_ item: LeafItem, group: String, cell p: [Pt], cid: Int, mapCentre: Pt) -> Leaf {
        let gb = Double(item.bytes) / 1e9
        var kind = item.kind
        if kind == .deps && gb < 2 { kind = .main }
        let r = Geo.resample(Geo.chaikin(Geo.bowOut(p), gb < 2 ? 3 : 4), 200)
        var ai = 0, bi = 0, best = 0.0
        var i = 0
        while i < r.count {
            var j = i + 1
            while j < r.count { let l = (r[i] - r[j]).length; if l > best { best = l; ai = i; bi = j }; j += 3 }
            i += 3
        }
        var a = r[ai], b = r[bi]
        if kind == .cache && (a - mapCentre).length > (b - mapCentre).length { swap(&a, &b) }
        let axis = b - a, lx = max(axis.length, 1e-6), dir = axis * (1 / lx), perp = Pt(-dir.y, dir.x)
        let half = max(r.map { abs(($0 - a).dot(perp)) }.max() ?? 1, 1e-6)
        let s: [Pt] = r.map { p in
            let pr = (p - a).dot(dir), u = 2 * pr / lx - 1, ap = a + dir * pr, off = p - ap, pd = off.dot(perp) / half
            var g = 1.0, shift = 0.0
            switch kind {
            case .worktree: g = 1 - 0.62 * pow(abs(u), 4)
            case .app:
                if u > 0 { g = 1 - 0.8 * pow(u, 5) } else { shift = max(0, 1 - abs(pd) / 0.6) * max(0, (-u - 0.4) / 0.6) * 0.3 * lx }
            case .cache:
                if u < 0 { g = 1 - 0.4 * pow(-u, 2.2) } else { shift = -max(0, 1 - abs(pd) / 0.35) * max(0, (u - 0.7) / 0.3) * 0.07 * lx }
            case .deps:
                g = (1 - 0.16 * (0.5 - 0.5 * cos(2 * .pi * 3.5 * (u + 1) / 2))) * (1 - 0.25 * pow(abs(u), 6))
            default: break
            }
            return ap + off * max(0, g) + dir * shift
        }
        let outline = wavy(s, kind: kind, cid: cid).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let veins = makeVeins(kind: kind, a: a, dir: dir, perp: perp, lx: lx, half: half, shape: s, cid: cid)

        // Label: wrap long names at - and /, like h8.js; fall back to size only, then nothing.
        let c = Geo.centroid(s)
        let name = item.foldedCount > 0 ? "other (\(item.foldedCount))" : item.name
        var parts = [name]
        if name.count > 9 {
            parts = []
            var cur = ""
            for ch in name {
                cur.append(ch)
                if ch == "-" || ch == "/" {
                    if let last = parts.last, (last + cur).count <= 10 { parts[parts.count - 1] = last + cur } else { parts.append(cur) }
                    cur = ""
                }
            }
            if !cur.isEmpty { if let last = parts.last, (last + cur).count <= 10 { parts[parts.count - 1] = last + cur } else { parts.append(cur) } }
        }
        let lw = Double(parts.map(\.count).max() ?? 0) * 6 + 6, lh = Double(parts.count) * 12.5, y0 = c.y - lh / 2 + 2
        var fits = true
        for k in 0...parts.count where Geo.chord(s, y: y0 + Double(k) * 12.5 - 4) < (k < parts.count ? lw : 30) { fits = false }
        let chord = Geo.chord(s, y: c.y)
        return Leaf(item: item, group: group, outline: outline, veins: veins, centroid: c,
                    labelLines: fits ? parts : [], showSize: fits || chord > 26)
    }

    static func wavy(_ s: [Pt], kind: LeafKind, cid: Int) -> [Pt] {
        var rng = ParkMiller(4242 + Int64(cid) * 104729)
        let n = s.count, c = Geo.centroid(s)
        var cum = [0.0]
        for i in 1..<n { cum.append(cum[i - 1] + (s[i] - s[i - 1]).length) }
        let total = cum[n - 1] + (s[0] - s[n - 1]).length
        let nw = max(3, (total / (24 + rng.next() * 12)).rounded()), ph = rng.next() * 6.283, amp = 1.55 + rng.next() * 0.35
        let k = 2 + floor(rng.next() * 3), ph2 = rng.next() * 6.283
        let ser = kind == .deps ? 0.3 : (kind == .worktree && rng.next() < 0.4 ? 0.15 : 0), ns = kind == .deps ? 40.0 : 60.0
        let o: [Pt] = s.indices.map { i in
            let t = cum[i] / total * 6.283, e = s[(i + 1) % n] - s[(i - 1 + n) % n], l = max(e.length, 1e-9)
            var nn = Pt(e.y / l, -e.x / l)
            if (c - s[i]).dot(nn) < 0 { nn = nn * -1 }
            let w = amp * (0.72 * sin(nw * t + ph) + 0.28 * sin(k * t + ph2)) + ser * sin(ns * t)
            return s[i] + nn * w
        }
        return Geo.chaikin(o, kind == .cache ? 3 : 1)
    }

    static func makeVeins(kind: LeafKind, a: Pt, dir: Pt, perp: Pt, lx: Double, half: Double, shape s: [Pt], cid: Int) -> [Vein] {
        var rng = ParkMiller(1000 + Int64(cid) * 7919)
        func at(_ t: Double) -> Pt { a + dir * (t * lx) }
        func width(_ t: Double) -> Double {
            var m = 0.0
            for p in s { let pr = (p - a).dot(dir) / lx; if abs(pr - t) < 0.03 { m = max(m, abs((p - (a + dir * (pr * lx))).dot(perp))) } }
            return m
        }
        let bow = (rng.next() - 0.5) * 0.06 * lx
        func mid(_ t: Double) -> Pt { at(t) + perp * (bow * 4 * t * (1 - t)) }
        func avg(_ p: Pt, _ q: Pt) -> Pt { (p + q) * 0.5 }
        var v: [Vein] = []
        if kind == .cache {
            let st0 = at(0.05)
            for i in 0..<6 {
                let tt = -0.78 + 1.56 * Double(i) / 5 + (rng.next() - 0.5) * 0.08
                let end = at(0.8 + rng.next() * 0.08) + perp * (tt * half * 0.85), fk = st0 + (end - st0) * 0.55
                v.append(Vein(p0: st0, c: avg(st0, fk) + perp * (tt * 3), p1: fk, width: 0.5, opacity: 0.9))
                for sg in [-1.0, 1.0] {
                    let e2 = end + perp * (sg * half * 0.07)
                    v.append(Vein(p0: fk, c: avg(fk, e2) + perp * (sg * 1.5), p1: e2, width: 0.32, opacity: 0.6))
                }
            }
            return v
        }
        let t0 = kind == .app ? 0.2 : 0.04, t1 = 0.95
        for i in 0..<4 {
            let ta = t0 + (t1 - t0) * Double(i) / 4, tb = t0 + (t1 - t0) * Double(i + 1) / 4
            v.append(Vein(p0: mid(ta), c: mid((ta + tb) / 2), p1: mid(tb), width: 0.8 - 0.5 * Double(i) / 3, opacity: 0.95))
        }
        let n = max(3, min(9, Int(lx / (kind == .deps ? 22 : 16))))
        var side = rng.next() < 0.5 ? 1.0 : -1.0
        for i in 1...n {
            let t = (Double(i) - 0.3 + rng.next() * 0.6) / (Double(n) + 0.5)
            if t < 0.08 || t > 0.9 { continue }
            let w = width(t) * (0.55 + rng.next() * 0.2), p0 = mid(t)
            let fw = kind == .deps ? 0.1 : (kind == .main ? 0.12 : 0.18) + rng.next() * 0.06
            let end = at(min(0.97, t + fw)) + perp * (side * w), c1 = at(t + fw * 0.25) + perp * (side * w * 0.55)
            let m1 = avg(p0, end) + (c1 - avg(p0, end)) * 0.5
            v.append(Vein(p0: p0, c: avg(p0, m1) + perp * (side * w * 0.08), p1: m1, width: 0.45, opacity: 1))
            v.append(Vein(p0: m1, c: avg(m1, end) + perp * (side * w * 0.06), p1: end, width: 0.3, opacity: 0.7))
            side = -side
        }
        return v
    }
}
