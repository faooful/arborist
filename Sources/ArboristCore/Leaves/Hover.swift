import Foundation

/// The popover in its own coordinates (D19, D22): where the map sits, the popover's size, and the map's
/// layout → view transform. The panel and footer are placed against it.
public struct PopoverSpace: Equatable, Sendable {
    /// Top-left of the map view in popover coordinates.
    public var mapOrigin: Pt
    /// The popover's size.
    public var size: Pt
    /// Map layout coordinates → map view coordinates (D15).
    public var transform: MapTransform

    public init(mapOrigin: Pt, size: Pt, transform: MapTransform = .identity) {
        self.mapOrigin = mapOrigin; self.size = size; self.transform = transform
    }

    /// A map layout point in popover coordinates.
    public func toPopover(_ p: Pt) -> Pt { mapOrigin + transform.toView(p) }
    /// A popover point in map layout coordinates.
    public func toMap(_ q: Pt) -> Pt { transform.toMap(Pt(q.x - mapOrigin.x, q.y - mapOrigin.y)) }
    /// True when `r` is not entirely inside the popover.
    public func clips(_ r: Rect) -> Bool { !r.inside(width: size.x, height: size.y) }
    /// D22: the detail strip, docked below the 448×400 map (the popover's VStack spacing apart).
    public var stripRect: Rect {
        Rect(x: mapOrigin.x, y: mapOrigin.y + PopoverLayout.mapHeight + PopoverLayout.stripGap,
             w: PopoverLayout.mapWidth, h: PopoverLayout.stripHeight)
    }
    /// D24: the footer buttons' own row, below the slot.
    public var footerRect: Rect {
        Rect(x: mapOrigin.x, y: stripRect.y + stripRect.h + PopoverLayout.stripGap, w: PopoverLayout.mapWidth, h: PopoverLayout.footerRowHeight)
    }
}

/// D24: the detail view in the shared slot below the map, in a strict vertical rhythm built from fixed
/// constants: title row (branch, tag, repo), path, a 4-column grid, the commit message, then the buttons
/// row (left-aligned to the grid, Remove at the right). Coordinates are relative to the slot's top-left
/// unless a function takes the slot rect. Every row is one line, truncated; nothing overlaps at any length.
public enum StripLayout {
    public static let padding = 10.0, gap = 6.0
    public static let titleHeight = 16.0, pathHeight = 14.0, gridHeight = 26.0, messageHeight = 14.0
    /// Extra space below the commit message, before the buttons.
    public static let messageBelow = 8.0
    /// Button height, and the space between buttons / grid columns / title parts.
    public static let row = 22.0, buttonGap = 8.0, columnGap = 8.0, titleGap = 7.0
    public static let inner = PopoverLayout.mapWidth - 2 * padding
    public static let titleY = padding
    public static let pathY = titleY + titleHeight + gap
    public static let gridY = pathY + pathHeight + gap
    public static let messageY = gridY + gridHeight + gap
    public static let buttonsY = messageY + messageHeight + messageBelow
    /// The slot's height: the details exactly fill it.
    public static let height = buttonsY + row + padding
    /// The tag's horizontal padding.
    public static let tagPadding = 6.0

    public static let buttons: [(name: String, x: Double, w: Double)] = [
        ("Reveal in Finder", 0, 120), ("Copy remove command", 120 + buttonGap, 150), ("Remove worktree", inner - 130, 130),
    ]
    public static func buttons(in strip: Rect) -> [(name: String, rect: Rect)] {
        buttons.map { ($0.name, Rect(x: strip.x + padding + $0.x, y: strip.y + buttonsY, w: $0.w, h: row)) }
    }
    public static func button(at p: Pt, in strip: Rect) -> String? { buttons(in: strip).first { $0.rect.contains(p) }?.name }

    public static let rows: [(name: String, rect: Rect)] = [
        ("title", Rect(x: padding, y: titleY, w: inner, h: titleHeight)),
        ("path", Rect(x: padding, y: pathY, w: inner, h: pathHeight)),
        ("stats", Rect(x: padding, y: gridY, w: inner, h: gridHeight)),
        ("message", Rect(x: padding, y: messageY, w: inner, h: messageHeight)),
    ]
    public static func row(_ name: String) -> Rect { rows.first { $0.name == name }!.rect }
    /// The four grid columns (Size, Changes, Sync, Last commit): equal widths, `columnGap` apart.
    public static var columns: [Rect] {
        let r = row("stats"), w = (r.w - 3 * columnGap) / 4
        return (0..<4).map { Rect(x: r.x + Double($0) * (w + columnGap), y: r.y, w: w, h: r.h) }
    }

    /// The title row's parts for these strings: branch, tag, repo (D25: no pinned label; selection is styling). The tag keeps its
    /// natural width; branch and repo share the rest (branch first, at least 60%), each truncated to its frame.
    public static func title(branch: String, tag: String, repo: String) -> [(name: String, rect: Rect)] {
        let r = row("title")
        let end = r.x + r.w
        let tagW = min((LeafText.width(tag, size: 10) + 2 * tagPadding + 1).rounded(.up), 120)
        let avail = max(0, end - r.x - tagW - 2 * titleGap)
        let bNat = LeafText.width(branch, size: 12), rNat = LeafText.width(repo, size: 11, weight: false)
        let bw = min(bNat, max(avail - rNat, avail * 0.6)), rw = max(0, min(rNat, avail - bw))
        let tagX = r.x + bw + titleGap, repoX = tagX + tagW + titleGap
        let out: [(String, Rect)] = [("branch", Rect(x: r.x, y: r.y, w: bw, h: r.h)),
                                     ("tag", Rect(x: tagX, y: r.y, w: tagW, h: r.h)),
                                     ("repo", Rect(x: repoX, y: r.y, w: rw, h: r.h))]
        return out
    }

    /// Every text and button frame in the details, in the slot's coordinates offset by `strip`'s origin.
    public static func named(in strip: Rect, branch: String = "", tag: String = "", repo: String = "") -> [(name: String, rect: Rect)] {
        let rel = title(branch: branch, tag: tag, repo: repo)
            + [("path", row("path"))] + columns.enumerated().map { ("column\($0.offset)", $0.element) } + [("message", row("message"))]
        return rel.map { ($0.0, Rect(x: strip.x + $0.1.x, y: strip.y + $0.1.y, w: $0.1.w, h: $0.1.h)) } + buttons(in: strip)
    }
    public static func frames(in strip: Rect, branch: String = "", tag: String = "", repo: String = "") -> [Rect] {
        named(in: strip, branch: branch, tag: tag, repo: repo).map(\.rect)
    }

    /// Pairs of frames that overlap (positive area), plus frames not entirely inside `slot`.
    public static func overlaps(_ f: [Rect], in slot: Rect) -> Int {
        var n = 0
        for i in f.indices {
            let a = f[i]
            if a.x < slot.x - 0.01 || a.y < slot.y - 0.01 || a.x + a.w > slot.x + slot.w + 0.01 || a.y + a.h > slot.y + slot.h + 0.01 { n += 1 }
            for j in f.indices where j > i {
                let b = f[j]
                if min(a.x + a.w, b.x + b.w) - max(a.x, b.x) > 0.01 && min(a.y + a.h, b.y + b.h) - max(a.y, b.y) > 0.01 { n += 1 }
            }
        }
        return n
    }

    /// D24: the frames that never depend on the leaf (everything below the title row), for the shift check.
    public static func fixedPart(_ f: [Rect]) -> [Rect] {
        guard let top = f.map(\.y).min() else { return [] }
        return f.filter { abs($0.y - top) > 0.01 }
    }
}

/// D24: the footer buttons, in their own row below the slot, so a pin never hides them.
public enum FooterLayout {
    public static let names = ["Clear", "Rescan", "List", "Settings", "Quit"]
    public static func buttons(in r: Rect) -> [(name: String, rect: Rect)] {
        let h = r.h
        return [("Clear", Rect(x: r.x, y: r.y, w: 72, h: h)), ("Rescan", Rect(x: r.x + 80, y: r.y, w: 64, h: h)),
                ("List", Rect(x: r.x + 152, y: r.y, w: 56, h: h)),
                ("Settings", Rect(x: r.x + r.w - 64, y: r.y, w: 28, h: h)), ("Quit", Rect(x: r.x + r.w - 28, y: r.y, w: 28, h: h))]
    }
}

/// D25: the resting panel in the shared slot, never blank: the legend row (state filters only), the
/// storage bar and its labels, then a 2 × 4 summary grid of real values. Fixed rows from these constants,
/// relative to the slot's top-left; the last row ends `gap` above the bottom padding.
public enum RestLayout {
    public static let padding = StripLayout.padding, gap = StripLayout.gap
    public static let legendY = padding, legendHeight = 18.0
    public static let barY = legendY + legendHeight + gap, barHeight = 6.0
    public static let storageY = barY + barHeight + 4, storageHeight = 14.0
    public static let gridHeight = StripLayout.gridHeight
    public static let grid1Y = storageY + storageHeight + gap
    public static let grid2Y = grid1Y + gridHeight + gap
    /// D25: the largest empty vertical run allowed inside the slot's content area (between its paddings).
    public static let maxEmptyGap = 12.0
    /// Legend items: dot 8 + 4, text, 4 + 4 horizontal padding; `itemGap` apart.
    public static let itemChrome = 20.0, itemGap = 9.0, legendSize = 11.0

    public static func row(_ name: String) -> Rect {
        let w = StripLayout.inner
        switch name {
        case "legend": return Rect(x: padding, y: legendY, w: w, h: legendHeight)
        case "bar": return Rect(x: padding, y: barY, w: w, h: barHeight)
        case "storage": return Rect(x: padding, y: storageY, w: w, h: storageHeight)
        case "grid1": return Rect(x: padding, y: grid1Y, w: w, h: gridHeight)
        default: return Rect(x: padding, y: grid2Y, w: w, h: gridHeight)
        }
    }
    /// The 8 summary cells: two rows of the detail grid's 4 columns.
    public static var cells: [Rect] {
        [grid1Y, grid2Y].flatMap { y in StripLayout.columns.map { Rect(x: $0.x, y: y, w: $0.w, h: gridHeight) } }
    }
    /// The legend's labels: Uncommitted, Clean, Stale, Ready (N) (D25: shortened; the grid spells out "Ready to clean"), and Show all when filtered.
    /// (D25: Caches moved to the summary grid so the row fits.)
    public static func legendLabels(ready: Int, showAll: Bool) -> [String] {
        ["Uncommitted", "Clean", "Stale", "Ready (\(ready))"] + (showAll ? ["Show all"] : [])
    }
    /// Each legend item's whole frame (with dot and padding) and its text frame, left to right.
    public static func legend(_ labels: [String]) -> [(label: String, item: Rect, text: Rect)] {
        let r = row("legend")
        var x = r.x
        return labels.map { l in
            // Room for the active (semibold) weight too.
            let w = (LeafText.width(l, size: legendSize, weight: false) * 1.06 + 2).rounded(.up)
            let item = Rect(x: x, y: r.y, w: w + itemChrome, h: r.h)
            x += item.w + itemGap
            return (l, item, Rect(x: item.x + 16, y: r.y, w: w, h: r.h))
        }
    }
    /// Every content frame of the resting panel (legend items, bar, storage row, 8 cells), offset by `slot`.
    public static func frames(in slot: Rect, legend labels: [String]) -> [Rect] {
        (legend(labels).map(\.item) + [row("bar"), row("storage")] + cells)
            .map { Rect(x: slot.x + $0.x, y: slot.y + $0.y, w: $0.w, h: $0.h) }
    }
    /// The largest empty vertical run inside the slot's content area (between the top and bottom padding).
    public static func emptyGap(_ frames: [Rect], in slot: Rect) -> Double {
        let top = slot.y + padding, bottom = slot.y + slot.h - padding
        var y = top, gap = 0.0
        for f in frames.sorted(by: { $0.y < $1.y }) {
            gap = max(gap, f.y - y); y = max(y, f.y + f.h)
        }
        return max(gap, bottom - y)
    }
}

/// D25: the resting panel's summary grid, from the shown (filtered) scan: real computed values.
public enum RestSummary {
    public static func cells(_ r: ScanResult) -> [(label: String, value: String)] {
        let all = r.repos.flatMap(\.worktrees), t = r.totals
        let ready = all.filter(CleanupSafety.isReady)
        func n(_ k: StateKey) -> String { "\(all.filter { StateKey.colour($0) == k }.count)" }
        return [("Worktrees", "\(all.count) in \(r.repos.count) repos"), ("Size", Format.bytes(t.projectsSource + t.projectsRebuildable)),
                ("Rebuildable", Format.bytes(t.projectsRebuildable)),
                ("Ready to clean", "\(ready.count) · \(Format.bytes(ready.reduce(0) { $0 + $1.size.total }))"),
                ("Uncommitted", n(.uncommitted)), ("Clean", n(.clean)), ("Stale", n(.stale)), ("Caches", Format.bytes(t.caches))]
    }
}

/// D25: how the panel changes between two frames: a crossfade only between rest and details; from one
/// leaf to another the values swap instantly (and nothing animates with Reduce Motion).
public enum PanelTransition: String, Codable, Sendable {
    case none, crossfade
    public static func between(_ a: String?, _ b: String?, reduceMotion: Bool = false) -> PanelTransition {
        !reduceMotion && (a == nil) != (b == nil) ? .crossfade : .none
    }
}

/// D25: one legend item as drawn: its label's natural width and the text frame it got.
public struct LegendMeasure: Codable, Equatable, Sendable {
    public var label: String, natural: Double, frame: Rect
    public init(label: String, natural: Double, frame: Rect) { self.label = label; self.natural = natural; self.frame = frame }
    /// Truncated: the label needs more than its frame, or the frame runs past the slot's content edge.
    public func truncated(rowRight: Double) -> Bool { natural > frame.w + 0.5 || frame.x + frame.w > rowRight + 0.5 }
}

/// D24: one title-row layout case (a leaf, or a synthetic extreme) and how many overlaps it has.
public struct LayoutCase: Codable, Equatable, Sendable {
    public var name: String
    public var overlaps: Int
    public init(name: String, overlaps: Int) { self.name = name; self.overlaps = overlaps }

    /// Every leaf (pinned and not) plus synthetic extremes: the longest and shortest branch, tag, repo.
    public static func all(_ r: ScanResult, map: LeafMap, now: Date = Date()) -> [LayoutCase] {
        let slot = Rect(x: 0, y: 0, w: PopoverLayout.mapWidth, h: PopoverLayout.stripHeight)
        var strings: [(String, String, String, String)] = map.leaves.compactMap { l in
            WorktreeList.find(r, path: l.item.id).map { let c = HoverCard($0, now: now, home: LeafSample.home); return (l.item.id, c.branch, c.pill, c.repo) }
        }
        let long = String(repeating: "W", count: 240), mid = "feature/" + String(repeating: "m", count: 60)
        for (n, b, t, p) in [("extreme long/long", long, "Uncommitted", long), ("extreme long/short", long, "Clean", "r"),
                             ("extreme short/long", "b", "Unpushed", long), ("extreme short/short", "b", "M", "r"),
                             ("extreme empty", "", "", ""), ("extreme mid/long tag", mid, String(repeating: "T", count: 80), mid)] {
            strings.append((n, b, t, p))
        }
        return strings.map { s in
            LayoutCase(name: s.0, overlaps: StripLayout.overlaps(StripLayout.frames(in: slot, branch: s.1, tag: s.2, repo: s.3), in: slot))
        }
    }
}

/// Hover state for the leaf map (D13, D15, D16, D22). The app's mouse tracking and the `--hover-sweep` hook
/// both drive it through `move(to:in:at:)` / `exit(at:)`, so the logic is the same everywhere and testable on Linux.
///
/// - **Leaf under the pointer.** A point resolves to the leaf under it or, in a gutter, the nearest leaf
///   edge within `LeafMap.hitRadius`, at once (no dwell). In a far gap or off the map it clears after `leaveDelay`.
/// - **Panel.** The bottom panel shows `strip`: the selected (pinned) leaf, else the hovered one (D25: no
///   floating tooltip; the panel is the only readout, DaisyDisk-style).
/// - **Select.** Clicking a leaf selects it (again: deselect); clicking empty space or Esc clears it.
///   Hover still outlines other leaves while one is selected.
public struct HoverTracker: Equatable, Sendable {
    /// Grace before a leave takes effect (D16).
    public static let leaveDelay = 0.08

    public private(set) var hovered: String?
    public private(set) var pinned: String?
    /// When a pending leave takes effect.
    public private(set) var clearAt: Double?
    /// Pointer in map coordinates while it is on the map.
    public private(set) var pointer: Pt?
    /// The popover the panel is placed in (sweep checks).
    public var space: PopoverSpace?

    public init() {}

    /// What the detail strip shows.
    public var strip: String? { pinned ?? hovered }

    /// Pointer at `p` (map coordinates) at time `t`. Returns true when the visible state changed.
    @discardableResult
    public mutating func move(to p: Pt, in map: LeafMap, at t: Double) -> Bool {
        let before = visible
        pointer = p
        if let leaf = map.hit(at: p) {
            clearAt = nil
            hovered = leaf.item.id
        } else if hovered != nil {
            // D16: in a far gap, clear after the grace; moving inside the gap doesn't postpone it.
            if clearAt == nil { clearAt = t + Self.leaveDelay }
            settle(at: t)
        }
        return before != visible
    }

    /// A click at `p`. On a leaf: pin it (or unpin if it is the pinned one). Elsewhere: unpin.
    @discardableResult
    public mutating func click(at p: Pt, in map: LeafMap) -> Bool {
        let before = visible
        if let leaf = map.hit(at: p) {
            let id = leaf.item.id
            pinned = pinned == id ? nil : id
            hovered = id; clearAt = nil; pointer = p
        } else {
            pinned = nil
        }
        return before != visible
    }

    /// Esc: unpin, keep the hover.
    public mutating func unpin() { pinned = nil }

    /// Popover closed: drop the pin and the hover at once.
    public mutating func reset() { let s = space; self = HoverTracker(); space = s }

    /// Pointer left the map at `t`: the hover clears after `leaveDelay`. A selection stays.
    public mutating func exit(at t: Double) {
        pointer = nil
        if hovered != nil, clearAt == nil { clearAt = t + Self.leaveDelay }
    }

    /// Hover by id (the List rows). nil starts a leave.
    @discardableResult
    public mutating func pointer(_ id: String?, at t: Double) -> Bool {
        let before = visible
        if let id { hovered = id; clearAt = nil } else { exit(at: t); settle(at: t) }
        return before != visible
    }

    /// Applies a pending leave if it is due.
    @discardableResult
    public mutating func settle(at t: Double) -> Bool {
        guard let c = clearAt, t >= c else { return false }
        hovered = nil; clearAt = nil
        return true
    }

    /// What the view draws; a change here is one animation transaction.
    public struct Visible: Equatable, Sendable {
        public var hovered: String?
        public var pinned: String?
        public var strip: String?
    }
    public var visible: Visible { Visible(hovered: hovered, pinned: pinned, strip: strip) }

    /// D22: how a leaf is drawn: others dimmed slightly, a ring on the hovered (2 pt) and pinned (stronger) leaf.
    public func appearance(of id: String) -> (opacity: Double, ring: Double) {
        if id == pinned { return (1, LeafPalette.ringPinned) }
        if id == hovered { return (1, LeafPalette.ringHover) }
        return (hovered == nil && pinned == nil ? 1 : LeafPalette.dimOthers, 0)
    }

    /// Animation length for a change: the normal fade, or none with Reduce Motion.
    public static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0 : LeafPalette.hoverFade }
}

/// Test hook (D15, D22): a pointer path across the map, fed through `HoverTracker`, one frame per step.
public enum HoverSweep {
    public struct Frame: Codable, Equatable, Sendable {
        public var frame: Int
        /// Pointer in layout (map) coordinates.
        public var x: Double
        public var y: Double
        /// The same pointer in the map view's coordinates (through the MapTransform).
        public var viewX: Double
        public var viewY: Double
        public var t: Double
        public var hovered: String?
        public var pinned: String?
        /// The id the detail strip shows.
        public var strip: String?
        /// Ground truth, independent of HoverTracker: the leaf whose drawn outline contains the pointer.
        public var underPointer: String?
        /// The pointer is on the map but inside no outline.
        public var inGap: Bool
        /// In a gap: the leaf the nearest-edge rule picks, else nil.
        public var snappedTo: String?
        /// The leaf the sweep pinned (its own record, not the tracker's).
        public var pinTruth: String?
        /// The strip button under the pointer, if any.
        public var buttonUnderPointer: String?
        /// End of the pin + reach-the-strip path: must be on a button with the pin held.
        public var reachTarget: Bool
        /// D24: the strip's drawn height (0 at rest).
        public var stripHeight: Double = 0
        /// D24: the map's frame in popover coordinates, as drawn.
        public var mapFrame: Rect?
        /// D24: the strip's text and button frames as drawn (nil when hidden).
        public var stripFrames: [Rect]?
        /// D24: the shared slot's frame as drawn (same at rest, hover and pin).
        public var slotFrame: Rect?
        /// D24: the footer buttons' frames as drawn (nil or short: hidden).
        public var footerButtons: [Rect]?
        /// D24: overlapping or out-of-slot pairs among the drawn detail frames.
        public var overlaps = 0
        /// D24: a footer button is missing, empty, outside the popover or under the slot.
        public var footerHidden = false
        /// D25: at rest, the largest empty vertical run in the panel (nil when details show or not measured).
        public var idleEmptyGap: Double?
        /// D25: legend items whose label doesn't fit its frame, and the measures (idle frames).
        public var legendTruncated = 0
        public var legend: [LegendMeasure]?
        /// D25: the panel transition applied for this frame.
        public var transition: PanelTransition = .none

        public init(frame: Int, x: Double, y: Double, viewX: Double? = nil, viewY: Double? = nil, t: Double,
                    hovered: String?, pinned: String? = nil, strip: String? = nil, underPointer: String? = nil,
                    inGap: Bool = false, snappedTo: String? = nil, pinTruth: String? = nil,
                    buttonUnderPointer: String? = nil, reachTarget: Bool = false) {
            self.frame = frame; self.x = x; self.y = y; self.viewX = viewX ?? x; self.viewY = viewY ?? y; self.t = t
            self.hovered = hovered; self.pinned = pinned; self.strip = strip; self.underPointer = underPointer
            self.inGap = inGap; self.snappedTo = snappedTo; self.pinTruth = pinTruth
            self.buttonUnderPointer = buttonUnderPointer; self.reachTarget = reachTarget
        }

        /// What should be hovered once the grace has passed (D16): the leaf under the pointer, else the snap.
        /// Writes every field, nil as null, so frames.json shows when nothing is hovered (D15).
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(frame, forKey: .frame); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(viewX, forKey: .viewX); try c.encode(viewY, forKey: .viewY); try c.encode(t, forKey: .t)
            try c.encode(hovered, forKey: .hovered); try c.encode(pinned, forKey: .pinned); try c.encode(strip, forKey: .strip)
            try c.encode(underPointer, forKey: .underPointer); try c.encode(inGap, forKey: .inGap)
            try c.encode(snappedTo, forKey: .snappedTo); try c.encode(pinTruth, forKey: .pinTruth)
            try c.encode(buttonUnderPointer, forKey: .buttonUnderPointer); try c.encode(reachTarget, forKey: .reachTarget)
            try c.encode(stripHeight, forKey: .stripHeight); try c.encode(mapFrame, forKey: .mapFrame); try c.encode(stripFrames, forKey: .stripFrames)
            try c.encode(slotFrame, forKey: .slotFrame); try c.encode(footerButtons, forKey: .footerButtons)
            try c.encode(overlaps, forKey: .overlaps); try c.encode(footerHidden, forKey: .footerHidden)
            try c.encode(idleEmptyGap, forKey: .idleEmptyGap); try c.encode(legendTruncated, forKey: .legendTruncated)
            try c.encode(legend, forKey: .legend)
            try c.encode(transition, forKey: .transition)
        }

        public var expected: String? { underPointer ?? snappedTo }
        public var isMismatch: Bool { expected != hovered }
        /// What the strip should show: the pinned leaf, else the expected hover.
        public var expectedStrip: String? { pinTruth ?? expected }
        public var isStripMismatch: Bool { expectedStrip != strip }
        /// D24: the strip is shown exactly when it has a leaf, at its full height, and takes 0 at rest.
        /// D24: the details are drawn exactly when there's a leaf (legend at rest), at the slot's full height.
        public var isIdleStripViolation: Bool {
            strip == nil ? (stripHeight != 0 || stripFrames != nil) : (stripHeight != PopoverLayout.stripHeight || stripFrames == nil)
        }
        public var isReachFailure: Bool { reachTarget && (buttonUnderPointer == nil || pinTruth == nil || strip != pinTruth || pinned != pinTruth) }
    }

    /// frames.json: the frames plus a summary.
    public struct Report: Codable, Equatable, Sendable {
        public var frames: [Frame]
        public var hoveredCount: Int
        public var mismatches: Int
        public var mismatchFrames: [Int]
        public var gapFrames: Int
        public var distinctHovered: Int
        /// D22: frames whose strip shows something other than pinned ?? expected. Expected 0.
        public var stripMismatches: Int
        /// D22: reach targets that missed a strip button or lost the pin. Expected 0.
        public var reachFailures: Int
        /// D22: reach targets on a button with the pin held.
        public var buttonHits: Int
        /// D24: frames where the strip has height at rest, or the wrong height when shown. Expected 0.
        public var idleStripViolations: Int
        /// D24: frames where the map frame differs from frame 0's (idle, hover, pin). Expected 0.
        public var mapFrameShifts: Int
        /// D24: shown-strip frames whose text/button frames differ from the first shown one's. Expected 0.
        public var stripLayoutShifts: Int
        public var idleFrames: Int
        public var pinnedFrames: Int
        /// D24: frames whose slot frame differs from frame 0's (rest, hover, pin). Expected 0.
        public var slotFrameShifts: Int
        /// D24: frames where a footer button isn't visible (pinned ones included). Expected 0.
        public var footerHiddenFrames: Int
        /// D24: text/button overlaps in drawn frames plus every layout case. Expected 0.
        public var overlaps: Int
        public var layoutCases: [LayoutCase]
        /// D25: idle frames whose panel has an empty vertical run over RestLayout.maxEmptyGap. Expected 0.
        public var idleEmptyGapViolations: Int
        public var maxIdleEmptyGap: Double
        /// D25: truncated legend items, summed over idle frames. Expected 0.
        public var legendTruncations: Int
        /// D25: leaf → different leaf frames that animated (must swap instantly). Expected 0.
        public var hoverTransitions: Int
        /// D25: leaf → leaf frames checked, and rest ↔ details frames (which may crossfade).
        public var hoverSwaps: Int
        public var restSwaps: Int

        public init(_ frames: [Frame], cases: [LayoutCase] = []) {
            self.frames = frames
            layoutCases = cases
            hoveredCount = frames.filter { $0.hovered != nil }.count
            mismatchFrames = frames.filter(\.isMismatch).map(\.frame)
            mismatches = mismatchFrames.count
            gapFrames = frames.filter(\.inGap).count
            distinctHovered = Set(frames.compactMap(\.hovered)).count
            stripMismatches = frames.filter(\.isStripMismatch).count
            reachFailures = frames.filter(\.isReachFailure).count + (frames.contains(where: \.reachTarget) ? 0 : 1)
            buttonHits = frames.filter { $0.reachTarget && !$0.isReachFailure }.count
            idleStripViolations = frames.filter(\.isIdleStripViolation).count
            let map0 = frames.first?.mapFrame
            mapFrameShifts = frames.filter { $0.mapFrame == nil || $0.mapFrame != map0 }.count
            let shown = frames.compactMap(\.stripFrames).map(StripLayout.fixedPart)
            stripLayoutShifts = shown.filter { $0 != shown.first }.count + frames.filter { $0.strip != nil && $0.stripFrames == nil }.count
            idleFrames = frames.filter { $0.strip == nil }.count
            pinnedFrames = frames.filter { $0.pinned != nil }.count
            let slot0 = frames.first?.slotFrame
            slotFrameShifts = frames.filter { $0.slotFrame == nil || $0.slotFrame != slot0 }.count
            footerHiddenFrames = frames.filter(\.footerHidden).count
            overlaps = frames.map(\.overlaps).reduce(0, +) + cases.map(\.overlaps).reduce(0, +)
            let gaps = frames.compactMap(\.idleEmptyGap)
            idleEmptyGapViolations = gaps.filter { $0 > RestLayout.maxEmptyGap + 0.01 }.count
                + frames.filter { $0.strip == nil && $0.idleEmptyGap == nil }.count
            maxIdleEmptyGap = gaps.max() ?? 0
            legendTruncations = frames.map(\.legendTruncated).reduce(0, +)
            let pairs = zip(frames, frames.dropFirst())
            let swaps = pairs.filter { $0.strip != nil && $1.strip != nil && $0.strip != $1.strip }
            hoverSwaps = swaps.count
            hoverTransitions = swaps.filter { $1.transition != .none }.count
            restSwaps = pairs.filter { ($0.strip == nil) != ($1.strip == nil) }.count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            self.init(try c.decode([Frame].self, forKey: .frames), cases: try c.decodeIfPresent([LayoutCase].self, forKey: .layoutCases) ?? [])
        }
        enum K: String, CodingKey { case frames, layoutCases }

        public var summary: String {
            "\(frames.count) frames, \(hoveredCount) hovered, \(distinctHovered) distinct leaves, \(gapFrames) in gaps, "
                + "\(mismatches) mismatches, \(stripMismatches) strip mismatches, "
                + "\(reachFailures) reach failures, \(buttonHits) button hits, "
                + "\(idleFrames) idle / \(pinnedFrames) pinned, \(idleStripViolations) idle-strip violations, "
                + "\(mapFrameShifts) map frame shifts, \(stripLayoutShifts) strip layout shifts, "
                + "\(slotFrameShifts) slot frame shifts, \(footerHiddenFrames) footer-hidden frames, "
                + "\(overlaps) overlaps (\(layoutCases.count) layout cases), "
                + "\(idleEmptyGapViolations) idle-gap violations (max \(String(format: "%.0f", maxIdleEmptyGap)) pt), "
                + "\(legendTruncations) legend truncations, \(hoverTransitions) hover transitions (\(hoverSwaps) leaf swaps, \(restSwaps) rest swaps)"
                + (mismatches > 0 ? " (frames \(mismatchFrames.map(String.init).joined(separator: ", ")))" : "")
        }
    }

    /// Ground truth for a pointer at view point `v`: plain point-in-polygon against every leaf's outline
    /// mapped into view coordinates. Deliberately doesn't use HoverTracker, `LeafMap.hit` or `toMap`.
    public static func underPointer(_ v: Pt, in map: LeafMap, _ transform: MapTransform) -> String? {
        map.leaves.first { Geo.inside($0.outline.map(transform.toView), v) }?.item.id
    }

    /// One frame from the tracker state after the pointer moved to `p` (map coordinates, nil = left the popover).
    public static func frame(_ i: Int, pointer p: Pt?, last: Pt, t: Double, tracker: HoverTracker,
                             map: LeafMap, transform: MapTransform = .identity,
                             pinTruth: String? = nil, reachTarget: Bool = false, drawn: Drawn? = nil) -> Frame {
        let q = p ?? last
        let v = transform.toView(q)
        let onMap = p != nil && q.x >= 0 && q.y >= 0 && q.x <= map.width && q.y <= map.height
        let truth = onMap ? underPointer(v, in: map, transform) : nil
        let gap = onMap && truth == nil
        let button = p.flatMap { pp in tracker.space.flatMap { s in StripLayout.button(at: s.toPopover(pp), in: s.stripRect) } }
        var fr = Frame(frame: i, x: q.x, y: q.y, viewX: v.x, viewY: v.y, t: t, hovered: tracker.hovered,
                     pinned: tracker.pinned, strip: tracker.strip, underPointer: truth, inGap: gap,
                     snappedTo: gap ? map.hit(at: q)?.item.id : nil, pinTruth: pinTruth,
                     buttonUnderPointer: button, reachTarget: reachTarget)
        if let d = drawn {
            fr.stripHeight = d.stripHeight; fr.mapFrame = d.mapFrame; fr.stripFrames = d.stripFrames.map(Self.sorted)
            fr.slotFrame = d.slotFrame; fr.footerButtons = d.footerButtons
            if let sf = d.stripFrames, let slot = d.slotFrame { fr.overlaps = StripLayout.overlaps(sf, in: slot) }
            fr.footerHidden = footerHidden(d.footerButtons, slot: d.slotFrame, popover: tracker.space?.size)
            if tracker.strip == nil, let slot = d.slotFrame {
                fr.idleEmptyGap = d.restFrames.map { RestLayout.emptyGap($0, in: slot) } ?? slot.h
                let right = slot.x + slot.w - RestLayout.padding
                fr.legend = d.legend
                fr.legendTruncated = d.legend.map { $0.filter { $0.truncated(rowRight: right) }.count } ?? 1
            }
            fr.transition = d.transition
        }
        return fr
    }

    /// D24: true unless all five footer buttons have a real frame inside the popover and clear of the slot.
    public static func footerHidden(_ b: [Rect]?, slot: Rect?, popover: Pt?) -> Bool {
        guard let b, b.count == FooterLayout.names.count else { return true }
        return b.contains { r in
            r.w <= 0 || r.h <= 0 || (popover.map { !r.inside(width: $0.x + 0.01, height: $0.y + 0.01) } ?? false)
                || (slot.map { r.intersects($0) } ?? false)
        }
    }

    /// D24: frames in reading order, so renderers that report in any order compare equal.
    public static func sorted(_ r: [Rect]) -> [Rect] { r.sorted { ($0.y, $0.x, $0.w, $0.h) < ($1.y, $1.x, $1.w, $1.h) } }

    /// D24: what the renderer (SVG in the CLI, SwiftUI in the app) actually drew for a frame.
    public struct Drawn: Equatable, Sendable {
        public var mapFrame: Rect
        public var stripHeight: Double
        public var stripFrames: [Rect]?
        public var slotFrame: Rect?
        public var footerButtons: [Rect]?
        /// D25: the resting panel's content frames and legend items (nil while details show).
        public var restFrames: [Rect]?
        public var legend: [LegendMeasure]?
        /// D25: the panel transition the renderer applied for this frame.
        public var transition: PanelTransition = .none
        public init(mapFrame: Rect, stripHeight: Double, stripFrames: [Rect]?, slotFrame: Rect? = nil, footerButtons: [Rect]? = nil,
                    restFrames: [Rect]? = nil, legend: [LegendMeasure]? = nil, transition: PanelTransition = .none) {
            self.mapFrame = mapFrame; self.stripHeight = stripHeight; self.stripFrames = stripFrames
            self.slotFrame = slotFrame; self.footerButtons = footerButtons
            self.restFrames = restFrames; self.legend = legend; self.transition = transition
        }
    }

    /// Serpentine across `rows` horizontal lines, then one point off the map and a settle after the grace.
    public static func path(in map: LeafMap, rows: Int = 3, perRow: Int = 16) -> [Pt?] {
        var pts: [Pt?] = []
        for r in 0..<rows {
            let y = map.height * (Double(r) + 0.5) / Double(rows)
            for i in 0..<perRow {
                let f = Double(i) / Double(perRow - 1)
                pts.append(Pt(map.width * (r % 2 == 0 ? f : 1 - f), y))
            }
        }
        pts.append(nil) // pointer leaves the map
        pts.append(nil) // after the grace
        return pts
    }

    /// One step of a sweep: a pointer move, a click, or leaving.
    public enum Step: Equatable, Sendable {
        case move(Pt)
        case click(Pt)
        case leave
        /// D24: Esc (unpin).
        case escape
    }

    /// D22: the pin + reach path: click the leaf to pin it, then move in `steps` frames from it to the strip's
    /// first button (popover space required). The last step is the reach target. Map coordinates.
    public static func pinAndReach(_ map: LeafMap, space: PopoverSpace, steps: Int = 6) -> (leaf: String, steps: [Step])? {
        guard let leaf = map.leaves.first(where: { map.hit(at: $0.centroid)?.item.id == $0.item.id }),
              let target = StripLayout.buttons(in: space.stripRect).first?.rect.center else { return nil }
        let from = space.toPopover(leaf.centroid)
        var out: [Step] = [.move(leaf.centroid), .click(leaf.centroid)]
        for i in 1...steps {
            let f = Double(i) / Double(steps)
            out.append(.move(space.toMap(Pt(from.x + (target.x - from.x) * f, from.y + (target.y - from.y) * f))))
        }
        return (leaf.item.id, out)
    }

    /// The whole sweep: the serpentine, then (with a space) pin + reach, then leave.
    public static func steps(_ map: LeafMap, space: PopoverSpace?, rows: Int = 3, perRow: Int = 16) -> (steps: [Step], pinned: String?) {
        let serp = path(in: map, rows: rows, perRow: perRow)
        // D24: one idle frame first (strip at rest), and Esc + leave at the end (back to rest).
        var out: [Step] = [.leave] + serp.compactMap { $0 }.map { .move($0) }
        var pinned: String?
        if let s = space, let r = pinAndReach(map, space: s) { out += r.steps + [.escape]; pinned = r.leaf }
        out += [.leave, .leave]
        return (out, pinned)
    }

    /// True when `p` (map coordinates) is on the map; off-map points (the strip) reach the tracker as an exit,
    /// the way the app's map tracking area reports them.
    public static func onMap(_ p: Pt, _ map: LeafMap) -> Bool { p.x >= 0 && p.y >= 0 && p.x <= map.width && p.y <= map.height }

    /// Runs the sweep through a tracker, the way the CLI does. `apply` sees the tracker and pointer after each step.
    public static func run(_ map: LeafMap, step: Double = 1.0 / 30, transform: MapTransform = .identity,
                           space: PopoverSpace? = nil, rows: Int = 3, perRow: Int = 16,
                           apply: (Int, HoverTracker, Pt?) -> Drawn? = { _, _, _ in nil }) -> [Frame] {
        var tracker = HoverTracker()
        tracker.space = space
        let (steps, pinLeaf) = steps(map, space: space, rows: rows, perRow: perRow)
        let reachAt = space == nil ? nil : steps.lastIndex { if case .move = $0 { return true }; return false }
        var frames: [Frame] = []
        var t = 0.0, last = Pt(-1, -1), pinTruth: String?
        for (i, s) in steps.enumerated() {
            var p: Pt?
            switch s {
            case .move(let q):
                p = q; last = q
                if onMap(q, map) { tracker.move(to: transform.toMap(transform.toView(q)), in: map, at: t) } else { tracker.exit(at: t) }
            case .click(let q):
                p = q; last = q
                tracker.click(at: q, in: map)
                pinTruth = pinTruth == nil ? pinLeaf : nil
            case .leave:
                tracker.exit(at: t)
            case .escape:
                tracker.unpin(); pinTruth = nil
            }
            // Instant mode (D16): a pending clear is applied by jumping time past the grace.
            if let c = tracker.clearAt { t = max(t, c); tracker.settle(at: t) }
            let drawn = apply(i, tracker, p)
            frames.append(frame(i, pointer: p, last: last, t: t, tracker: tracker, map: map, transform: transform,
                                pinTruth: pinTruth, reachTarget: i == reachAt, drawn: drawn))
            t += p == nil ? HoverTracker.leaveDelay + 0.01 : step
        }
        return frames
    }

    public static func json(_ frames: [Frame]) -> Data { json(Report(frames)) }

    public static func json(_ report: Report) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try! e.encode(report)
    }
}
