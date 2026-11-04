import Foundation

/// D26: the header row from fixed constants, so it fits at 480 pt with no truncation at worst-case counts.
/// Left to right: "N worktrees" (22 pt), "· S stale" (13 pt), the repo filter button ("All 35 repos" /
/// "3 of 35 repos" / a single repo's name), and a compact scan-status icon flush right (its text is the
/// icon's help and sits in the footer row). Each text gets its natural width; nothing is cut.
public enum HeaderLayout {
    public static let width = PopoverLayout.mapWidth, height = PopoverLayout.headerHeight
    public static let countSize = 22.0, subSize = 13.0, filterSize = 11.5
    /// Gaps between items, the filter button's chrome (padding + chevron), the status icon's side.
    public static let gap = 6.0, filterChrome = 22.0, statusSide = 18.0
    /// A single repo's name longer than this shows as "1 of N repos".
    public static let filterMaxText = 130.0
    /// Room for the app's real font: estimated widths × this.
    public static let slack = 1.06

    public static func count(_ r: ScanResult) -> String { let w = r.worktreeCount; return "\(w) worktree\(w == 1 ? "" : "s")" }
    public static func sub(_ r: ScanResult) -> String { r.totals.staleWorktrees > 0 ? "· \(r.totals.staleWorktrees) stale" : "" }
    /// The filter button's label (D26: carries the repo count, which left the headline).
    public static func filterLabel(selected: [String], total: Int) -> String {
        if selected.count == total { return "All \(total) repo\(total == 1 ? "" : "s")" }
        if selected.isEmpty { return "No repos" }
        if selected.count == 1, LeafText.width(selected[0], size: filterSize, weight: false) <= filterMaxText { return selected[0] }
        return "\(selected.count) of \(total) repos"
    }
    public static func filterLabel(_ f: RepoFilter, repos: [Repo]) -> String {
        filterLabel(selected: f.selected(repos).map(\.name), total: repos.count)
    }

    static func w(_ s: String, _ size: Double) -> Double { s.isEmpty ? 0 : (LeafText.width(s, size: size, weight: false) * slack + 2).rounded(.up) }

    /// Text frames (header-relative) for count, sub, filter (text only; the button adds `filterChrome`) and
    /// the status icon.
    public static func frames(count c: String, sub s: String, filter f: String) -> [(name: String, text: String, rect: Rect)] {
        let cw = w(c, countSize), sw = w(s, subSize), fw = w(f, filterSize)
        let sx = cw + gap, fx = sx + sw + (s.isEmpty ? 0 : gap)
        return [("count", c, Rect(x: 0, y: 0, w: cw, h: height)), ("sub", s, Rect(x: sx, y: 6, w: sw, h: 18)),
                ("filter", f, Rect(x: fx, y: 4, w: fw, h: 18)),
                ("status", "", Rect(x: width - statusSide, y: 4, w: statusSide, h: statusSide))]
    }
    /// D28: closes the gap the padded width estimate leaves after the count (and the stale text): with the
    /// drawn natural widths known, the following frames move left so each starts `gap` after the text
    /// before it. Frames only move left and keep their widths, so nothing can truncate; status stays put.
    public static func tightened(_ frames: [(name: String, text: String, rect: Rect)], naturals: [Double?]) -> [(name: String, text: String, rect: Rect)] {
        var out = frames, shift = 0.0
        for i in frames.indices where i < 3 {
            if i > 0 { out[i].rect.x -= shift }
            if i < 2, i < naturals.count, let n = naturals[i], n > 0, n < frames[i].rect.w, !frames[i].text.isEmpty {
                shift += frames[i].rect.w - n.rounded(.up)
            }
        }
        return out
    }

    /// The filter button's whole frame (text + chrome).
    public static func filterButton(_ frames: [(name: String, text: String, rect: Rect)]) -> Rect {
        let t = frames.first { $0.name == "filter" }!.rect
        return Rect(x: t.x, y: t.y, w: t.w + filterChrome, h: t.h)
    }
    /// Measures for the sweep: each text's natural width against its frame; the filter button may not
    /// reach the status icon.
    public static func measures(count c: String, sub s: String, filter f: String) -> [LegendMeasure] {
        let fr = frames(count: c, sub: s, filter: f)
        let sizes = ["count": countSize, "sub": subSize, "filter": filterSize]
        return fr.filter { $0.name != "status" && !$0.text.isEmpty }.map {
            LegendMeasure(label: $0.text, natural: LeafText.width($0.text, size: sizes[$0.name]!, weight: false), frame: $0.name == "filter" ? filterButton(fr) : $0.rect)
        }
    }
    /// The right edge the text items must stay left of.
    public static var contentRight: Double { width - statusSide - gap }
    /// Worst cases: 9,999 worktrees, 999 stale, 999 repos, every filter label shape (and a long single name).
    public static func worstCase() -> [LegendMeasure] {
        let filters = [filterLabel(selected: Array(repeating: "r", count: 999), total: 999), filterLabel(selected: [], total: 999),
                       filterLabel(selected: Array(repeating: "r", count: 998), total: 999),
                       filterLabel(selected: [String(repeating: "W", count: 60)], total: 999), filterLabel(selected: ["mmmmmmmmmmmmmmmmm"], total: 999)]
        return filters.flatMap { measures(count: "9999 worktrees", sub: "· 999 stale", filter: $0) }
    }
    /// Truncated: needs more than its frame, or runs into the status icon.
    public static func truncations(_ m: [LegendMeasure], originX: Double = 0) -> Int {
        m.filter { $0.truncated(rowRight: originX + contentRight) }.count
    }
    /// D26: scan status in short form for the footer (and the icon's help): "Cached · 34/35", "34/35 repos".
    public static func status(progress: String?, cached: Bool) -> String {
        if let p = progress { return cached ? "Cached · \(p)" : p }
        return cached ? "Cached" : ""
    }
}

/// D26: the repo filter menu, an opaque in-popover panel in the light palette (not a vibrancy popover).
public enum RepoMenuLayout {
    public static let width = 300.0, padding = 8.0, topRow = 22.0, search = 26.0, divider = 9.0, row = 22.0, maxRows = 12
    public static let checkSide = 14.0, countWidth = 40.0
    public static func height(rows: Int, searching: Bool) -> Double {
        padding * 2 + topRow + (searching ? search : 0) + divider + Double(min(rows, maxRows)) * row
    }
    /// Top-left in popover-content coordinates (header-relative x, below the header), under the filter button,
    /// kept inside the 448 pt content width.
    public static func origin(filterButton b: Rect) -> Pt { Pt(min(max(0, b.x), PopoverLayout.mapWidth - width), PopoverLayout.headerHeight + 4) }
}

/// D26: the menu's colours (opaque light palette) and their WCAG contrast checks.
public enum RepoMenuStyle {
    public static let background = LeafPalette.cardFill, stroke = LeafPalette.cardStroke
    public static let name = LeafPalette.ink, count = "#5e5c4c", hint = "#5e5c4c"
    public static let hover = "#efe9da", selectedCheck = LeafPalette.ring, uncheckedBox = "#8a8676"

    public struct Contrast: Codable, Equatable, Sendable {
        public var what: String, fg: String, bg: String, ratio: Double, minimum: Double
        public var fails: Bool { ratio < minimum }
        public init(what: String, fg: String, bg: String, ratio: Double, minimum: Double) {
            self.what = what; self.fg = fg; self.bg = bg; self.ratio = ratio; self.minimum = minimum
        }
    }
    public static func luminance(_ hex: String) -> Double {
        let (r, g, b) = LeafPalette.rgb(hex)
        func c(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)
    }
    public static func ratio(_ a: String, _ b: String) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// Text pairs need 4.5:1, the checkbox glyphs 3:1, on the panel and on a hovered row.
    public static func checks(name: String = name, count: String = count, background: String = background, hover: String = hover) -> [Contrast] {
        [("name", name, 4.5), ("count", count, 4.5), ("hint", hint, 4.5), ("checked box", selectedCheck, 3), ("empty box", uncheckedBox, 3)]
            .flatMap { w in [background, hover].map { bg in Contrast(what: w.0, fg: w.1, bg: bg, ratio: ratio(w.1, bg), minimum: w.2) } }
    }
}

/// D26: one repo menu row.
public struct RepoMenuRow: Equatable, Sendable {
    public var name: String, count: Int, selected: Bool
    public init(name: String, count: Int, selected: Bool) { self.name = name; self.count = count; self.selected = selected }
    public static func rows(_ repos: [Repo], filter: RepoFilter) -> [RepoMenuRow] {
        repos.map { RepoMenuRow(name: $0.name, count: $0.worktrees.count, selected: filter.includes($0)) }
    }
}
