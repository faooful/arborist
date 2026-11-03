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
/// - **Reachable card (D20).** The card takes priority over the leaves under it: a pointer on the card keeps
///   it, so its buttons can be clicked without pinning. Between the hovered leaf and the card is a corridor
///   (the convex hull of both rects); crossing other leaves inside it holds the card for `cardGrace`.
///   Elsewhere, moving to another leaf switches only after `switchDwell` on it.
/// - **Pinned card.** Clicking a leaf pins its card so its buttons can be used. Hover pauses until you click
///   the same leaf or empty space, or the popover closes.
public struct HoverTracker: Equatable, Sendable {
    /// Grace before a leave takes effect.
    public static let leaveDelay = 0.08
    /// Space kept between the card and the hovered leaf's bounding box.
    public static let cardGap = 12.0
    public static let cardMargin = 6.0
    /// D20: how long the corridor from the leaf to the card holds the card, and the grace on leaving the map.
    public static let cardGrace = 0.25
    /// D20: how long the pointer must rest on another leaf before the card switches to it.
    public static let switchDwell = 0.12

    /// Leaf drawn lifted, and the leaf the card describes.
    public private(set) var hovered: String?
    public private(set) var card: String?
    /// When a pending leave takes effect.
    public private(set) var clearAt: Double?
    /// Card's top-left while a card is shown: in popover coordinates when `space` is set (D19), else map coordinates.
    public private(set) var cardOrigin: Pt?
    /// Card size used for placement (set by the view; a sensible default otherwise).
    public var cardSize = LeafSVG.cardSlot
    /// The popover the card is placed in (D19). Nil: the old in-map corner anchoring (map coordinates).
    public var space: CardSpace?
    /// Card pinned by a click: hover is paused and the card's buttons are live.
    public private(set) var pinned = false
    /// The pointer is under the (unpinned) card. Only happens near the map's centre, which every corner
    /// covers; the view fades the card so the leaf under the pointer stays visible.
    public private(set) var cardUnderPointer = false
    /// D20: the pointer is on the shown card (it has priority over the leaves under it).
    public private(set) var onCard = false
    /// D20: the pointer is in the corridor from the hovered leaf to the card and the card is held.
    public private(set) var holding = false
    /// D20: when the corridor hold runs out.
    public private(set) var corridorUntil: Double?
    /// D20: when a pending switch to another leaf takes effect.
    public private(set) var switchAt: Double?
    /// The hovered leaf's bounding box, in the card's coordinate space.
    public private(set) var leafRect: Rect?
    private var pending: Leaf?
    private var pendingPointer = Pt(0, 0)
    private var bounds = Pt(0, 0)

    public init() {}

    /// The next time `settle` has something to do.
    public var nextDeadline: Double? { [clearAt, switchAt].compactMap { $0 }.min() }

    /// D20: true when `q` (card space) is in the convex hull of the hovered leaf's rect and the card's rect.
    public func inCorridor(_ q: Pt) -> Bool {
        guard card != nil, let l = leafRect, let c = cardRect else { return false }
        return Geo.inside(Self.hull(l.corners + c.corners), q)
    }

    /// Convex hull (monotone chain), counter-clockwise.
    public static func hull(_ pts: [Pt]) -> [Pt] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: Pt, _ a: Pt, _ b: Pt) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [Pt] = [], upper: [Pt] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        return Array(lower.dropLast() + upper.dropLast())
    }

    public var cardRect: Rect? { cardOrigin.map { Rect(x: $0.x, y: $0.y, w: cardSize.x, h: cardSize.y) } }

    /// Pointer at `p` (map coordinates) at time `t`. Returns true when the visible state changed.
    @discardableResult
    public mutating func move(to p: Pt, in map: LeafMap, at t: Double) -> Bool {
        let before = visible
        guard !pinned else { clearAt = nil; return false }
        let q = cardPoint(p)
        bounds = Pt(map.width, map.height)
        cardUnderPointer = false
        // D20: the card has priority over whatever is under it.
        onCard = card != nil && (cardRect?.contains(q) ?? false)
        if onCard {
            clearAt = nil; holding = false; corridorUntil = nil; pending = nil; switchAt = nil
            return before != visible
        }
        let hit = map.hit(at: p)
        // D20: in the corridor toward the card (and not back on the hovered leaf), hold for the grace.
        if card != nil, hit?.item.id != hovered, inCorridor(q) {
            let until = corridorUntil ?? (t + Self.cardGrace)
            corridorUntil = until
            if t < until {
                holding = true; clearAt = nil; pending = nil; switchAt = nil
                return before != visible
            }
        } else {
            corridorUntil = nil
        }
        holding = false
        if let leaf = hit {
            // On a leaf or within the snap radius: cancels any pending clear.
            clearAt = nil
            if hovered == nil || leaf.item.id == hovered || card == nil {
                pending = nil; switchAt = nil
                show(leaf, pointer: p)
            } else {
                // D20: another leaf: switch after the dwell (moving on to a third leaf restarts it).
                if pending?.item.id != leaf.item.id { pending = leaf; switchAt = t + Self.switchDwell }
                pendingPointer = p
                settle(at: t)
            }
        } else if hovered != nil {
            pending = nil; switchAt = nil
            // D16: in a gap farther than the snap radius from every leaf, clear after the grace. The deadline
            // is set on entering the gap, so moving around inside it doesn't postpone the clear.
            if clearAt == nil { clearAt = t + Self.leaveDelay }
            settle(at: t)
        }
        return before != visible
    }

    /// A click at `p`. On a leaf: pin its card (or unpin if it's already pinned). On empty space: unpin.
    /// On the pinned card itself: nothing (its buttons handle the click). Returns true when the state changed.
    @discardableResult
    public mutating func click(at p: Pt, in map: LeafMap) -> Bool {
        let before = visible
        // D20: a click on the shown card (pinned or not) belongs to its buttons.
        if card != nil, let r = cardRect, r.contains(cardPoint(p)) { return false }
        bounds = Pt(map.width, map.height)
        pending = nil; switchAt = nil; holding = false; corridorUntil = nil
        if let leaf = map.hit(at: p) {
            if pinned && leaf.item.id == card { pinned = false } else { pinned = true; show(leaf, pointer: p) }
        } else {
            pinned = false
        }
        cardUnderPointer = false
        return before != visible
    }

    /// Popover closed or Escape: drop the pin and the hover at once.
    public mutating func reset() { self = HoverTracker(cardSize: cardSize, space: space) }

    private init(cardSize: Pt, space: CardSpace?) { self.cardSize = cardSize; self.space = space }

    /// A map point in the card's coordinate space.
    func cardPoint(_ p: Pt) -> Pt { space?.toPopover(p) ?? p }

    private mutating func show(_ leaf: Leaf, pointer: Pt) {
        // D20: the same leaf again (the pointer heading for its card) doesn't dodge the pointer; only a new card does.
        let same = leaf.item.id == card && cardOrigin != nil
        hovered = leaf.item.id; card = leaf.item.id
        if let s = space {
            leafRect = s.leafRect(leaf)
            cardOrigin = CardPlacement.place(leaf: s.leafRect(leaf), size: cardSize, in: s.size, current: cardOrigin,
                                             pointer: same ? nil : s.toPopover(pointer))
            return
        }
        let (x0, y0, x1, y1) = Geo.bbox(leaf.outline)
        leafRect = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        cardOrigin = Self.anchor(current: cardOrigin, leaf: leafRect!, size: cardSize, in: bounds, pointer: pointer)
    }

    /// Pointer left the map at `t`: clear after `leaveDelay` (call `settle` then). A pinned card stays.
    /// D20: with the pointer on the card the map's exit is ignored (the card reports its own exit); while
    /// holding in the corridor the clear waits for the corridor's grace.
    public mutating func exit(at t: Double) {
        pending = nil; switchAt = nil
        guard hovered != nil, clearAt == nil, !pinned, !onCard else { return }
        clearAt = holding ? max(corridorUntil ?? t, t + Self.leaveDelay) : t + Self.leaveDelay
    }

    /// D20: the pointer left the card at `t` (the card's own tracking). Clears after `leaveDelay` unless
    /// the pointer lands back on the map or the card.
    public mutating func exitCard(at t: Double) {
        guard onCard else { return }
        onCard = false
        if hovered != nil, !pinned, clearAt == nil { clearAt = t + Self.leaveDelay }
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
        var changed = false
        if let s = switchAt, t >= s, let l = pending {
            pending = nil; switchAt = nil
            show(l, pointer: pendingPointer)
            changed = true
        }
        guard let c = clearAt, t >= c else { return changed }
        hovered = nil; card = nil; clearAt = nil; cardOrigin = nil; cardUnderPointer = false
        onCard = false; holding = false; corridorUntil = nil; leafRect = nil; pending = nil; switchAt = nil
        return true
    }

    /// What the view draws; a change here is one animation transaction.
    public struct Visible: Equatable, Sendable {
        public var hovered: String?
        public var card: String?
        public var cardOrigin: Pt?
        public var cardUnderPointer: Bool
        public var pinned: Bool
        public var onCard: Bool = false
    }
    public var visible: Visible { Visible(hovered: hovered, card: card, cardOrigin: cardOrigin, cardUnderPointer: cardUnderPointer, pinned: pinned, onCard: onCard) }
    /// Card opacity: faded while it sits over the pointer without being engaged (placement avoids that, D21).
    public var cardOpacity: Double { cardUnderPointer && !onCard ? 0.3 : 1 }

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
/// D20: where the hover card's buttons sit. The app pins the footer to the bottom of the card slot, so these
/// offsets hold for every card: Remove on the last row, Reveal in Finder above it (conservative widths).
public enum HoverCardLayout {
    public static let padding = 10.0, row = 22.0, rowGap = 4.0
    public static func buttons(in card: Rect) -> [(name: String, rect: Rect)] {
        let remove = Rect(x: card.x + padding, y: card.y + card.h - padding - row, w: 120, h: row)
        let reveal = Rect(x: card.x + padding, y: remove.y - rowGap - row, w: 104, h: row)
        return [("Reveal in Finder", reveal), ("Remove worktree", remove)]
    }
    public static func button(at p: Pt, in card: Rect) -> String? { buttons(in: card).first { $0.rect.contains(p) }?.name }
}

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
        /// The card's rect in popover coordinates (D19), while shown.
        public var cardRect: Rect?
        /// The card is shown and not fully inside the popover (should never happen).
        public var cardClipped: Bool
        /// D21: the shown card can't be reached: it is clipped, or it sits over the pointer (so the click that
        /// pins it would land on the card instead of the leaf). Should never happen.
        public var cardReachFailure: Bool
        /// D20: the pointer is on the shown card (geometry), so the card stays whatever is under it.
        public var onCard: Bool = false
        /// D20: the tracker holds the card while the pointer is in the corridor (checked against the geometry).
        public var inCorridor: Bool = false
        /// D20: the card button under the pointer, if any.
        public var buttonUnderPointer: String? = nil
        /// D20: this frame is the end of a reach-into-card path; it must land on a button of the card.
        public var reachTarget: Bool = false

        public init(frame: Int, x: Double, y: Double, viewX: Double? = nil, viewY: Double? = nil, t: Double,
                    hovered: String?, cardShown: Bool, cardX: Double?, cardY: Double?,
                    underPointer: String? = nil, inGap: Bool = false, snappedTo: String? = nil,
                    cardRect: Rect? = nil, cardClipped: Bool = false, cardReachFailure: Bool = false) {
            self.cardRect = cardRect; self.cardClipped = cardClipped; self.cardReachFailure = cardReachFailure
            self.frame = frame; self.x = x; self.y = y; self.viewX = viewX ?? x; self.viewY = viewY ?? y; self.t = t
            self.hovered = hovered; self.cardShown = cardShown; self.cardX = cardX; self.cardY = cardY
            self.underPointer = underPointer; self.inGap = inGap; self.snappedTo = snappedTo
        }

        /// What should be hovered once the grace has passed (D16): the leaf under the pointer, else the
        /// leaf within the snap radius, else nothing.
        /// D20: on the card, or held in the corridor, the card's leaf stays hovered.
        public var expected: String? { (onCard || inCorridor) && cardShown ? (heldCard ?? hovered) : (underPointer ?? snappedTo) }
        /// The card's leaf while shown (same as hovered for an unpinned card).
        public var heldCard: String? = nil
        /// A frame where the hovered leaf differs from the expected one.
        public var isMismatch: Bool { expected != hovered }

        enum CodingKeys: String, CodingKey {
            case frame, x, y, viewX, viewY, t, hovered, cardShown, cardX, cardY, underPointer, inGap, snappedTo, expected, cardRect, cardClipped, cardReachFailure
            case onCard, inCorridor, buttonUnderPointer, reachTarget, heldCard
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
                      snappedTo: try c.decodeIfPresent(String.self, forKey: .snappedTo),
                      cardRect: try c.decodeIfPresent(Rect.self, forKey: .cardRect),
                      cardClipped: try c.decodeIfPresent(Bool.self, forKey: .cardClipped) ?? false,
                      cardReachFailure: try c.decodeIfPresent(Bool.self, forKey: .cardReachFailure) ?? false)
            onCard = try c.decodeIfPresent(Bool.self, forKey: .onCard) ?? false
            inCorridor = try c.decodeIfPresent(Bool.self, forKey: .inCorridor) ?? false
            buttonUnderPointer = try c.decodeIfPresent(String.self, forKey: .buttonUnderPointer)
            reachTarget = try c.decodeIfPresent(Bool.self, forKey: .reachTarget) ?? false
            heldCard = try c.decodeIfPresent(String.self, forKey: .heldCard)
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
            try c.encode(cardRect, forKey: .cardRect); try c.encode(cardClipped, forKey: .cardClipped)
            try c.encode(cardReachFailure, forKey: .cardReachFailure)
            try c.encode(onCard, forKey: .onCard); try c.encode(inCorridor, forKey: .inCorridor)
            try c.encode(buttonUnderPointer, forKey: .buttonUnderPointer); try c.encode(reachTarget, forKey: .reachTarget)
            try c.encode(heldCard, forKey: .heldCard)
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
        /// Frames whose card is not fully inside the popover (D19). Expected 0.
        public var cardClipped: Int
        /// Frames whose card can't be reached (D21). Expected 0.
        public var cardReachFailures: Int
        /// D20: frames with the pointer on the card, and reach targets that landed on a button.
        public var onCardFrames: Int
        public var buttonHits: Int

        public init(_ frames: [Frame]) {
            onCardFrames = frames.filter(\.onCard).count
            buttonHits = frames.filter { $0.reachTarget && $0.buttonUnderPointer != nil }.count
            self.frames = frames
            hoveredCount = frames.filter { $0.hovered != nil }.count
            mismatchFrames = frames.filter(\.isMismatch).map(\.frame)
            mismatches = mismatchFrames.count
            gapFrames = frames.filter(\.inGap).count
            distinctHovered = Set(frames.compactMap(\.hovered)).count
            cardClipped = frames.filter(\.cardClipped).count
            cardReachFailures = frames.filter(\.cardReachFailure).count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            self.init(try c.decode([Frame].self, forKey: .frames))
        }
        enum K: String, CodingKey { case frames }

        public var summary: String {
            "\(frames.count) frames, \(hoveredCount) hovered, \(distinctHovered) distinct leaves, \(gapFrames) in gaps, "
                + "\(mismatches) mismatches, \(cardClipped) clipped cards, \(cardReachFailures) card reach failures, \(buttonHits) button hits" + (mismatches > 0 ? " (frames \(mismatchFrames.map(String.init).joined(separator: ", ")))" : "")
        }
    }

    /// Ground truth for a pointer at view point `v`: plain point-in-polygon against every leaf's outline
    /// mapped into view coordinates. Deliberately doesn't use HoverTracker, `LeafMap.hit` or `toMap`.
    public static func underPointer(_ v: Pt, in map: LeafMap, _ transform: MapTransform) -> String? {
        map.leaves.first { Geo.inside($0.outline.map(transform.toView), v) }?.item.id
    }

    /// Builds one frame from the tracker state after the pointer moved to `p` (map coordinates, nil = left).
    public static func frame(_ i: Int, pointer p: Pt?, last: Pt, t: Double, tracker: HoverTracker,
                             map: LeafMap, transform: MapTransform = .identity,
                             placedNow: Bool = false, reachTarget: Bool = false) -> Frame {
        let q = p ?? last
        let v = transform.toView(q)
        let truth = p.map { _ in underPointer(v, in: map, transform) } ?? nil
        let onMap = p != nil && q.x >= 0 && q.y >= 0 && q.x <= map.width && q.y <= map.height
        let gap = onMap && truth == nil
        let rect = tracker.card == nil ? nil : tracker.cardRect
        let clipped = rect.map { tracker.space?.clips($0) ?? !$0.inside(width: map.width, height: map.height) } ?? false
        let cp = p.map { tracker.cardPoint($0) }
        let overPointer = cp.flatMap { c in rect.map { $0.contains(c) } } ?? false
        let corridor = !overPointer && tracker.holding && (cp.map(tracker.inCorridor) ?? false)
        let button = cp.flatMap { c in rect.flatMap { HoverCardLayout.button(at: c, in: $0) } }
        // D21/D20: unreachable when clipped, when it is placed right over the pointer (it would steal the
        // leaf), or when a reach-into-card path ends anywhere but on one of its buttons.
        let reachMissed = reachTarget && (button == nil || tracker.card == nil)
        var f = Frame(frame: i, x: q.x, y: q.y, viewX: v.x, viewY: v.y, t: t, hovered: tracker.hovered,
                     cardShown: tracker.card != nil, cardX: tracker.cardOrigin?.x, cardY: tracker.cardOrigin?.y,
                     underPointer: truth, inGap: gap, snappedTo: gap ? map.hit(at: q)?.item.id : nil,
                     cardRect: rect, cardClipped: clipped,
                     cardReachFailure: clipped || (placedNow && overPointer) || reachMissed)
        f.onCard = overPointer; f.inCorridor = corridor; f.buttonUnderPointer = button; f.reachTarget = reachTarget
        f.heldCard = tracker.card
        return f
    }

    /// D20: the reach-into-card path from the tracker's current state: from the hovered leaf's centre straight
    /// to the card's first button in `steps` frames (fast enough to stay inside the corridor's grace).
    /// Points are map coordinates. Empty when no card is shown.
    public static func reachPath(_ tracker: HoverTracker, steps: Int = 6) -> [Pt] {
        guard tracker.card != nil, let r = tracker.cardRect, let l = tracker.leafRect,
              let target = HoverCardLayout.buttons(in: r).first?.rect.center else { return [] }
        let from = l.center
        let toMap: (Pt) -> Pt = { q in
            guard let s = tracker.space else { return q }
            return s.transform.toMap(q - s.mapOrigin)
        }
        return (0...steps).map { i in
            let f = Double(i) / Double(steps)
            return toMap(Pt(from.x + (target.x - from.x) * f, from.y + (target.y - from.y) * f))
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

    /// Runs `path` through a tracker, the way the CLI does. Pointer events go in as view points through
    /// `transform`, like the app's mouse tracking. `apply` sees the tracker after each step.
    public static func run(_ map: LeafMap, path: [Pt?], step: Double = 1.0 / 30, cardSize: Pt = LeafSVG.cardSlot,
                           transform: MapTransform = .identity, space: CardSpace? = nil,
                           apply: (Int, HoverTracker) -> Void = { _, _ in }) -> [Frame] {
        run(map, path: path, step: step, cardSize: cardSize, transform: transform, space: space) { i, t, _ in apply(i, t) }
    }

    /// Same, with the pointer for each frame (the reach-into-card path adds frames beyond `path`).
    public static func run(_ map: LeafMap, path: [Pt?], step: Double = 1.0 / 30, cardSize: Pt = LeafSVG.cardSlot,
                           transform: MapTransform = .identity, space: CardSpace? = nil,
                           applyAt: (Int, HoverTracker, Pt?) -> Void) -> [Frame] {
        var tracker = HoverTracker()
        tracker.cardSize = cardSize
        tracker.space = space
        var frames: [Frame] = []
        var t = 0.0, last = Pt(-1, -1)
        func feed(_ p: Pt?, reachTarget: Bool) {
            let i = frames.count, before = tracker.cardOrigin
            if let p {
                tracker.move(to: transform.toMap(transform.toView(p)), in: map, at: t); last = p
            } else { tracker.exitCard(at: t); tracker.exit(at: t) }
            // Instant mode (D16, D20): a pending clear or leaf switch is applied by jumping time to it, so
            // each frame shows the settled state.
            if let c = tracker.nextDeadline { t = max(t, c); tracker.settle(at: t) }
            applyAt(i, tracker, p)
            frames.append(frame(i, pointer: p, last: last, t: t, tracker: tracker, map: map, transform: transform,
                                placedNow: tracker.cardOrigin != before, reachTarget: reachTarget))
            t += p == nil ? HoverTracker.leaveDelay + 0.01 : step
        }
        // D20: before the pointer leaves, reach into the card and end on a button.
        let leaveAt = path.firstIndex { $0 == nil } ?? path.count
        for p in path[..<leaveAt] { feed(p, reachTarget: false) }
        // No card at the end of the serpentine (it ended in a gap): start the reach from the first leaf.
        if tracker.card == nil, let l = map.leaves.first { feed(l.centroid, reachTarget: false) }
        let reach = reachPath(tracker)
        for (k, p) in reach.enumerated() { feed(p, reachTarget: k == reach.count - 1) }
        for p in path[leaveAt...] { feed(p, reachTarget: false) }
        return frames
    }

    public static func json(_ frames: [Frame]) -> Data { json(Report(frames)) }

    public static func json(_ report: Report) -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try! e.encode(report)
    }
}
