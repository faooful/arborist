import Foundation

/// D27: the cleanup confirm is an in-popover overlay (not a sheet). These are its fixed frames and the
/// hit order of everything under it, so "which view gets a click at this point" is testable on Linux.
public enum ConfirmLayout {
    public static let width = PopoverLayout.mapWidth, padding = 16.0, buttonHeight = 24.0
    public static let cancelWidth = 72.0, removeWidth = 96.0, buttonGap = 8.0
    /// The overlay sits above every other layer (map, panel, footer, repo menu).
    public static let zIndex = 100.0

    /// Cancel and Remove, right-aligned on the panel's last row (panel coordinates).
    public static func buttons(panel: Rect) -> [(name: String, rect: Rect)] {
        let y = panel.y + panel.h - padding - buttonHeight
        let removeX = panel.x + panel.w - padding - removeWidth
        let cancelX = removeX - buttonGap - cancelWidth
        return [("Cancel", Rect(x: cancelX, y: y, w: cancelWidth, h: buttonHeight)),
                ("Remove", Rect(x: removeX, y: y, w: removeWidth, h: buttonHeight))]
    }
}

/// D27: one hit-testable layer: highest z wins; a layer with `hitTesting == false` never takes a click.
public struct HitLayer: Equatable, Sendable {
    public var name: String, z: Double, frame: Rect, hitTesting: Bool
    public init(name: String, z: Double, frame: Rect, hitTesting: Bool = true) {
        self.name = name; self.z = z; self.frame = frame; self.hitTesting = hitTesting
    }
}

public enum HitOrder {
    static func contains(_ r: Rect, _ p: Pt) -> Bool { p.x >= r.x && p.x < r.x + r.w && p.y >= r.y && p.y < r.y + r.h }

    /// The layer a click at `p` reaches: highest z among hit-testable layers containing `p`
    /// (ties go to the later layer, as in SwiftUI's ZStack order).
    public static func topmost(at p: Pt, in layers: [HitLayer]) -> HitLayer? {
        var best: (Int, HitLayer)?
        for (i, l) in layers.enumerated() where l.hitTesting && contains(l.frame, p) {
            if best == nil || l.z >= best!.1.z { best = (i, l) }
        }
        return best?.1
    }

    /// The popover's layers: map and footer are only hit-testable while no confirm is open; the confirm's
    /// dim layer (full popover) and its buttons sit on top at `ConfirmLayout.zIndex`.
    public static func popover(size: Pt, map: Rect, footer: [Rect], confirm: [(name: String, rect: Rect)]?) -> [HitLayer] {
        let open = confirm != nil
        var l = [HitLayer(name: "map", z: 0, frame: map, hitTesting: !open)]
        l += footer.enumerated().map { HitLayer(name: "footer\($0.offset)", z: 0, frame: $0.element, hitTesting: !open) }
        if let c = confirm {
            l.append(HitLayer(name: "dim", z: ConfirmLayout.zIndex, frame: Rect(x: 0, y: 0, w: size.x, h: size.y)))
            l += c.map { HitLayer(name: $0.name, z: ConfirmLayout.zIndex + 1, frame: $0.rect) }
        }
        return l
    }

    /// Every confirm button's centre must reach that button. Returns the names that don't.
    public static func failures(_ layers: [HitLayer], buttons: [(name: String, rect: Rect)]) -> [String] {
        buttons.compactMap { b in
            let c = Pt(b.rect.x + b.rect.w / 2, b.rect.y + b.rect.h / 2)
            return topmost(at: c, in: layers)?.name == b.name ? nil : b.name
        }
    }
}

/// D27: confirm wording. A prune-only item's folder is already gone, so it frees nothing: say so.
public enum ConfirmWording {
    public static let pruneTag = "already deleted"
    public static let pruneNote = "Already deleted on disk; removes the stale git entry."
    /// (bytes to free from real removals, number of prune-only items)
    public static func totals(bytes: [Int64], pruneOnly: [Bool]) -> (Int64, Int) {
        var b: Int64 = 0, n = 0
        for (x, p) in zip(bytes, pruneOnly) { if p { n += 1 } else { b += x } }
        return (b, n)
    }
    /// The footer line: "Frees about 1.2 GB", the prune note when nothing else runs, or both counts.
    public static func summary(bytes: [Int64], pruneOnly: [Bool]) -> String {
        let (b, n) = totals(bytes: bytes, pruneOnly: pruneOnly)
        let removes = pruneOnly.count - n
        if removes == 0 { return n == 1 ? pruneNote : "Already deleted on disk; removes \(n) stale git entries." }
        let s = "Frees about \(Format.bytes(b))"
        return n == 0 ? s : s + " · \(n) already deleted"
    }
}

/// D27b: what the confirm does for each input. Each visible button is a plain click target with its own
/// action; the keys are bound separately and map to the same actions. A button's click must never depend
/// on a keyboard shortcut (the `.defaultAction` system Remove button took Return but not clicks).
public enum ConfirmAction: String, Sendable { case cancel, remove }
public enum ConfirmInput: String, CaseIterable, Sendable {
    case clickCancel, clickRemove, escape, `return`
    public var action: ConfirmAction {
        switch self {
        case .clickCancel, .escape: return .cancel
        case .clickRemove, .return: return .remove
        }
    }
    /// The visible buttons carry no keyboard shortcut (keys live on hidden buttons).
    public static let visibleButtonShortcuts: [String: String?] = ["Cancel": nil, "Remove": nil]
}
