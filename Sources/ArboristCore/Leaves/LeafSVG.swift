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
    public static func popover(_ r: ScanResult, map: LeafMap, note: String = "Linux render", hover: String? = nil, now: Date = Date()) -> String {
        let freeBytes = r.volume?.freeBytes ?? 0, totalBytes = r.volume?.totalBytes ?? 0
        let pad = 16.0, w = map.width + pad * 2, mapTop = 52.0
        let cachesY = mapTop + map.height + 16, keyTop = cachesY + 14
        let h = keyTop + 110
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(w))\" height=\"\(f(h))\" viewBox=\"0 0 \(f(w)) \(f(h))\" font-family=\"-apple-system, 'SF Pro Text', Inter, 'DejaVu Sans', sans-serif\">"
        s += "<rect width=\"100%\" height=\"100%\" rx=\"14\" fill=\"\(LeafPalette.background)\"/>"
        let parts = r.headline.split(separator: " ", maxSplits: 2).map(String.init)   // "40" "worktrees" "in 34 repos · 5 stale"
        s += "<text x=\"\(pad)\" y=\"38\" font-size=\"22\" font-weight=\"400\" fill=\"\(LeafPalette.ink)\">\(esc(parts.prefix(2).joined(separator: " ")))"
        if parts.count > 2 { s += "<tspan font-size=\"13\" fill=\"\(LeafPalette.inkSoft)\" dx=\"5\">\(esc(parts[2]))</tspan>" }
        s += "</text>"
        s += "<text x=\"\(f(w - pad))\" y=\"36\" text-anchor=\"end\" font-size=\"11.5\" fill=\"\(LeafPalette.inkSoft)\">Arborist</text>"
        s += "<g transform=\"translate(\(pad),\(mapTop))\">" + mapBody(map, hover: hover) + "</g>"
        if let c = Format.cachesLine(r.caches) {
            s += "<text x=\"\(pad)\" y=\"\(f(cachesY))\" font-size=\"10.5\" fill=\"\(LeafPalette.inkSoft)\">\(esc(c))</text>"
        }
        // Key: states, rebuildable share, kinds.
        var x = pad
        for (state, name) in [(LeafState.protected, "Uncommitted / unpushed"), (.clean, "Clean"), (.stale, "Merged / stale")] {
            s += "<rect x=\"\(f(x))\" y=\"\(f(keyTop))\" width=\"9\" height=\"9\" rx=\"2.5\" fill=\"\(LeafPalette.fill(state))\"/>"
            s += "<text x=\"\(f(x + 14))\" y=\"\(f(keyTop + 8.5))\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">\(name)</text>"
            x += 22 + Double(name.count) * 6.0
        }
        x = pad
        for (kind, name) in [(LeafKind.worktree, "Worktree"), (.main, "Main checkout")] {
            s += "<path transform=\"translate(\(f(x)),\(f(keyTop + 18)))\" d=\"\(keyGlyph(kind))\" fill=\"\(LeafPalette.fill(.clean))\" stroke=\"\(LeafPalette.keyStroke)\" stroke-width=\".5\"/>"
            s += "<text x=\"\(f(x + 22))\" y=\"\(f(keyTop + 26.5))\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">\(name)</text>"
            x += 34 + Double(name.count) * 6.0
        }
        s += "<rect x=\"\(f(x))\" y=\"\(f(keyTop + 18))\" width=\"18\" height=\"10\" rx=\"4\" fill=\"\(LeafPalette.fill(.clean))\"/>"
        s += "<rect x=\"\(f(x + 4))\" y=\"\(f(keyTop + 20.5))\" width=\"10\" height=\"5\" rx=\"2.5\" fill=\"\(LeafPalette.rebuildableShade)\" fill-opacity=\"\(LeafPalette.rebuildableOpacity(.clean) * 1.6)\"/>"
        s += "<text x=\"\(f(x + 23))\" y=\"\(f(keyTop + 26.5))\" font-size=\"11\" fill=\"\(LeafPalette.inkSoft)\">Rebuildable (node_modules, .build…)</text>"
        let barY = keyTop + 42, frac = totalBytes > 0 ? 1 - Double(freeBytes) / Double(totalBytes) : 0
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
            s += hoverCard(HoverCard(ref, now: now, home: LeafSample.home), near: leaf.centroid + Pt(pad, mapTop), in: Pt(w, h))
        }
        return s + "</svg>"
    }

    /// Card size used by the SVG and the app.
    public static let cardWidth = 250.0
    public static func cardHeight(_ c: HoverCard) -> Double { 16 + Double(c.lines.count) * 15 }

    /// Where to put a card for a leaf centred at `p`: beside it, kept inside `bounds`.
    public static func cardOrigin(near p: Pt, size: Pt, in bounds: Pt) -> Pt {
        var x = p.x + 18, y = p.y - size.y / 2
        if x + size.x > bounds.x - 6 { x = p.x - 18 - size.x }
        x = min(max(6, x), bounds.x - size.x - 6)
        y = min(max(6, y), bounds.y - size.y - 6)
        return Pt(x, y)
    }

    static func hoverCard(_ c: HoverCard, near p: Pt, in bounds: Pt) -> String {
        let size = Pt(cardWidth, cardHeight(c)), o = cardOrigin(near: p, size: size, in: bounds)
        var s = "<g>"
        s += "<rect x=\"\(f(o.x + 1))\" y=\"\(f(o.y + 2))\" width=\"\(f(size.x))\" height=\"\(f(size.y))\" rx=\"9\" fill=\"#000\" fill-opacity=\".08\"/>"
        s += "<rect x=\"\(f(o.x))\" y=\"\(f(o.y))\" width=\"\(f(size.x))\" height=\"\(f(size.y))\" rx=\"9\" fill=\"\(LeafPalette.cardFill)\" stroke=\"\(LeafPalette.cardStroke)\" stroke-width=\".8\"/>"
        for (i, line) in c.lines.enumerated() {
            let y = o.y + 20 + Double(i) * 15
            if i == 0 {
                s += "<circle cx=\"\(f(o.x + 14))\" cy=\"\(f(y - 4))\" r=\"3.5\" fill=\"\(LeafPalette.dot(c.status))\"/>"
                s += "<text x=\"\(f(o.x + 23))\" y=\"\(f(y))\" font-size=\"12\" font-weight=\"600\" fill=\"\(LeafPalette.ink)\">\(esc(c.branch))<tspan font-weight=\"400\" fill=\"\(LeafPalette.inkSoft)\"> · \(c.status.word)</tspan></text>"
            } else {
                let last = i == c.lines.count - 1
                s += "<text x=\"\(f(o.x + 12))\" y=\"\(f(y))\" font-size=\"\(i == 2 ? 10.5 : 11)\" fill=\"\(last ? LeafPalette.ink : LeafPalette.inkSoft)\"\(last ? " font-weight=\"500\"" : "")>\(esc(clip(line, 40)))</text>"
            }
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
        var s = ""
        for (i, leaf) in map.leaves.enumerated() {
            let st = leaf.item.state, d = path(leaf.outline)
            let hovered = hover == leaf.item.id, dim = hover != nil && !hovered
            s += "<g\(dim ? " opacity=\"\(LeafPalette.dimOthers)\"" : "")\(hovered ? " transform=\"translate(0,-1.5)\"" : "")>"
            if hovered { s += "<path d=\"\(d)\" fill=\"#000\" fill-opacity=\".18\" transform=\"translate(0,3)\"/>" }
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
            if hovered { s += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(LeafPalette.hoverStroke)\" stroke-width=\"1.6\"/>" }
            let dark = LeafPalette.isDark(st)
            let lc = dark ? LeafPalette.labelOnDark : "#1c1e21", sc = dark ? LeafPalette.sizeOnDark : LeafPalette.sizeOnLight
            let lines = leaf.labelLines, y0 = leaf.centroid.y - Double(lines.count + (leaf.subLabel == nil ? 0 : 1)) * 12.5 / 2 + 2
            for (k, line) in lines.enumerated() { s += text(leaf.centroid.x, y0 + Double(k) * 12.5 + 4, line, size: 10.5, color: lc, weight: 500) }
            if leaf.showSize { s += text(leaf.centroid.x, lines.isEmpty ? leaf.centroid.y + 3 : y0 + Double(lines.count) * 12.5 + 4, sizeLabel(leaf.item), size: 10.5, color: sc) }
            if let sub = leaf.subLabel { s += text(leaf.centroid.x, y0 + Double(lines.count + 1) * 12.5 + 4, sub, size: 10.5, color: sc, extra: " font-style=\"italic\"") }
            s += "</g>"
        }
        for g in map.groupLabels {
            let rot = g.vertical ? " transform=\"rotate(-90 \(f(g.at.x)) \(f(g.at.y)))\"" : ""
            s += text(g.at.x, g.at.y, g.name, size: 10.5, color: LeafPalette.groupLabel, weight: 500, extra: rot)
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
