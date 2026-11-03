#if os(macOS)
import SwiftUI

/// Kanso-like palette: warm off-white, monochrome greys and black only.
enum Theme {
    static let paper = Color(red: 0.961, green: 0.953, blue: 0.933)
    static let ink = Color(white: 0.08)
    static let ink2 = Color(white: 0.35)
    static let ink3 = Color(white: 0.55)
    static let line = Color(white: 0.82)
    static let projectShades: [Color] = [Color(white: 0.18), Color(white: 0.30), Color(white: 0.42), Color(white: 0.52), Color(white: 0.62), Color(white: 0.70), Color(white: 0.76), Color(white: 0.80)]
    static let rebuildable = Color(white: 0.86)
    static let caches = Color(white: 0.72)
}
#endif
