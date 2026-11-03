import Foundation

/// SVG renderer for the leaf map and the icon stages. Used for snapshots on Linux; the app draws the same
/// geometry with SwiftUI.
public enum LeafSVG {
    static func f(_ v: Double) -> String { String(format: "%.2f", v) }
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func path(_ p: [Pt]) -> String {
        guard let first = p.first else { return "" }
        return "M\(f(first.x)),\(f(first.y))" + p.dropFirst().map { "L\(f($0.x)),\(f($0.y))" }.joined() + "Z"
    }
    static func text(_ x: Double, _ y: Double, _ t: String, size: Double, color: String, weight: Int = 400, extra: String = "") -> String {
        "<text x=\"\(f(x))\" y=\"\(f(y))\" text-anchor=\"middle\" font-size=\"\(size)\" fill=\"\(color)\" font-weight=\"\(weight)\"\(extra)>\(esc(t))</text>"
    }

    /// The popover as an SVG (worktree-first, D12): headline, map, caches line, key, free bar and Clear.
    /// `hover` is a leaf id to draw in its hovered state, with its card.
    public static func popover(_ r: ScanResult, map: LeafMap, note: String = "Linux render", hover: String? = nil, now: Date = Date(),
                               cardAt: Pt? = nil, pointer: Pt? = nil, cardOpacity: Double = 1) -> String {
        let freeBytes = r.volume?.freeBytes ?? 0, totalBytes = r.volume?.totalBytes ?? 0
        let pad = svgPad, mapTop = svgMapTop, size = svgSize(map), w = size.x, h = size.y
        let keyTop = mapTop + map.height + 12
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(w))\" height=\"\(f(h))\" viewBox=\"0 0 \(f(w)) \(f(h))\" font-family=\"-apple-system, 'SF Pro Text', Inter, 'DejaVu Sans', sans-serif\">"
        s += "<rect width=\"100%\" height=\"100%\" rx=\"14\" fill=\"\(LeafPalette.background)\"/>"
        let parts = r.headline.split(separator: " ", maxSplits: 2).map(String.init)   // "40" "worktrees" "in 34 repos · 5 stale"
        s += "<text x=\"\(pad)\" y=\"38\" font-size=\"22\" font-weight=\"400\" fill=\"\(LeafPalette.ink)\">\(esc(parts.prefix(2).joined(separator: " ")))"
        if parts.count > 2 { s += "<tspan font-size=\"13\" fill=\"\(LeafPalette.inkSoft)\" dx=\"5\">\(esc(parts[2]))</tspan>" }
        s += "</text>"
        s += "<text x=\"\(f(w - pad))\" y=\"36\" text-anchor=\"end\" font-size=\"11.5\" fill=\"\(LeafPalette.inkSoft)\">Arborist</text>"
        s += "<g transform=\"translate(\(pad),\(mapTop))\">" + mapBody(map, hover: hover) + "</g>"
        // Footer (D13): one legend line with three dots, and the caches total at the right.
        var x = pad
        for (state, name) in [(LeafState.protected, "Uncommitted / unpushed"), (.clean, "Clean"), (.stale, "Merged / stale")] {
            s += "<circle cx=\"\(f(x + 4))\" cy=\"\(f(keyTop + 4.5))\" r=\"4\" fill=\"\(LeafPalette.fill(state))\"/>"
            s += "<text x=\"\(f(x + 13))\" y=\"\(f(keyTop + 8.5))\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">\(name)</text>"
            x += 26 + LeafText.width(name, size: 11, weight: false)
        }
        if let c = Format.cachesTotal(r.caches) {
            s += "<text x=\"\(f(w - pad))\" y=\"\(f(keyTop + 8.5))\" text-anchor=\"end\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">\(esc(c))</text>"
        }
        let barY = keyTop + 24, frac = totalBytes > 0 ? 1 - Double(freeBytes) / Double(totalBytes) : 0
        s += "<rect x=\"\(pad)\" y=\"\(f(barY))\" width=\"\(f(map.width))\" height=\"6\" rx=\"3\" fill=\"\(LeafPalette.barTrack)\"/>"
        s += "<rect x=\"\(pad)\" y=\"\(f(barY))\" width=\"\(f(map.width * frac))\" height=\"6\" rx=\"3\" fill=\"\(LeafPalette.barFill)\"/>"
        s += "<text x=\"\(pad)\" y=\"\(f(barY + 20))\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\"><tspan fill=\"\(LeafPalette.ink)\" font-weight=\"500\">\(esc(Format.bytes(freeBytes)))</tspan> free</text>"
        s += "<text x=\"\(f(w - pad))\" y=\"\(f(barY + 20))\" text-anchor=\"end\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">of \(esc(Format.bytes(totalBytes)))</text>"
        let btnY = barY + 34
        s += "<rect x=\"\(pad)\" y=\"\(f(btnY))\" width=\"72\" height=\"28\" rx=\"7\" fill=\"\(LeafPalette.button)\"/>"
        s += text(pad + 36, btnY + 18, "Clear \(map.staleCount)", size: 12, color: LeafPalette.labelOnDark, weight: 500)
        s += "<text x=\"\(f(w - pad))\" y=\"\(f(btnY + 18))\" text-anchor=\"end\" font-size=\"10.5\" fill=\"\(LeafPalette.inkSoft)\">\(note)</text>"
        // Hover card on top of everything.
        if let id = hover, let leaf = map.leaves.first(where: { $0.item.id == id }), let ref = WorktreeList.find(r, path: id) {
            let card = HoverCard(ref, now: now, home: LeafSample.home)
            // D19: `cardAt` and the default placement are in popover coordinates, against the whole popover.
            let o = cardAt ?? CardPlacement.place(leaf: cardSpace(map).leafRect(leaf), size: Pt(cardWidth, cardHeight(card)), in: size)
            s += cardOpacity < 1 ? "<g opacity=\"\(cardOpacity)\">" + hoverCard(card, at: o) + "</g>"
                                 : hoverCard(card, at: o)
        }
        // --hover-sweep frames mark the pointer (D15).
        if let p = pointer {
            s += "<circle cx=\"\(f(p.x + pad))\" cy=\"\(f(p.y + mapTop))\" r=\"3.5\" fill=\"#d0402b\" stroke=\"#fff\" stroke-width=\"1\"/>"
        }
        return s + "</svg>"
    }

    static let svgPad = 16.0, svgMapTop = 52.0
    /// The SVG popover's size for `map`.
    public static func svgSize(_ map: LeafMap) -> Pt { Pt(map.width + svgPad * 2, svgMapTop + map.height + 12 + 92) }
    /// The SVG popover as a card space (D19): the map at (16, 52), drawn 1:1.
    public static func cardSpace(_ map: LeafMap) -> CardSpace { CardSpace(mapOrigin: Pt(svgPad, svgMapTop), size: svgSize(map)) }

    /// Card metrics shared by the SVG and the app (D13).
    public static let cardWidth = 264.0
    public static func cardHeight(_ c: HoverCard) -> Double {
        128 + Double(c.message.count) * 14 + (c.message.isEmpty ? 0 : 4) + 8 + 22 + 10
    }
    /// The app's card adds a "Remove worktree" row (D14).
    public static let appCardExtra = 26.0
    /// Tallest card (2 message lines, app row). Hover anchors the card using this so it never needs to move
    /// because one card is taller than the last (D15).
    public static let cardSlot = Pt(cardWidth, 200.0 + appCardExtra) // cardHeight with 2 message lines = 200

    /// Places the card beside the hovered leaf without covering it: right, left, below, then above.
    /// If none fits inside `bounds`, the one overlapping the leaf least (clamped to bounds) wins.
    public static func cardOrigin(avoiding leaf: Rect, size: Pt, in bounds: Pt, gap: Double = 10) -> Pt {
        let cy = leaf.y + leaf.h / 2 - size.y / 2, cx = leaf.x + leaf.w / 2 - size.x / 2
        func clampY(_ y: Double) -> Double { min(max(4, y), bounds.y - size.y - 4) }
        func clampX(_ x: Double) -> Double { min(max(4, x), bounds.x - size.x - 4) }
        let tries = [Pt(leaf.x + leaf.w + gap, clampY(cy)), Pt(leaf.x - gap - size.x, clampY(cy)),
                     Pt(clampX(cx), leaf.y + leaf.h + gap), Pt(clampX(cx), leaf.y - gap - size.y)]
        if let ok = tries.first(where: { Rect(x: $0.x, y: $0.y, w: size.x, h: size.y).inside(width: bounds.x, height: bounds.y) }) { return ok }
        func overlap(_ p: Pt) -> Double {
            let r = Rect(x: clampX(p.x), y: clampY(p.y), w: size.x, h: size.y)
            return max(0, min(r.x + r.w, leaf.x + leaf.w) - max(r.x, leaf.x)) * max(0, min(r.y + r.h, leaf.y + leaf.h) - max(r.y, leaf.y))
        }
        let best = tries.min { overlap($0) < overlap($1) }!
        return Pt(clampX(best.x), clampY(best.y))
    }

    static func hoverCard(_ c: HoverCard, at o: Pt) -> String {
        let W = cardWidth, H = cardHeight(c), px = 10.0, soft = LeafPalette.inkSoft, ink = LeafPalette.ink
        var s = "<g>"
        s += "<filter id=\"cs\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow dx=\"0\" dy=\"3\" stdDeviation=\"5\" flood-color=\"#000\" flood-opacity=\".12\"/></filter>"
        s += "<rect x=\"\(f(o.x))\" y=\"\(f(o.y))\" width=\"\(f(W))\" height=\"\(f(H))\" rx=\"9\" fill=\"\(LeafPalette.cardFill)\" stroke=\"\(LeafPalette.cardStroke)\" stroke-width=\".6\" filter=\"url(#cs)\"/>"
        // Header: branch + pill, repo, path.
        var y = o.y + 21
        let bw = LeafText.width(c.branch, size: 12) * 1.04
        s += "<text x=\"\(f(o.x + px))\" y=\"\(f(y))\" font-size=\"12\" font-weight=\"600\" fill=\"\(ink)\">\(esc(clip(c.branch, 26)))</text>"
        let pw = LeafText.width(c.pill, size: 10) + 12, pxp = min(o.x + px + bw + 7, o.x + W - px - pw)
        s += "<rect x=\"\(f(pxp))\" y=\"\(f(y - 10.5))\" width=\"\(f(pw))\" height=\"14\" rx=\"7\" fill=\"\(LeafPalette.dot(c.status))\" fill-opacity=\".2\"/>"
        s += "<text x=\"\(f(pxp + pw / 2))\" y=\"\(f(y - 0.5))\" text-anchor=\"middle\" font-size=\"10\" font-weight=\"500\" fill=\"\(LeafPalette.pillText(c.status))\">\(esc(c.pill))</text>"
        y += 15
        s += "<text x=\"\(f(o.x + px))\" y=\"\(f(y))\" font-size=\"11\" fill=\"\(soft)\">\(esc(c.repo))</text>"
        y += 14
        s += "<text x=\"\(f(o.x + px))\" y=\"\(f(y))\" font-size=\"10\" font-family=\"'SF Mono', Menlo, 'DejaVu Sans Mono', monospace\" fill=\"\(soft)\"><title>\(esc(c.fullPath))</title>\(esc(c.path))</text>"
        y += 10
        s += "<line x1=\"\(f(o.x + px))\" x2=\"\(f(o.x + W - px))\" y1=\"\(f(y))\" y2=\"\(f(y))\" stroke=\"\(LeafPalette.cardStroke)\" stroke-width=\".6\"/>"
        // Stats 2×2.
        let col2 = o.x + W / 2 + 4
        let stats = [("Size", c.size, o.x + px), ("Changes", c.changes, col2), ("Sync", c.sync, o.x + px), ("Last commit", c.lastCommit, col2)]
        for (k, st) in stats.enumerated() {
            let ry = y + 15 + Double(k / 2) * 34
            s += "<text x=\"\(f(st.2))\" y=\"\(f(ry))\" font-size=\"10\" fill=\"\(soft)\">\(st.0)</text>"
            s += "<text x=\"\(f(st.2))\" y=\"\(f(ry + 14))\" font-size=\"11.5\" font-weight=\"500\" fill=\"\(ink)\">\(esc(st.1))</text>"
            if k == 0, c.rebuildableShare > 0 {
                let bx = st.2, bwid = 96.0
                s += "<rect x=\"\(f(bx))\" y=\"\(f(ry + 18.5))\" width=\"\(f(bwid))\" height=\"4\" rx=\"2\" fill=\"\(LeafPalette.barTrack)\"><title>\(esc(c.rebuildable ?? ""))</title></rect>"
                s += "<rect x=\"\(f(bx))\" y=\"\(f(ry + 18.5))\" width=\"\(f(bwid * c.rebuildableShare))\" height=\"4\" rx=\"2\" fill=\"\(LeafPalette.barFill)\"/>"
            }
        }
        y += 72
        for line in c.message { y += 14; s += "<text x=\"\(f(o.x + px))\" y=\"\(f(y))\" font-size=\"11\" fill=\"\(ink)\">\(esc(line))</text>" }
        y += c.message.isEmpty ? 4 : 10
        // Footer buttons.
        var bx = o.x + px
        for label in ["Reveal in Finder"] + (c.removeCommand == nil ? [] : ["Copy remove command"]) {
            let wv = LeafText.width(label, size: 11, weight: false) * 1.08 + 16
            s += "<rect x=\"\(f(bx))\" y=\"\(f(y))\" width=\"\(f(wv))\" height=\"22\" rx=\"6\" fill=\"\(LeafPalette.background)\" stroke=\"\(LeafPalette.cardStroke)\" stroke-width=\".6\"/>"
            s += "<text x=\"\(f(bx + wv / 2))\" y=\"\(f(y + 15))\" text-anchor=\"middle\" font-size=\"11\" fill=\"\(ink)\">\(label)</text>"
            bx += wv + 6
        }
        return s + "</g>"
    }

    static func clip(_ t: String, _ n: Int) -> String { t.count > n ? String(t.prefix(n - 1)) + "…" : t }

    static func keyGlyph(_ k: LeafKind) -> String {
        switch k {
        case .worktree: "M1,5Q5,1 9,1T17,5Q13,9 9,9T1,5Z"
        case .main: "M5,1H13A4,4 0 0 1 13,9H5A4,4 0 0 1 5,1Z"
        case .cache: "M1,4Q4,1 8,1H17L13,5L17,9H8Q4,9 1,6Z"
        default: "M2,1Q4,0 6,1Q8,0 10,1Q12,0 14,1Q17,1 17,5Q17,9 14,9Q12,10 10,9Q8,10 6,9Q4,10 2,9Q1,8 1,5Q1,2 2,1Z"
        }
    }

    public static func mapBody(_ map: LeafMap, hover: String? = nil) -> String {
        var s = "<filter id=\"ls\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow dx=\"0\" dy=\"2\" stdDeviation=\"3\" flood-color=\"#000\" flood-opacity=\".18\"/></filter>"
        // Hovered leaf last so it sits on top of its neighbours.
        let order = map.leaves.enumerated().sorted { ($0.element.item.id == hover ? 1 : 0) < ($1.element.item.id == hover ? 1 : 0) }
        for (i, leaf) in order {
            let st = leaf.item.state, d = path(leaf.outline)
            let hovered = hover == leaf.item.id, dim = hover != nil && !hovered
            let c = leaf.centroid, k = LeafPalette.hoverScale
            let lift = hovered ? " transform=\"translate(\(f(c.x * (1 - k))),\(f(c.y * (1 - k) - 1))) scale(\(k))\" filter=\"url(#ls)\"" : ""
            s += "<g\(dim ? " opacity=\"\(LeafPalette.dimOthers)\"" : "")\(lift)>"
            s += "<clipPath id=\"L\(i)\"><path d=\"\(d)\"/></clipPath>"
            s += "<path d=\"\(d)\" fill=\"\(LeafPalette.fill(st))\"\(st == .stale ? " stroke=\"\(LeafPalette.staleStroke)\" stroke-width=\".4\"" : "")/>"
            if !leaf.inner.isEmpty {
                s += "<path d=\"\(path(leaf.inner))\" fill=\"\(LeafPalette.rebuildableShade)\" fill-opacity=\"\(LeafPalette.rebuildableOpacity(st))\"/>"
            }
            let (vc, vo) = LeafPalette.vein(st)
            s += "<g clip-path=\"url(#L\(i))\">"
            for v in leaf.veins {
                s += "<path d=\"M\(f(v.p0.x)),\(f(v.p0.y))Q\(f(v.c.x)),\(f(v.c.y)) \(f(v.p1.x)),\(f(v.p1.y))\" stroke=\"\(vc)\" stroke-opacity=\"\(f(vo * v.opacity))\" stroke-width=\"\(f(v.width))\" fill=\"none\" stroke-linecap=\"round\"/>"
            }
            s += "</g>"
            if let name = leaf.labelLines.first {
                let lc = LeafPalette.isDark(st) ? LeafPalette.labelOnDark : "#1c1e21"
                s += text(c.x, c.y + 3.8, name, size: LeafText.leafSize, color: lc, weight: 500)
            }
            s += "</g>"
        }
        for g in map.groupLabels {
            s += text(g.at.x, g.at.y, g.name, size: LeafText.groupSize, color: LeafPalette.groupLabel, weight: 500)
        }
        return s
    }

    /// Size text on a leaf: "other (n)" leaves and ordinary ones both show bytes.
    public static func sizeLabel(_ i: LeafItem) -> String { Format.bytes(i.bytes) }

    /// Four stage glyphs, each drawn black at icon size and enlarged, with captions (light and dark rows).
    public static func stageStrip(cell: Double = 96) -> String {
        let stages = LeafStage.allCases, w = cell * Double(stages.count), h = cell * 2 + 40
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(w))\" height=\"\(f(h))\" font-family=\"Inter, 'DejaVu Sans', sans-serif\">"
        s += "<rect width=\"\(f(w))\" height=\"\(f(cell + 20))\" fill=\"#f4f4f4\"/><rect y=\"\(f(cell + 20))\" width=\"\(f(w))\" height=\"\(f(cell + 20))\" fill=\"#2a2a2a\"/>"
        for (row, color) in ["#111111", "#f2f2f2"].enumerated() {
            for (i, st) in stages.enumerated() {
                let g = LeafGlyph.glyph(st), ox = Double(i) * cell + cell * 0.2, oy = Double(row) * (cell + 20) + 6, k = cell * 0.6
                func sc(_ p: [Pt], close: Bool) -> String {
                    let pts = p.map { "\(f(ox + $0.x * k)),\(f(oy + $0.y * k))" }
                    return (close ? "M" : "M") + pts.joined(separator: "L") + (close ? "Z" : "")
                }
                s += "<path d=\"\(sc(g.outline, close: true))\" fill=\"\(g.filled ? color : "none")\" stroke=\"\(color)\" stroke-width=\"\(g.filled ? 0 : 2.2)\" stroke-linejoin=\"round\"/>"
                s += "<path d=\"\(sc(g.stem, close: false))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"2.4\" stroke-linecap=\"round\"/>"
                s += "<path d=\"\(sc(g.midrib, close: false))\" fill=\"none\" stroke=\"\(g.filled ? (row == 0 ? "#f4f4f4" : "#2a2a2a") : color)\" stroke-width=\"1.3\" stroke-linecap=\"round\"/>"
                // Actual 18pt icon size, bottom right of each cell.
                let ix = Double(i) * cell + cell - 24, iy = oy + cell - 34, ik = 18.0
                let small = g.outline.map { "\(f(ix + $0.x * ik)),\(f(iy + $0.y * ik))" }.joined(separator: "L")
                s += "<path d=\"M\(small)Z\" fill=\"\(g.filled ? color : "none")\" stroke=\"\(color)\" stroke-width=\"\(g.filled ? 0 : 1)\"/>"
                s += text(Double(i) * cell + cell / 2, oy + cell + 8, st.title, size: 11, color: row == 0 ? "#333" : "#ddd")
            }
        }
        return s + "</svg>"
    }
}
