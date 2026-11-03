import Foundation

/// Hover state for the leaf map (D13), kept out of the view so it can be tested.
///
/// - Moving onto a leaf highlights it at once and moves the card to it; the card is never hidden
///   between two leaves, so neighbours cross-fade instead of flickering.
/// - Leaving (the pointer in a gutter or off the map) only clears after `leaveDelay`; landing on a
///   leaf within that time cancels the clear.
public struct HoverTracker: Equatable, Sendable {
    public static let leaveDelay = 0.12

    /// Leaf drawn lifted, and the leaf the card describes (the same once settled).
    public private(set) var hovered: String?
    public private(set) var card: String?
    /// When a pending leave takes effect.
    public private(set) var clearAt: Double?

    public init() {}

    /// Pointer is over leaf `id` (nil: over a gutter or outside) at time `t`.
    /// Returns true when the visible state changed (the view animates that change).
    @discardableResult
    public mutating func pointer(_ id: String?, at t: Double) -> Bool {
        let before = self
        if let id {
            hovered = id; card = id; clearAt = nil
        } else if hovered != nil {
            if clearAt == nil { clearAt = t + Self.leaveDelay }
            settle(at: t)
        }
        return before.hovered != hovered || before.card != card
    }

    /// Applies a pending leave if it is due. Call from a timer fired `leaveDelay` after a leave.
    @discardableResult
    public mutating func settle(at t: Double) -> Bool {
        guard let c = clearAt, t >= c else { return false }
        hovered = nil; card = nil; clearAt = nil
        return true
    }

    /// Opacity, scale and lift for a leaf. With Reduce Motion there is no scale or lift.
    public func appearance(of id: String, reduceMotion: Bool) -> (opacity: Double, scale: Double) {
        guard let h = hovered else { return (1, 1) }
        if h == id { return (1, reduceMotion ? 1 : LeafPalette.hoverScale) }
        return (LeafPalette.dimOthers, 1)
    }

    /// Animation length for a change: the normal fade, or a short opacity-only fade with Reduce Motion.
    public static func duration(reduceMotion: Bool) -> Double { reduceMotion ? 0.1 : LeafPalette.hoverFade }
}
