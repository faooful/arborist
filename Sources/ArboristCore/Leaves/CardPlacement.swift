import Foundation

/// Where the hover card sits in the *popover* (D19). The card is drawn above the whole popover, not inside
/// the clipped 448×400 map, so it is placed against the popover's bounds.
public struct CardSpace: Equatable, Sendable {
    /// Top-left of the map view in popover coordinates.
    public var mapOrigin: Pt
    /// The popover's size; the card always fits inside it.
    public var size: Pt
    /// Map layout coordinates → map view coordinates (D15).
    public var transform: MapTransform

    public init(mapOrigin: Pt, size: Pt, transform: MapTransform = .identity) {
        self.mapOrigin = mapOrigin; self.size = size; self.transform = transform
    }

    /// A map layout point in popover coordinates.
    public func toPopover(_ p: Pt) -> Pt { mapOrigin + transform.toView(p) }
    /// A leaf's bounding box in popover coordinates.
    public func leafRect(_ leaf: Leaf) -> Rect {
        let (x0, y0, x1, y1) = Geo.bbox(leaf.outline)
        let a = toPopover(Pt(x0, y0)), b = toPopover(Pt(x1, y1))
        return Rect(x: a.x, y: a.y, w: b.x - a.x, h: b.y - a.y)
    }
    /// True when `r` is not entirely inside the popover.
    public func clips(_ r: Rect) -> Bool { !r.inside(width: size.x, height: size.y) }
}

public enum CardPlacement {
    public static let margin = 8.0
    public static let gap = 10.0

    /// Card origin for a leaf at `leaf` (popover coordinates): below the leaf, else beside it (right, left),
    /// flipping above when there's no room below; if none is clear, the least-overlapping one. Always clamped
    /// inside `bounds` with `margin`, so the card fits whenever it is smaller than the popover.
    /// `current` is kept while it still fits and stays clear of the leaf, so the card doesn't jitter.
    /// `pointer` (popover coordinates): the card never sits over it, even when no spot clears a huge leaf,
    /// so the leaf under the pointer stays clickable and the card stays reachable (D21).
    public static func place(leaf: Rect, size: Pt, in bounds: Pt, current: Pt? = nil, pointer: Pt? = nil,
                             margin m: Double = margin, gap g: Double = gap) -> Pt {
        func clampX(_ x: Double) -> Double { min(max(m, x), max(m, bounds.x - size.x - m)) }
        func clampY(_ y: Double) -> Double { min(max(m, y), max(m, bounds.y - size.y - m)) }
        func rect(_ o: Pt) -> Rect { Rect(x: o.x, y: o.y, w: size.x, h: size.y) }
        func fits(_ o: Pt) -> Bool {
            o.x >= m - 0.001 && o.y >= m - 0.001 && o.x + size.x <= bounds.x - m + 0.001 && o.y + size.y <= bounds.y - m + 0.001
        }
        let guardBox = Rect(x: leaf.x - g / 2, y: leaf.y - g / 2, w: leaf.w + g, h: leaf.h + g)
        func clearOfPointer(_ o: Pt) -> Bool {
            guard let p = pointer else { return true }
            return !rect(o).intersects(Rect(x: p.x - g, y: p.y - g, w: 2 * g, h: 2 * g))
        }
        if let c = current, fits(c), !rect(c).intersects(guardBox) { return c }
        let cx = leaf.x + leaf.w / 2 - size.x / 2, cy = leaf.y + leaf.h / 2 - size.y / 2
        let tries = [Pt(clampX(cx), leaf.y + leaf.h + g),          // below
                     Pt(leaf.x + leaf.w + g, clampY(cy)),          // right
                     Pt(leaf.x - g - size.x, clampY(cy)),          // left
                     Pt(clampX(cx), leaf.y - g - size.y)]          // above (flip)
        if let ok = tries.first(where: { fits($0) && !rect($0).intersects(guardBox) }) { return ok }
        func overlap(_ o: Pt) -> Double {
            let r = rect(Pt(clampX(o.x), clampY(o.y)))
            return max(0, min(r.x + r.w, leaf.x + leaf.w) - max(r.x, leaf.x)) * max(0, min(r.y + r.h, leaf.y + leaf.h) - max(r.y, leaf.y))
        }
        // Nothing clears the leaf (a very large leaf): least overlap among the spots that leave the pointer free,
        // including the popover's corners; keep the current spot if it still leaves the pointer free.
        if let c = current, fits(c), clearOfPointer(c) { return c }
        let corners = [Pt(m, m), Pt(bounds.x - size.x - m, m), Pt(m, bounds.y - size.y - m), Pt(bounds.x - size.x - m, bounds.y - size.y - m)]
        let all = (tries + corners).map { Pt(clampX($0.x), clampY($0.y)) }
        let free = all.filter(clearOfPointer)
        return (free.isEmpty ? all : free).min { overlap($0) < overlap($1) }!
    }
}
