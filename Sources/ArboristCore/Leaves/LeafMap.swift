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
    /// Share of the map this item asks for. Defaults to `bytes`; worktree leaves use `LeafLayout.weight` (D12).
    public var weight: Double
    /// Rebuildable part of `bytes`, drawn as a shaded inner leaf (D12).
    public var rebuildableBytes: Int64 = 0
    /// Repo name, shown as the small second label line.
    public var repo: String?
    public var status: WorktreeStatus?
    public init(id: String, name: String, bytes: Int64, kind: LeafKind, state: LeafState, path: String? = nil, removeCommand: String? = nil) {
        self.id = id; self.name = name; self.bytes = bytes; self.kind = kind; self.state = state; self.path = path; self.removeCommand = removeCommand
        self.weight = Double(bytes)
    }
    /// Fraction of the leaf drawn as rebuildable, 0…0.9.
    public var rebuildableShare: Double {
        bytes > 0 ? min(0.9, max(0, Double(rebuildableBytes) / Double(bytes))) : 0
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
    /// Rebuildable share: the outline shrunk about its centroid to that share of the area (empty when none).
    public var inner: [Pt] = []
    /// Small second line (the repo), when it fits.
    public var subLabel: String?
}

public struct GroupLabel: Equatable, Sendable {
    public var name: String
    /// Text anchor: horizontal centre, baseline.
    public var at: Pt
    /// Always false since D13 (rotated side labels were removed); kept for source compatibility.
    public var vertical: Bool = false
    /// The box the text occupies, used for collision checks.
    public var rect: Rect { let w = LeafText.width(name, size: LeafText.groupSize); return Rect(x: at.x - w / 2, y: at.y - 10, w: w, h: 13) }
}

public struct Rect: Equatable, Sendable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public func intersects(_ o: Rect, gap: Double = 0) -> Bool {
        x < o.x + o.w + gap && o.x < x + w + gap && y < o.y + o.h + gap && o.y < y + h + gap
    }
    public func inside(width: Double, height: Double) -> Bool { x >= 0 && y >= 0 && x + w <= width && y + h <= height }
}

/// Text measurement for fit checks (D13). An estimate of SF Pro/Inter advance widths, a little generous so
/// "fits" is never optimistic.
public enum LeafText {
    /// Horizontal padding each side of a leaf label.
    public static let pad = 5.0
    /// True when `text` at `leafSize` fits inside the polygon centred on `c`.
    public static func fits(_ text: String, in poly: [Pt], at c: Pt, size: Double = leafSize) -> Bool {
        let w = width(text, size: size) + 2 * pad
        return [-size * 0.55, 0, size * 0.45].allSatisfy { Geo.chord(poly, y: c.y + $0) >= w }
    }
    public static let leafSize = 10.5
    public static let groupSize = 10.5
    public static func width(_ s: String, size: Double, weight medium: Bool = true) -> Double {
        var w = 0.0
        for ch in s {
            switch ch {
            case "i", "l", "j", ".", ",", ":", ";", "'", "|", "!", "I": w += 0.30
            case "f", "t", "r", "/", "-", "(", ")", " ": w += 0.38
            case "m", "w", "M", "W": w += 0.88
            case "A"..."Z", "_": w += 0.68
            default: w += 0.57
            }
        }
        return w * size * (medium ? 1.03 : 1.0)
    }
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

    /// Worktree-first (D12): one group per repo, one leaf per worktree including the main checkout.
    /// Repos with the most worktrees come first. Caches and free space are not leaves.
    public static func groups(from r: ScanResult) -> [LeafGroup] {
        let repos = r.repos.filter { !$0.worktrees.isEmpty }.sorted {
            $0.worktrees.count != $1.worktrees.count ? $0.worktrees.count > $1.worktrees.count : $0.size.total > $1.size.total
        }
        return repos.map { repo in
            LeafGroup(name: repo.name, items: repo.worktrees.map { item(for: $0, repo: repo.name) })
        }
    }

    public static func item(for w: Worktree, repo: String) -> LeafItem {
        let st = w.status
        let state: LeafState = (st == .uncommitted || st == .unpushed) ? .protected : (st == .clean ? .clean : .stale)
        var i = LeafItem(id: w.path, name: WorktreeLabel.branchName(w.branch, head: w.head), bytes: w.size.total,
                         kind: w.isMain ? .main : .worktree, state: state, path: w.path, removeCommand: w.removeCommand)
        i.rebuildableBytes = w.size.rebuildable
        i.repo = repo
        i.status = st
        i.weight = weight(bytes: w.size.total)
        return i
    }

    /// Leaf area for a worktree: grows with the square root of its size, from a floor, so a 20 GB
    /// checkout is bigger than a 50 MB worktree but every worktree stays visible.
    public static func weight(bytes: Int64) -> Double { 0.6 + (Double(max(0, bytes)) / 1e9).squareRoot() }

    // MARK: Folding

    /// Smallest byte value that still gets its own leaf, for a map of `width` x `height`.
    public static func minBytes(total: Int64, width: Double, height: Double, minLeaf: Double = minLeaf) -> Int64 {
        Int64((Double(total) * minLeaf * minLeaf / (width * height * 0.82)).rounded(.up))
    }

    /// Items below `minBytes` are folded into one "other" leaf per group; a lone tiny item is padded up to the minimum.
    public static func fold(_ groups: [LeafGroup], minBytes: Int64) -> [LeafGroup] { fold(groups, minWeight: Double(minBytes)) }

    /// Same as `fold(_:minBytes:)`, on `weight`.
    public static func fold(_ groups: [LeafGroup], minWeight: Double) -> [LeafGroup] {
        groups.map { g in
            var g = g
            let small = g.items.filter { $0.weight < minWeight }
            guard !small.isEmpty else { return g }
            if small.count == 1 {
                g.items = g.items.map { var i = $0; if i.weight < minWeight { i.weight = minWeight }; return i }
                return g
            }
            g.items = g.items.filter { $0.weight >= minWeight }
            let state: LeafState = small.contains { $0.state == .protected } ? .protected
                : (small.allSatisfy { $0.state == .stale } ? .stale : .clean)
            var other = LeafItem(id: g.name + "#other", name: "other", bytes: small.reduce(0) { $0 + $1.bytes }, kind: .main, state: state)
            other.weight = max(minWeight, small.reduce(0) { $0 + $1.weight })
            other.rebuildableBytes = small.reduce(0) { $0 + $1.rebuildableBytes }
            other.repo = small.first?.repo
            other.foldedCount = small.count
            g.items.append(other)
            return g
        }
    }

    // MARK: Layout

    public static func layout(_ input: [LeafGroup], width: Double = 448, height: Double = 400,
                              seed: String = defaultSeed, staleCount: Int? = nil) -> LeafMap {
        let marginX = 14.0, marginY = 15.0
        let total = input.flatMap(\.items).reduce(0.0) { $0 + $1.weight }
        guard total > 0 else { return LeafMap(width: width, height: height, leaves: [], groupLabels: [], stipple: [], staleCount: staleCount ?? 0) }
        let minW = total * minLeaf * minLeaf / (width * height * 0.82)
        // Every worktree keeps its own leaf (D13): small and 0 B ones are padded to a fixed minimum, never folded.
        let groups = pad(input, minWeight: minW).filter { !$0.items.isEmpty }

        // Organic outer boundary: a convex superellipse.
        let w = width - marginX, h = height
        var outer: [Pt] = []
        for i in 0..<72 {
            let a = Double(i) / 72 * 2 * .pi, c = cos(a), s = sin(a), e = 0.28
            outer.append(Pt(marginX + w / 2 + (w / 2 - 1) * sgn(c) * pow(abs(c), e),
                            h / 2 + (h / 2 - marginY) * sgn(s) * pow(abs(s), e)))
        }
        var rng = PowerTreemap.Rng(seed: seed)
        let groupCells = PowerTreemap.split(values: groups.map { $0.items.reduce(0.0) { $0 + $1.weight } }, clip: outer, rng: &rng)

        var leaves: [Leaf] = [], stipple: [Pt] = [], candidates: [(Double, GroupLabel)] = []
        var cid = 0
        for (gi, g) in groups.enumerated() {
            let gpoly = groupCells[gi]
            guard gpoly.count >= 3 else { continue }
            let gp = Geo.inset(gpoly, 3.4)
            guard gp.count >= 3 else { continue }
            if !g.isFree, let l = groupLabel(g.name, gp, height: height) { candidates.append((g.items.reduce(0.0) { $0 + $1.weight }, l)) }
            let cells = PowerTreemap.split(values: g.items.map(\.weight), clip: gpoly, rng: &rng)
            for (ii, item) in g.items.enumerated() {
                var p = Geo.inset(cells[ii], 2.8)
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
        let labels = placeLabels(candidates, width: width, height: height)
        let stale = staleCount ?? groups.flatMap(\.items).reduce(0) { $0 + ($1.state == .stale ? max(1, $1.foldedCount) : 0) }
        return LeafMap(width: width, height: height, leaves: leaves, groupLabels: labels, stipple: stipple, staleCount: stale)
    }

    static func sgn(_ v: Double) -> Double { v < 0 ? -1 : (v > 0 ? 1 : 0) }

    /// Candidate label for a group touching the top or bottom edge of the map (D13: no rotated side labels).
    static func groupLabel(_ name: String, _ gp: [Pt], height: Double) -> GroupLabel? {
        let ys = gp.map(\.y), mnY = ys.min()!, mxY = ys.max()!
        let top = mnY < 22, bottom = mxY > height - 22
        guard top || bottom else { return nil }
        let edge = top ? mnY : mxY
        let pts = gp.filter { abs($0.y - edge) < 6 }
        let x = pts.reduce(0) { $0 + $1.x } / Double(max(pts.count, 1))
        return GroupLabel(name: name, at: Pt(x, top ? 10 : height - 3))
    }

    /// Keeps a label only if it lies inside the map and clears every label already kept; bigger groups win (D13).
    /// Labels that don't fit are dropped, never shifted onto a neighbour's leaves.
    static func placeLabels(_ candidates: [(Double, GroupLabel)], width: Double, height: Double) -> [GroupLabel] {
        var kept: [GroupLabel] = []
        for (_, l) in candidates.sorted(by: { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name < $1.1.name }) {
            let r = l.rect
            guard r.inside(width: width, height: height), !kept.contains(where: { $0.rect.intersects(r, gap: 6) }) else { continue }
            kept.append(l)
        }
        return kept.sorted { $0.at.x != $1.at.x ? $0.at.x < $1.at.x : $0.at.y < $1.at.y }
    }

    /// Pads every item to at least `minWeight` so each worktree, even a 0 B prunable one, gets a fixed minimum leaf.
    public static func pad(_ groups: [LeafGroup], minWeight: Double) -> [LeafGroup] {
        groups.map { g in
            var g = g
            g.items = g.items.map { var i = $0; i.weight = max(i.weight, minWeight); return i }
            return g
        }
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

        // Label (D13): the branch name on one line at 10.5 pt, only if the leaf is wide enough at the text's
        // top, middle and bottom; otherwise no text. Sizes and the repo live in the hover card.
        let c = Geo.centroid(s)
        let name = item.foldedCount > 0 ? "other (\(item.foldedCount))" : item.name
        let fits = LeafText.fits(name, in: outline, at: c)
        // Rebuildable share: the outline scaled about its centroid so its area is that share of the leaf.
        let share = item.rebuildableShare
        let inner = share > 0.02 ? outline.map { c + ($0 - c) * share.squareRoot() } : []
        return Leaf(item: item, group: group, outline: outline, veins: veins, centroid: c,
                    labelLines: fits ? [name] : [], showSize: false, inner: inner, subLabel: nil)
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
