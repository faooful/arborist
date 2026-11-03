import Foundation

/// The popover in its own coordinates (D19, D22): where the map sits, the popover's size, and the map's
/// layout → view transform. The tooltip is placed and checked against it.
public struct PopoverSpace: Equatable, Sendable {
    /// Top-left of the map view in popover coordinates.
    public var mapOrigin: Pt
    /// The popover's size; the tooltip always fits inside it.
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
}

/// D22: the tooltip that follows the pointer: offset 12 pt right and below, flipped left/up at the
/// popover's edges, always inside it.
public enum TooltipPlacement {
    public static let offset = 12.0, margin = 4.0
    public static let size = Pt(200, 52)

    public static func place(pointer p: Pt, size: Pt = size, in bounds: Pt) -> Pt {
        var x = p.x + offset, y = p.y + offset
        if x + size.x > bounds.x - margin { x = p.x - offset - size.x }
        if y + size.y > bounds.y - margin { y = p.y - offset - size.y }
        x = min(max(margin, x), max(margin, bounds.x - size.x - margin))
        y = min(max(margin, y), max(margin, bounds.y - size.y - margin))
        return Pt(x, y)
    }
}

/// D22: where the detail strip's buttons sit (the app gives them these fixed frames). Strip coordinates
/// are the popover's; the button row is at the strip's bottom.
public enum StripLayout {
    public static let padding = 10.0, row = 22.0
    public static let buttons: [(name: String, x: Double, w: Double)] = [
        ("Reveal in Finder", 0, 120), ("Copy remove command", 128, 150), ("Remove worktree", 286, 142),
    ]
    public static func buttons(in strip: Rect) -> [(name: String, rect: Rect)] {
        let y = strip.y + strip.h - padding - row
        return buttons.map { ($0.name, Rect(x: strip.x + padding + $0.x, y: y, w: $0.w, h: row)) }
    }
    public static func button(at p: Pt, in strip: Rect) -> String? { buttons(in: strip).first { $0.rect.contains(p) }?.name }
}

/// D22: the tooltip's three facts.
public struct LeafTooltip: Equatable, Sendable {
    public var branch: String, repo: String, size: String
    public init(_ c: HoverCard) { branch = c.branch; repo = c.repo; size = c.size }
}

/// Hover state for the leaf map (D13, D15, D16, D22). The app's mouse tracking and the `--hover-sweep` hook
/// both drive it through `move(to:in:at:)` / `exit(at:)`, so the logic is the same everywhere and testable on Linux.
///
/// - **Leaf under the pointer.** A point resolves to the leaf under it or, in a gutter, the nearest leaf
///   edge within `LeafMap.hitRadius`, at once (no dwell). In a far gap or off the map it clears after `leaveDelay`.
/// - **Tooltip.** While a leaf is hovered and the pointer is on the map, a small tooltip follows the pointer
///   (`tooltipOrigin`). It never takes hit-testing.
/// - **Strip.** The docked strip shows `strip`: the pinned leaf, else the hovered one.
/// - **Pin.** Clicking a leaf pins it to the strip (again: unpin); clicking empty space or Esc unpins.
///   Hover still rings other leaves and moves the tooltip while pinned.
public struct HoverTracker: Equatable, Sendable {
    /// Grace before a leave takes effect (D16).
    public static let leaveDelay = 0.08

    public private(set) var hovered: String?
    public private(set) var pinned: String?
    /// When a pending leave takes effect.
    public private(set) var clearAt: Double?
    /// Pointer in map coordinates while it is on the map.
    public private(set) var pointer: Pt?
    /// The popover the tooltip is placed in. Nil: the map itself.
    public var space: PopoverSpace?
    public var tooltipSize = TooltipPlacement.size
    private var bounds = Pt(0, 0)

    public init() {}

    /// What the detail strip shows.
    public var strip: String? { pinned ?? hovered }

    /// Pointer at `p` (map coordinates) at time `t`. Returns true when the visible state changed.
    @discardableResult
    public mutating func move(to p: Pt, in map: LeafMap, at t: Double) -> Bool {
        let before = visible
        bounds = Pt(map.width, map.height)
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
    public mutating func reset() { let s = space, z = tooltipSize; self = HoverTracker(); space = s; tooltipSize = z }

    /// Pointer left the map at `t`: the tooltip goes at once, the hover after `leaveDelay`. A pin stays.
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

    /// The tooltip's top-left (popover coordinates with a space, else map coordinates), while shown.
    public var tooltipOrigin: Pt? {
        guard hovered != nil, let p = pointer else { return nil }
        if let s = space { return TooltipPlacement.place(pointer: s.toPopover(p), size: tooltipSize, in: s.size) }
        return TooltipPlacement.place(pointer: p, size: tooltipSize, in: bounds)
    }
    public var tooltipRect: Rect? { tooltipOrigin.map { Rect(x: $0.x, y: $0.y, w: tooltipSize.x, h: tooltipSize.y) } }

    /// What the view draws; a change here is one animation transaction.
    public struct Visible: Equatable, Sendable {
        public var hovered: String?
        public var pinned: String?
        public var strip: String?
        public var tooltipOrigin: Pt?
    }
    public var visible: Visible { Visible(hovered: hovered, pinned: pinned, strip: strip, tooltipOrigin: tooltipOrigin) }

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
        /// The tooltip's rect in popover coordinates, while shown.
        public var tooltipRect: Rect?
        public var tooltipClipped: Bool
        /// The strip button under the pointer, if any.
        public var buttonUnderPointer: String?
        /// End of the pin + reach-the-strip path: must be on a button with the pin held.
        public var reachTarget: Bool

        public init(frame: Int, x: Double, y: Double, viewX: Double? = nil, viewY: Double? = nil, t: Double,
                    hovered: String?, pinned: String? = nil, strip: String? = nil, underPointer: String? = nil,
                    inGap: Bool = false, snappedTo: String? = nil, pinTruth: String? = nil, tooltipRect: Rect? = nil,
                    tooltipClipped: Bool = false, buttonUnderPointer: String? = nil, reachTarget: Bool = false) {
            self.frame = frame; self.x = x; self.y = y; self.viewX = viewX ?? x; self.viewY = viewY ?? y; self.t = t
            self.hovered = hovered; self.pinned = pinned; self.strip = strip; self.underPointer = underPointer
            self.inGap = inGap; self.snappedTo = snappedTo; self.pinTruth = pinTruth; self.tooltipRect = tooltipRect
            self.tooltipClipped = tooltipClipped; self.buttonUnderPointer = buttonUnderPointer; self.reachTarget = reachTarget
        }

        /// What should be hovered once the grace has passed (D16): the leaf under the pointer, else the snap.
        public var expected: String? { underPointer ?? snappedTo }
        public var isMismatch: Bool { expected != hovered }
        /// What the strip should show: the pinned leaf, else the expected hover.
        public var expectedStrip: String? { pinTruth ?? expected }
        public var isStripMismatch: Bool { expectedStrip != strip }
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
        /// D22: frames whose tooltip isn't fully inside the popover. Expected 0.
        public var tooltipClipped: Int
        /// D22: reach targets that missed a strip button or lost the pin. Expected 0.
        public var reachFailures: Int
        /// D22: reach targets on a button with the pin held.
        public var buttonHits: Int
        public var tooltipFrames: Int

        public init(_ frames: [Frame]) {
            self.frames = frames
            hoveredCount = frames.filter { $0.hovered != nil }.count
            mismatchFrames = frames.filter(\.isMismatch).map(\.frame)
            mismatches = mismatchFrames.count
            gapFrames = frames.filter(\.inGap).count
            distinctHovered = Set(frames.compactMap(\.hovered)).count
            stripMismatches = frames.filter(\.isStripMismatch).count
            tooltipClipped = frames.filter(\.tooltipClipped).count
            reachFailures = frames.filter(\.isReachFailure).count + (frames.contains(where: \.reachTarget) ? 0 : 1)
            buttonHits = frames.filter { $0.reachTarget && !$0.isReachFailure }.count
            tooltipFrames = frames.filter { $0.tooltipRect != nil }.count
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            self.init(try c.decode([Frame].self, forKey: .frames))
        }
        enum K: String, CodingKey { case frames }

        public var summary: String {
            "\(frames.count) frames, \(hoveredCount) hovered, \(distinctHovered) distinct leaves, \(gapFrames) in gaps, \(tooltipFrames) with tooltip, "
                + "\(mismatches) mismatches, \(stripMismatches) strip mismatches, \(tooltipClipped) clipped tooltips, "
                + "\(reachFailures) reach failures, \(buttonHits) button hits"
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
                             pinTruth: String? = nil, reachTarget: Bool = false) -> Frame {
        let q = p ?? last
        let v = transform.toView(q)
        let onMap = p != nil && q.x >= 0 && q.y >= 0 && q.x <= map.width && q.y <= map.height
        let truth = onMap ? underPointer(v, in: map, transform) : nil
        let gap = onMap && truth == nil
        let rect = tracker.tooltipRect
        let clipped = rect.map { tracker.space?.clips($0) ?? !$0.inside(width: map.width, height: map.height) } ?? false
        let button = p.flatMap { pp in tracker.space.flatMap { s in StripLayout.button(at: s.toPopover(pp), in: s.stripRect) } }
        return Frame(frame: i, x: q.x, y: q.y, viewX: v.x, viewY: v.y, t: t, hovered: tracker.hovered,
                     pinned: tracker.pinned, strip: tracker.strip, underPointer: truth, inGap: gap,
                     snappedTo: gap ? map.hit(at: q)?.item.id : nil, pinTruth: pinTruth, tooltipRect: rect,
                     tooltipClipped: clipped, buttonUnderPointer: button, reachTarget: reachTarget)
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
    public static func steps(_ map: LeafMap, space: PopoverSpace?) -> (steps: [Step], pinned: String?) {
        let serp = path(in: map)
        var out: [Step] = serp.compactMap { $0 }.map { .move($0) }
        var pinned: String?
        if let s = space, let r = pinAndReach(map, space: s) { out += r.steps; pinned = r.leaf }
        out += [.leave, .leave]
        return (out, pinned)
    }

    /// True when `p` (map coordinates) is on the map; off-map points (the strip) reach the tracker as an exit,
    /// the way the app's map tracking area reports them.
    public static func onMap(_ p: Pt, _ map: LeafMap) -> Bool { p.x >= 0 && p.y >= 0 && p.x <= map.width && p.y <= map.height }

    /// Runs the sweep through a tracker, the way the CLI does. `apply` sees the tracker and pointer after each step.
    public static func run(_ map: LeafMap, step: Double = 1.0 / 30, transform: MapTransform = .identity,
                           space: PopoverSpace? = nil, apply: (Int, HoverTracker, Pt?) -> Void = { _, _, _ in }) -> [Frame] {
        var tracker = HoverTracker()
        tracker.space = space
        let (steps, pinLeaf) = steps(map, space: space)
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
            }
            // Instant mode (D16): a pending clear is applied by jumping time past the grace.
            if let c = tracker.clearAt { t = max(t, c); tracker.settle(at: t) }
            apply(i, tracker, p)
            frames.append(frame(i, pointer: p, last: last, t: t, tracker: tracker, map: map, transform: transform,
                                pinTruth: pinTruth, reachTarget: i == reachAt))
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
