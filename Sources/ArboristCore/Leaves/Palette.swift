import Foundation

/// H7/H8 palette tokens, shared by the SwiftUI app and the SVG snapshot renderer.
public enum LeafPalette {
    public static let background = "#f6f3ec"
    public static let ink = "#4a5640"
    public static let inkSoft = "#7c7a68"
    public static let groupLabel = "#8a8670"
    public static let barTrack = "#ebe6da"
    public static let barFill = "#b9b29c"
    public static let stipple = "#cbc4b0"
    public static let staleStroke = "#b8976a"
    public static let keyStroke = "#a9b09b"
    public static let button = "#4a5640"
    public static let labelOnDark = "#fbf8ef"
    public static let sizeOnDark = "#f1ecdc"
    public static let sizeOnLight = "#5e6a52"

    public static func fill(_ s: LeafState) -> String {
        switch s {
        case .protected: "#7d8a6a"   // moss
        case .clean: "#c9d0bd"       // sage
        case .stale: "#c9a97e"       // dried-leaf tan
        case .deps: "#e4e6d3"
        case .free: "#efebe0"
        }
    }
    /// Vein colour and alpha (0–1).
    public static func vein(_ s: LeafState) -> (String, Double) {
        switch s {
        // Lighter than H8 (D13): veins are texture, not information.
        case .protected: ("#fbf8ef", 0x1c / 255.0)
        case .stale: ("#7a603e", 0x2a / 255.0)
        case .deps: ("#a7ae9a", 0x44 / 255.0)
        default: ("#7f8a70", 0x2a / 255.0)
        }
    }
    /// Rebuildable inner share (D12): a darker wash inside the leaf.
    public static let rebuildableShade = "#2f3a28"
    public static func rebuildableOpacity(_ s: LeafState) -> Double { s == .protected ? 0.15 : 0.085 }
    /// Hover: outline of the hovered leaf, and how much the others fade.
    public static let hoverStroke = "#2f3a28"
    /// Other leaves fade to this while one is hovered (D13): a gentle fade toward the paper, no darkening.
    public static let dimOthers = 0.88
    /// Hovered leaf scale and the hover fade duration (D13).
    public static let hoverScale = 1.03
    public static let hoverFade = 0.18
    public static let cardFill = "#fffdf7"
    public static let cardStroke = "#d8d1bf"
    /// Status dot colour for a worktree status.
    public static func dot(_ s: WorktreeStatus) -> String {
        switch s {
        case .uncommitted: "#5f6d4c"
        case .unpushed: "#7d8a6a"
        case .merged, .stale: "#b8976a"
        case .clean: "#b3bba5"
        }
    }

    /// Text colour inside a state pill (on the dot colour at 20%).
    public static func pillText(_ s: WorktreeStatus) -> String {
        switch s {
        case .uncommitted, .unpushed: "#3f4a32"
        case .merged, .stale: "#7a5a32"
        case .clean: "#5d6652"
        }
    }

    public static func isDark(_ s: LeafState) -> Bool { s == .protected }

    /// "#rrggbb" -> (r, g, b) in 0…1.
    public static func rgb(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
