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

    /// The popover as an SVG (worktree-first, D12, D22): headline, map, detail strip, key, free bar and Clear.
    /// `hover` is the hovered leaf (ringed, in the panel unless one is `pinned`, i.e. selected); `pointer`
    /// (map coordinates) draws the sweep's pointer marker. D25: no tooltip; the panel is the readout.
    public static func popover(_ r: ScanResult, map: LeafMap, note: String = "Linux render", hover: String? = nil, pinned: String? = nil,
                               now: Date = Date(), pointer: Pt? = nil, showAll: Bool = false,
                               filterLabel: String? = nil, status: String = "", menu: [RepoMenuRow]? = nil) -> String {
        let pad = svgPad, mapTop = svgMapTop, size = svgSize(map), w = size.x, h = size.y
        let space = popoverSpace(map)
        // D24: one shared slot below the map: legend + storage bar at rest, the leaf details on hover or pin
        // (same rect). The footer buttons have their own row below it.
        let slot = space.stripRect
        let shown = (pinned ?? hover).flatMap { WorktreeList.find(r, path: $0) }.map { HoverCard($0, now: now, home: LeafSample.home) }
        var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(w))\" height=\"\(f(h))\" viewBox=\"0 0 \(f(w)) \(f(h))\" font-family=\"-apple-system, 'SF Pro Text', Inter, 'DejaVu Sans', sans-serif\">"
        s += "<rect width=\"100%\" height=\"100%\" rx=\"14\" fill=\"\(LeafPalette.background)\"/>"
        let hs = header(r, filter: filterLabel ?? HeaderLayout.filterLabel(selected: r.repos.map(\.name), total: r.repos.count), status: status)
        s += hs.svg
        s += "<g transform=\"translate(\(pad),\(mapTop))\">" + mapBody(map, hover: hover, pinned: pinned) + "</g>"
        if let shown {
            s += strip(shown, pinned: pinned != nil, in: slot).svg
        } else {
            s += rest(r, in: slot, showAll: showAll).svg + "<!-- \(esc(note)) -->"
        }
        for (name, b) in FooterLayout.buttons(in: space.footerRect) {
            let label = name == "Clear" ? "Clear \(map.staleCount)" : name == "Settings" ? "⚙" : name == "Quit" ? "⏻" : name
            let dark = name == "Clear"
            s += "<rect x=\"\(f(b.x))\" y=\"\(f(b.y))\" width=\"\(f(b.w))\" height=\"\(f(b.h))\" rx=\"7\" fill=\"\(dark ? LeafPalette.button : "none")\"/>"
            s += text(b.x + b.w / 2, b.y + 18, label, size: 12, color: dark ? LeafPalette.labelOnDark : LeafPalette.inkSoft, weight: dark ? 500 : 400)
        }
        if let menu { s += repoMenu(menu, under: HeaderLayout.filterButton(hs.frames)) }
        if let p = pointer {
            s += "<circle cx=\"\(f(p.x + pad))\" cy=\"\(f(p.y + mapTop))\" r=\"3.5\" fill=\"#d0402b\" stroke=\"#fff\" stroke-width=\"1\"/>"
        }
        return s + "</svg>"
    }

    static let svgPad = 16.0, svgMapTop = 52.0
    /// The SVG popover's size for `map`: map, strip, key, free bar, buttons.
    public static func svgSize(_ map: LeafMap) -> Pt {
        Pt(map.width + svgPad * 2, svgMapTop + map.height + PopoverLayout.stripGap + PopoverLayout.stripHeight
             + PopoverLayout.stripGap + PopoverLayout.footerRowHeight + svgPad)
    }

    /// D24: what `popover` draws for this hover state: the map's frame, the strip's height and its frames.
    public static func drawn(_ r: ScanResult, map: LeafMap, hover: String?, pinned: String?, now: Date = Date(),
                             showAll: Bool = false, previousStrip: String?? = nil) -> HoverSweep.Drawn {
        let strip0 = pinned ?? hover
        let transition = previousStrip.map { PanelTransition.between($0, strip0) } ?? .none
        let space = popoverSpace(map)
        let shown = (pinned ?? hover).flatMap { WorktreeList.find(r, path: $0) }.map { HoverCard($0, now: now, home: LeafSample.home) }
        let mapFrame = Rect(x: svgPad, y: svgMapTop, w: map.width, h: map.height)
        let footer = FooterLayout.buttons(in: space.footerRect).map(\.rect)
        guard let shown else {
            let rs = rest(r, in: space.stripRect, showAll: showAll)
            return HoverSweep.Drawn(mapFrame: mapFrame, stripHeight: 0, stripFrames: nil, slotFrame: space.stripRect, footerButtons: footer,
                                    restFrames: rs.frames, legend: rs.legend, transition: transition)
        }
        let st = strip(shown, pinned: pinned != nil, in: space.stripRect)
        return HoverSweep.Drawn(mapFrame: mapFrame, stripHeight: space.stripRect.h, stripFrames: st.frames, slotFrame: space.stripRect,
                                footerButtons: footer, transition: transition)
    }
    /// The SVG popover as a popover space: the map at (16, 52), drawn 1:1.
    public static func popoverSpace(_ map: LeafMap) -> PopoverSpace { PopoverSpace(mapOrigin: Pt(svgPad, svgMapTop), size: svgSize(map)) }

    /// D26: the header row from HeaderLayout's frames (offset by the popover padding): count, stale, the
    /// filter button and the status icon. Every text at its natural width.
    public static func header(_ r: ScanResult, filter: String, status: String) -> (svg: String, frames: [(name: String, text: String, rect: Rect)], measures: [LegendMeasure]) {
        let c = HeaderLayout.count(r), sub = HeaderLayout.sub(r)
        let fr = HeaderLayout.frames(count: c, sub: sub, filter: filter)
        let ox = svgPad, oy = svgPad
        func at(_ n: String) -> Rect { let q = fr.first { $0.name == n }!.rect; return Rect(x: ox + q.x, y: oy + q.y, w: q.w, h: q.h) }
        var s = ""
        let a = at("count"), b = at("sub"), fb = at("filter"), st = at("status")
        s += "<text x=\"\(f(a.x))\" y=\"\(f(oy + 22))\" font-size=\"22\" font-weight=\"400\" fill=\"\(LeafPalette.ink)\">\(esc(c))</text>"
        if !sub.isEmpty { s += "<text x=\"\(f(b.x))\" y=\"\(f(oy + 22))\" font-size=\"13\" fill=\"\(LeafPalette.inkSoft)\">\(esc(sub))</text>" }
        s += "<text x=\"\(f(fb.x + 4))\" y=\"\(f(oy + 21))\" font-size=\"11.5\" fill=\"\(LeafPalette.inkSoft)\">\(esc(filter)) ▾</text>"
        s += "<circle cx=\"\(f(st.x + 9))\" cy=\"\(f(st.y + 9))\" r=\"6\" fill=\"none\" stroke=\"\(LeafPalette.inkSoft)\" stroke-width=\"1.2\"><title>\(esc(status.isEmpty ? "Arborist" : status))</title></circle>"
        let fbBox = HeaderLayout.filterButton(fr)
        let m = HeaderLayout.measures(count: c, sub: sub, filter: filter).map {
            LegendMeasure(label: $0.label, natural: $0.natural, frame: Rect(x: ox + $0.frame.x, y: oy + $0.frame.y, w: $0.frame.w, h: $0.frame.h))
        }
        _ = fbBox
        return (s, fr, m)
    }

    /// D26: the repo filter menu, open: an opaque light panel under the filter button (RepoMenuLayout,
    /// RepoMenuStyle), checkboxes, names, counts; the first row drawn hovered.
    public static func repoMenu(_ rows: [RepoMenuRow], under button: Rect) -> String {
        let o = RepoMenuLayout.origin(filterButton: button), x = svgPad + o.x, y = svgPad + o.y, w = RepoMenuLayout.width
        let searching = rows.count > RepoFilter.searchThreshold, p = RepoMenuLayout.padding
        let h = RepoMenuLayout.height(rows: rows.count, searching: searching)
        var s = "<rect x=\"\(f(x))\" y=\"\(f(y + 2))\" width=\"\(f(w))\" height=\"\(f(h))\" rx=\"8\" fill=\"#000\" fill-opacity=\".12\"/>"
        s += "<rect x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(w))\" height=\"\(f(h))\" rx=\"8\" fill=\"\(RepoMenuStyle.background)\" stroke=\"\(RepoMenuStyle.stroke)\" stroke-width=\".8\"/>"
        var cy = y + p
        s += "<text x=\"\(f(x + p))\" y=\"\(f(cy + 15))\" font-size=\"11\" fill=\"\(RepoMenuStyle.name)\">All</text>"
        s += "<text x=\"\(f(x + p + 30))\" y=\"\(f(cy + 15))\" font-size=\"11\" fill=\"\(RepoMenuStyle.name)\">None</text>"
        s += "<text x=\"\(f(x + w - p))\" y=\"\(f(cy + 15))\" text-anchor=\"end\" font-size=\"10\" fill=\"\(RepoMenuStyle.hint)\">⌥-click: only</text>"
        cy += RepoMenuLayout.topRow
        if searching {
            s += "<rect x=\"\(f(x + p))\" y=\"\(f(cy + 2))\" width=\"\(f(w - 2 * p))\" height=\"20\" rx=\"5\" fill=\"#fff\" stroke=\"\(RepoMenuStyle.stroke)\"/>"
            s += "<text x=\"\(f(x + p + 6))\" y=\"\(f(cy + 16))\" font-size=\"11\" fill=\"\(RepoMenuStyle.hint)\">Search repos</text>"
            cy += RepoMenuLayout.search
        }
        s += "<line x1=\"\(f(x + p))\" x2=\"\(f(x + w - p))\" y1=\"\(f(cy + 4))\" y2=\"\(f(cy + 4))\" stroke=\"\(RepoMenuStyle.stroke)\"/>"
        cy += RepoMenuLayout.divider
        for (i, r) in rows.prefix(RepoMenuLayout.maxRows).enumerated() {
            if i == 0 { s += "<rect x=\"\(f(x + 4))\" y=\"\(f(cy))\" width=\"\(f(w - 8))\" height=\"\(f(RepoMenuLayout.row))\" rx=\"5\" fill=\"\(RepoMenuStyle.hover)\"/>" }
            let bx = x + p, by = cy + 4, cs = RepoMenuLayout.checkSide
            if r.selected {
                s += "<rect x=\"\(f(bx))\" y=\"\(f(by))\" width=\"\(f(cs))\" height=\"\(f(cs))\" rx=\"3\" fill=\"\(RepoMenuStyle.selectedCheck)\"/>"
                s += "<path d=\"M\(f(bx + 3.5)) \(f(by + 7.5)) l3 3 l4.5 -6\" stroke=\"#fff\" stroke-width=\"1.6\" fill=\"none\"/>"
            } else {
                s += "<rect x=\"\(f(bx + 0.5))\" y=\"\(f(by + 0.5))\" width=\"\(f(cs - 1))\" height=\"\(f(cs - 1))\" rx=\"3\" fill=\"none\" stroke=\"\(RepoMenuStyle.uncheckedBox)\"/>"
            }
            let nameW = w - 2 * p - cs - 6 - RepoMenuLayout.countWidth
            s += "<text x=\"\(f(bx + cs + 6))\" y=\"\(f(cy + 15))\" font-size=\"11.5\" font-weight=\"\(r.selected ? 500 : 400)\" fill=\"\(RepoMenuStyle.name)\">\(esc(fit(r.name, nameW, 11.5, medium: r.selected)))</text>"
            s += "<text x=\"\(f(x + w - p))\" y=\"\(f(cy + 15))\" text-anchor=\"end\" font-size=\"11.5\" fill=\"\(RepoMenuStyle.count)\">\(r.count)</text>"
            cy += RepoMenuLayout.row
        }
        return s
    }

    /// D25: the resting panel (same content as the app's RestPanel): legend, storage bar and labels, and the
    /// 2 × 4 summary grid, all from RestLayout. Returns its content frames and legend measures.
    static func rest(_ r: ScanResult, in slot: Rect, showAll: Bool) -> (svg: String, frames: [Rect], legend: [LegendMeasure]) {
        let soft = LeafPalette.inkSoft, ink = LeafPalette.ink
        func o(_ q: Rect) -> Rect { Rect(x: slot.x + q.x, y: slot.y + q.y, w: q.w, h: q.h) }
        let all = r.repos.flatMap(\.worktrees)
        let labels = RestLayout.legendLabels(ready: all.filter(CleanupSafety.isReady).count, showAll: showAll)
        let colours: [String] = [LeafPalette.fill(.protected), LeafPalette.fill(.clean), LeafPalette.fill(.stale), LeafPalette.ring, "none"]
        var s = "", legend: [LegendMeasure] = []
        for (k, item) in RestLayout.legend(labels).enumerated() {
            let it = o(item.item), tx = o(item.text)
            if colours[k] != "none" { s += "<circle cx=\"\(f(it.x + 8))\" cy=\"\(f(it.y + 9))\" r=\"4\" fill=\"\(colours[k])\"/>" }
            s += "<text x=\"\(f(tx.x))\" y=\"\(f(tx.y + 13))\" font-size=\"11\" fill=\"\(soft)\">\(esc(fit(item.label, tx.w, 11, medium: false)))</text>"
            legend.append(LegendMeasure(label: item.label, natural: LeafText.width(item.label, size: 11, weight: false), frame: tx))
        }
        let freeBytes = r.volume?.freeBytes ?? 0, totalBytes = r.volume?.totalBytes ?? 0
        let bar = o(RestLayout.row("bar")), st = o(RestLayout.row("storage"))
        let frac = totalBytes > 0 ? 1 - Double(freeBytes) / Double(totalBytes) : 0
        s += "<rect x=\"\(f(bar.x))\" y=\"\(f(bar.y))\" width=\"\(f(bar.w))\" height=\"6\" rx=\"3\" fill=\"\(LeafPalette.barTrack)\"/>"
        s += "<rect x=\"\(f(bar.x))\" y=\"\(f(bar.y))\" width=\"\(f(bar.w * frac))\" height=\"6\" rx=\"3\" fill=\"\(LeafPalette.barFill)\"/>"
        s += "<text x=\"\(f(st.x))\" y=\"\(f(st.y + 11))\" font-size=\"11\" fill=\"\(soft)\"><tspan fill=\"\(ink)\" font-weight=\"500\">\(esc(Format.bytes(freeBytes)))</tspan> free</text>"
        s += "<text x=\"\(f(st.x + st.w))\" y=\"\(f(st.y + 11))\" text-anchor=\"end\" font-size=\"11\" fill=\"\(soft)\">of \(esc(Format.bytes(totalBytes)))</text>"
        for (cell, kv) in zip(RestLayout.cells.map(o), RestSummary.cells(r)) {
            s += "<text x=\"\(f(cell.x))\" y=\"\(f(cell.y + 10))\" font-size=\"10\" fill=\"\(soft)\">\(esc(fit(kv.label, cell.w, 10, medium: false)))</text>"
            s += "<text x=\"\(f(cell.x))\" y=\"\(f(cell.y + 23))\" font-size=\"11.5\" font-weight=\"500\" font-variant-numeric=\"tabular-nums\" fill=\"\(ink)\">\(esc(fit(kv.value, cell.w, 11.5)))</text>"
        }
        return (s, RestLayout.frames(in: slot, legend: labels), legend)
    }

    /// D22/D24: the leaf details in the shared slot (same content as the app's DetailStrip). Every frame comes
    /// from StripLayout; each text is cut to its frame's width; returns the frames it drew into.
    static func strip(_ c: HoverCard, pinned: Bool, in r: Rect) -> (svg: String, frames: [Rect]) {
        let soft = LeafPalette.inkSoft, ink = LeafPalette.ink
        let named = StripLayout.named(in: r, branch: c.branch, tag: c.pill, repo: c.repo)
        func at(_ n: String) -> Rect { named.first { $0.name == n }!.rect }
        var s = "<rect x=\"\(f(r.x))\" y=\"\(f(r.y))\" width=\"\(f(r.w))\" height=\"\(f(r.h))\" rx=\"9\" fill=\"\(LeafPalette.cardFill)\" stroke=\"\(pinned ? LeafPalette.ring : LeafPalette.cardStroke)\" stroke-width=\"\(pinned ? 2 : 0.6)\"/>"
        let b = at("branch"), t = at("tag"), rp = at("repo")
        s += "<text x=\"\(f(b.x))\" y=\"\(f(b.y + 12))\" font-size=\"12\" font-weight=\"600\" fill=\"\(ink)\">\(esc(fit(c.branch, b.w, 12)))</text>"
        s += "<rect x=\"\(f(t.x))\" y=\"\(f(t.y + 1))\" width=\"\(f(t.w))\" height=\"14\" rx=\"7\" fill=\"\(LeafPalette.dot(c.status))\" fill-opacity=\".2\"/>"
        s += "<text x=\"\(f(t.x + StripLayout.tagPadding))\" y=\"\(f(t.y + 11.5))\" font-size=\"10\" font-weight=\"500\" fill=\"\(LeafPalette.pillText(c.status))\">\(esc(fit(c.pill, t.w - 2 * StripLayout.tagPadding, 10)))</text>"
        s += "<text x=\"\(f(rp.x))\" y=\"\(f(rp.y + 12))\" font-size=\"11\" fill=\"\(soft)\">\(esc(fit(c.repo, rp.w, 11, medium: false)))</text>"
        let p = at("path")
        s += "<text x=\"\(f(p.x))\" y=\"\(f(p.y + 10))\" font-size=\"10\" font-family=\"'SF Mono', Menlo, 'DejaVu Sans Mono', monospace\" fill=\"\(soft)\">\(esc(clip(c.path, Int(p.w / 6.1))))</text>"
        let stats = [("Size", c.size), ("Changes", c.changes), ("Sync", c.sync), ("Last commit", c.lastCommit)]
        for (k, st) in stats.enumerated() {
            let col = at("column\(k)")
            s += "<text x=\"\(f(col.x))\" y=\"\(f(col.y + 10))\" font-size=\"10\" fill=\"\(soft)\">\(st.0)</text>"
            s += "<text x=\"\(f(col.x))\" y=\"\(f(col.y + 23))\" font-size=\"11.5\" font-weight=\"500\" font-variant-numeric=\"tabular-nums\" fill=\"\(ink)\">\(esc(fit(st.1, col.w, 11.5)))</text>"
        }
        let m = at("message")
        s += "<text x=\"\(f(m.x))\" y=\"\(f(m.y + 11))\" font-size=\"11\" fill=\"\(ink)\">\(esc(fit(c.message.joined(separator: " "), m.w, 11, medium: false)))</text>"
        for (name, b) in StripLayout.buttons(in: r) {
            let enabled = name != "Copy remove command" || c.removeCommand != nil
            s += "<rect x=\"\(f(b.x))\" y=\"\(f(b.y))\" width=\"\(f(b.w))\" height=\"\(f(b.h))\" rx=\"6\" fill=\"\(LeafPalette.background)\" stroke=\"\(LeafPalette.cardStroke)\" stroke-width=\".6\"\(enabled ? "" : " opacity=\".4\"")/>"
            s += text(b.x + b.w / 2, b.y + 15, name, size: 11, color: ink, extra: enabled ? "" : " opacity=\".4\"")
        }
        return (s, named.map(\.rect))
    }

    /// Cuts `t` (with "…") so its estimated width at `size` fits in `w`.
    static func fit(_ t: String, _ w: Double, _ size: Double, medium: Bool = true) -> String {
        if LeafText.width(t, size: size, weight: medium) <= w { return t }
        var out = ""
        for ch in t {
            if LeafText.width(out + String(ch) + "…", size: size, weight: medium) > w { break }
            out.append(ch)
        }
        return out.isEmpty ? "" : out + "…"
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

    public static func mapBody(_ map: LeafMap, hover: String? = nil, pinned: String? = nil) -> String {
        var s = "<filter id=\"ls\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feDropShadow dx=\"0\" dy=\"2\" stdDeviation=\"3\" flood-color=\"#000\" flood-opacity=\".18\"/></filter>"
        // Ringed leaves last so their rings sit on top of their neighbours.
        func rank(_ l: Leaf) -> Int { l.item.id == pinned ? 2 : (l.item.id == hover ? 1 : 0) }
        let order = map.leaves.enumerated().sorted { rank($0.element) < rank($1.element) }
        for (i, leaf) in order {
            let st = leaf.item.state, d = path(leaf.outline)
            let id = leaf.item.id, c = leaf.centroid
            let ring = id == pinned ? LeafPalette.ringPinned : (id == hover ? LeafPalette.ringHover : 0)
            let dim = (hover != nil || pinned != nil) && ring == 0
            s += "<g\(dim ? " opacity=\"\(LeafPalette.dimOthers)\"" : "")>"
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
            if ring > 0 { s += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(LeafPalette.ring)\" stroke-width=\"\(f(ring))\" stroke-linejoin=\"round\"/>" }
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
