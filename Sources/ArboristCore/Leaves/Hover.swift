import Foundation

/// Hover state for the leaf map (D13, D15). The app's mouse tracking and the `--hover-sweep` test hook
/// both drive it through `move(to:in:at:)` / `exit(at:)`, so the logic is the same everywhere and testable on Linux.
///
/// - **Nearest cell.** A point resolves to the leaf under it or, in a gutter or vein, the nearest leaf
///   edge within `LeafMap.hitRadius`. Hit-testing uses the layout outlines, never the lifted (scaled) drawing.
/// - **Sticky inside the map.** Over empty space inside the map the last leaf stays hovered. Only leaving
///   the map clears it, after `leaveDelay` (landing back within that time cancels the clear).
/// - **Stable card.** The card goes in one corner of the map, chosen when hovering starts (the corner away
///   from the leaf). It stays there across a sweep and moves only when the hovered leaf would come within
///   `cardGap` of it. While sweeping, the card doesn't catch the pointer: the leaves under it still hover,
///   and the card then moves away from them.
/// - **Pinned card.** Clicking a leaf pins its card so its buttons can be used. Hover pauses until you click
///   the same leaf or empty space, or the popover closes.
public struct HoverTracker: Equatable, Sendable {
    /// Grace before a leave takes effect.
    public static let leaveDelay = 0.08
    /// Space kept between the card and the hovered leaf's bounding box.
    public static let cardGap = 12.0
    public static let cardMargin = 6.0

    /// Leaf drawn lifted, and the leaf the card describes.
    public private(set) var hovered: String?
    public private(set) var card: String?
    /// When a pending leave takes effect.
    public private(set) var clearAt: Double?
    /// Card's top-left in map coordinates, while a card is shown.
    public private(set) var cardOrigin: Pt?
    /// Card size used for placement (set by the view; a sensible default otherwise).
    public var cardSize = LeafSVG.cardSlot
    /// Card pinned by a click: hover is paused and the card's buttons are live.
    public private(set) var pinned = false
    /// The pointer is under the (unpinned) card. Only happens near the map's centre, which every corner
    /// covers; the view fades the card so the leaf under the pointer stays visible.
    public private(set) var cardUnderPointer = false

    public init() {}

    public var cardRect: Rect? { cardOrigin.map { Rect(x: $0.x, y: $0.y, w: cardSize.x, h: cardSize.y) } }

    /// Pointer at `p` (map coordinates) at time `t`. Returns true when the visible state changed.
    @discardableResult
    public mutating func move(to p: Pt, in map: LeafMap, at t: Double) -> Bool {
        let before = visible
        guard !pinned else { clearAt = nil; return false }
        if let leaf = map.hit(at: p) {
            // On a leaf or within the snap radius: cancels any pending clear.
            clearAt = nil
            show(leaf, in: map, pointer: p)
        } else if hovered != nil {
            // D16: in a gap farther than the snap radius from every leaf, clear after the grace. The deadline
            // is set on entering the gap, so moving around inside it doesn't postpone the clear.
            if clearAt == nil { clearAt = t + Self.leaveDelay }
            settle(at: t)
        }
        cardUnderPointer = cardRect?.contains(p) ?? false
        return before != visible
    }

    /// A click at `p`. On a leaf: pin its card (or unpin if it's already pinned). On empty space: unpin.
    /// On the pinned card itself: nothing (its buttons handle the click). Returns true when the state changed.
    @discardableResult
    public mutating func click(at p: Pt, in map: LeafMap) -> Bool {
        let before = visible
        if pinned, let r = cardRect, r.contains(p) { return false }
        if let leaf = map.hit(at: p) {
            if pinned && leaf.item.id == card { pinned = false } else { pinned = true; show(leaf, in: map, pointer: p) }
        } else {
            pinned = false
        }
        cardUnderPointer = !pinned && (cardRect?.contains(p) ?? false)
        return before != visible
    }

    /// Popover closed or Escape: drop the pin and the hover at once.
    public mutating func reset() { self = HoverTracker(cardSize: cardSize) }

    private init(cardSize: Pt) { self.cardSize = cardSize }

    private mutating func show(_ leaf: Leaf, in map: LeafMap, pointer: Pt) {
        hovered = leaf.item.id; card = leaf.item.id
        let (x0, y0, x1, y1) = Geo.bbox(leaf.outline)
        cardOrigin = Self.anchor(current: cardOrigin, leaf: Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0),
                                 size: cardSize, in: Pt(map.width, map.height), pointer: pointer)
    }

    /// Pointer left the map at `t`: clear after `leaveDelay` (call `settle` then). A pinned card stays.
    public mutating func exit(at t: Double) {
        if hovered != nil, clearAt == nil, !pinned { clearAt = t + Self.leaveDelay }
    }

    /// Hover by id (the List rows). nil starts a leave.
    @discardableResult
    public mutating func pointer(_ id: String?, at t: Double) -> Bool {
        let before = visible
        if let id { hovered = id; card = id; clearAt = nil } else { exit(at: t); settle(at: t) }
        return before != visible
    }

    /// Applies a pending leave if it is due.
    @discardableResult
    public mutating func settle(at t: Double) -> Bool {
        guard let c = clearAt, t >= c else { return false }
        hovered = nil; card = nil; clearAt = nil; cardOrigin = nil; cardUnderPointer = false
        return true
    }

    /// What the view draws; a change here is one animation transaction.
    public struct Visible: Equatable, Sendable {
        public var hovered: String?
        public var card: String?
        public var cardOrigin: Pt?
        public var cardUnderPointer: Bool
        public var pinned: Bool
    }
    public var visible: Visible { Visible(hovered: hovered, card: card, cardOrigin: cardOrigin, cardUnderPointer: cardUnderPointer, pinned: pinned) }
    /// Card opacity: faded while it sits over the pointer.
    public var cardOpacity: Double { cardUnderPointer ? 0.3 : 1 }

    /// Keeps `current` if it stays clear of the leaf; otherwise the map corner farthest from the leaf that's clear,
    /// else the corner with the least overlap.
    public static func anchor(current: Pt?, leaf: Rect, size: Pt, in bounds: Pt, pointer: Pt? = nil) -> Pt {
        let guardBox = Rect(x: leaf.x - cardGap, y: leaf.y - cardGap, w: leaf.w + 2 * cardGap, h: leaf.h + 2 * cardGap)
        func rect(_ o: Pt) -> Rect { Rect(x: o.x, y: o.y, w: size.x, h: size.y) }
        if let c = current, !rect(c).intersects(guardBox, gap: 0) { return c }
        let m = cardMargin, xr = max(m, bounds.x - size.x - m), yb = max(m, bounds.y - size.y - m)
        let corners = [Pt(m, m), Pt(xr, m), Pt(m, yb), Pt(xr, yb)]
        let lc = Pt(leaf.x + leaf.w / 2, leaf.y + leaf.h / 2)
        func dist(_ o: Pt) -> Double { let c = Pt(o.x + size.x / 2, o.y + size.y / 2); return hypot(c.x - lc.x, c.y - lc.y) }
        if let best = corners.filter({ !rect($0).intersects(guardBox, gap: 0) }).max(by: { dist($0) < dist($1) }) { return best }
        // No corner clears a central leaf (the card is over half the map wide). Stay put unless the card covers
        // the pointer (or the leaf's middle), so a sweep through the centre doesn't bounce the card between corners.
        let focus = pointer ?? lc
        let core = Rect(x: focus.x - cardGap, y: focus.y - cardGap, w: 2 * cardGap, h: 2 * cardGap)
        if let c = current, !rect(c).intersects(core, gap: 0) { return c }
        if let best = corners.filter({ !rect($0).intersects(core, gap: 0) }).max(by: { dist($0) < dist($1) }) { return best }
        func overlap(_ o: Pt) -> Double {
            let r = rect(o)
            return max(0, min(r.x + r.w, leaf.x + leaf.w) - max(r.x, leaf.x)) * max(0, min(r.y + r.h, leaf.y + leaf.h) - max(r.y, leaf.y))
        }
        return corners.min { overlap($0) < overlap($1) }!
    }

    /// Opacity and scale for a leaf. With Reduce Motion there is no scale or lift.
    public func appearance(of id: String, reduceMotion: Bool) -> (opacity: Double, scale: Double) {
        guard let h = hovered else { return (1, 1) }
        if h == id { return (1, reduceMotion ? 1 : LeafPalette.hoverScale) }
        return (LeafPalette.dimOthers, 1)
    }

    /// Animation length for a change: the normal fade, or a short opacity-only fade with Reduce Motion.
    public static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0.1 : LeafPalette.hoverFade }
}

/// Test hook (D15): a pointer path across the map, fed through `HoverTracker.move`, one frame per step.
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
        public var cardShown: Bool
        public var cardX: Double?
        public var cardY: Double?
        /// Ground truth, independent of HoverTracker: the leaf whose drawn outline (in view coordinates)
        /// contains the pointer, by plain point-in-polygon. Nil in a gap or off the map.
        public var underPointer: String?
        /// True when the pointer is on the map but inside no outline.
        public var inGap: Bool
        /// In a gap: the leaf the nearest-edge rule picks (`LeafMap.hit`), else nil.
        public var snappedTo: String?

        public init(frame: Int, x: Double, y: Double, viewX: Double? = nil, viewY: Double? = nil, t: Double,
                    hovered: String?, cardShown: Bool, cardX: Double?, cardY: Double?,
                    underPointer: String? = nil, inGap: Bool = false, snappedTo: String? = nil) {
            self.frame = frame; self.x = x; self.y = y; self.viewX = viewX ?? x; self.viewY = viewY ?? y; self.t = t
            self.hovered = hovered; self.cardShown = cardShown; self.cardX = cardX; self.cardY = cardY
            self.underPointer = underPointer; self.inGap = inGap; self.snappedTo = snappedTo
        }

        /// What should be hovered once the grace has passed (D16): the leaf under the pointer, else the
        /// leaf within the snap radius, else nothing.
        public var expected: String? { underPointer ?? snappedTo }
        /// A frame where the hovered leaf differs from the expected one.
        public var isMismatch: Bool { expected != hovered }

        enum CodingKeys: String, CodingKey {
            case frame, x, y, viewX, viewY, t, hovered, cardShown, cardX, cardY, underPointer, inGap, snappedTo, expected
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(frame: try c.decode(Int.self, forKey: .frame), x: try c.decode(Double.self, forKey: .x),
                      y: try c.decode(Double.self, forKey: .y), viewX: try c.decodeIfPresent(Double.self, forKey: .viewX),
                      viewY: try c.decodeIfPresent(Double.self, forKey: .viewY), t: try c.decode(Double.self, forKey: .t),
                      hovered: try c.decodeIfPresent(String.self, forKey: .hovered), cardShown: try c.decode(Bool.self, forKey: .cardShown),
                      cardX: try c.decodeIfPresent(Double.self, forKey: .cardX), cardY: try c.decodeIfPresent(Double.self, forKey: .cardY),
                      underPointer: try c.decodeIfPresent(String.self, forKey: .underPointer),
                      inGap: try c.decodeIfPresent(Bool.self, forKey: .inGap) ?? false,
                      snappedTo: try c.decodeIfPresent(String.self, forKey: .snappedTo))
        }

        /// Writes `null` for missing values instead of leaving the key out.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(frame, forKey: .frame); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
            try c.encode(viewX, forKey: .viewX); try c.encode(viewY, forKey: .viewY)
            try c.encode(t, forKey: .t); try c.encode(hovered, forKey: .hovered); try c.encode(cardShown, forKey: .cardShown)
            try c.encode(cardX, forKey: .cardX); try c.encode(cardY, forKey: .cardY)
            try c.encode(underPointer, forKey: .underPointer); try c.encode(inGap, forKey: .inGap); try c.encode(snappedTo, forKey: .snappedTo)
            try c.encode(expected, forKey: .expected)
        }
    }

    /// frames.json: the frames plus a summary.
    public struct Report: Codable, Equatable, Sendable {
        public var frames: [Frame]
        public var hoveredCount: Int
        /// Frames where `hovered` differs from `underPointer ?? snappedTo` (D16).
        public var mismatches: Int
        public var mismatchFrames: [Int]
        /// Frames with the pointer in a gap between outlines.
        public var gapFrames: Int
        public var distinctHovered: Int

        public init(_ frames: [Frame]) {
            self.frames = frames
            hoveredCount = frames.filter { $0.hovered != nil }.count
            mismatchFrames = frames.filter(\.isMismatch).map(\.frame)
            mismatches = mismatchFrames.count
            gapFrames = frames.filter(\.inGap).count
            distinctHovered = Set(frames.compactMap(\.hovered)).count
        }

        public var summary: String {
            "\(frames.count) frames, \(hoveredCount) hovered, \(distinctHovered) distinct leaves, \(gapFrames) in gaps, "
                + "\(mismatches) mismatches" + (mismatches > 0 ? " (frames \(mismatchFrames.map(String.init).joined(separator: ", ")))" : "")
        }
    }

    /// Ground truth for a pointer at view point `v`: plain point-in-polygon against every leaf's outline
    /// mapped into view coordinates. Deliberately doesn't use HoverTracker, `LeafMap.hit` or `toMap`.
    public static func underPointer(_ v: Pt, in map: LeafMap, _ transform: MapTransform) -> String? {
        map.leaves.first { Geo.inside($0.outline.map(transform.toView), v) }?.item.id
    }

    /// Builds one frame from the tracker state after the pointer moved to `p` (map coordinates, nil = left).
    public static func frame(_ i: Int, pointer p: Pt?, last: Pt, t: Double, tracker: HoverTracker,
                             map: LeafMap, transform: MapTransform = .identity) -> Frame {
        let q = p ?? last
        let v = transform.toView(q)
        let truth = p.map { _ in underPointer(v, in: map, transform) } ?? nil
        let onMap = p != nil && q.x >= 0 && q.y >= 0 && q.x <= map.width && q.y <= map.height
        let gap = onMap && truth == nil
        return Frame(frame: i, x: q.x, y: q.y, viewX: v.x, viewY: v.y, t: t, hovered: tracker.hovered,
                     cardShown: tracker.card != nil, cardX: tracker.cardOrigin?.x, cardY: tracker.cardOrigin?.y,
                     underPointer: truth, inGap: gap, snappedTo: gap ? map.hit(at: q)?.item.id : nil)
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

    /// Runs `path` through a tracker, the way the CLI does. Pointer events go in as view points through
    /// `transform`, like the app's mouse tracking. `apply` sees the tracker after each step.
    public static func run(_ map: LeafMap, path: [Pt?], step: Double = 1.0 / 30, cardSize: Pt = LeafSVG.cardSlot,
                           transform: MapTransform = .identity,
                           apply: (Int, HoverTracker) -> Void = { _, _ in }) -> [Frame] {
        var tracker = HoverTracker()
        tracker.cardSize = cardSize
        var frames: [Frame] = []
        var t = 0.0, last = Pt(-1, -1)
        for (i, p) in path.enumerated() {
            if let p {
                tracker.move(to: transform.toMap(transform.toView(p)), in: map, at: t); last = p
            } else { tracker.exit(at: t) }
            // Instant mode (D16): a pending clear is applied by jumping time past the grace, so each frame
            // shows the settled state.
            if let c = tracker.clearAt { t = max(t, c); tracker.settle(at: t) }
            apply(i, tracker)
            frames.append(frame(i, pointer: p, last: last, t: t, tracker: tracker, map: map, transform: transform))
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
