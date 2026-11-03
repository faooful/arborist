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
        case .protected: ("#fbf8ef", 0x30 / 255.0)
        case .stale: ("#7a603e", 0x48 / 255.0)
        case .deps: ("#a7ae9a", 0x70 / 255.0)
        default: ("#7f8a70", 0x48 / 255.0)
        }
    }
    public static func isDark(_ s: LeafState) -> Bool { s == .protected }

    /// "#rrggbb" -> (r, g, b) in 0…1.
    public static func rgb(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
}
