#if os(macOS)
import ArboristCore
import SwiftUI

extension Color {
    /// From an H8 palette token like "#7d8a6a".
    init(hex: String, opacity: Double = 1) {
        let (r, g, b) = LeafPalette.rgb(hex)
        self.init(red: r, green: g, blue: b, opacity: opacity)
    }
}

enum Theme {
    static let paper = Color(hex: LeafPalette.background)
    static let ink = Color(hex: LeafPalette.ink)
    static let ink2 = Color(hex: LeafPalette.inkSoft)
    static let ink3 = Color(hex: LeafPalette.groupLabel)
    static let line = Color(hex: LeafPalette.barTrack)
}
#endif
