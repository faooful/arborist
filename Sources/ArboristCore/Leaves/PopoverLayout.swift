/// Fixed popover geometry (D17). The map has an explicit size so it can't collapse when the window
/// sizes itself to its content (MenuBarExtra `.window` windows use the content's ideal size).
public enum PopoverLayout {
    public static let width = 480.0
    public static let padding = 16.0
    public static let mapWidth = width - 2 * padding // 448
    public static let mapHeight = 400.0
    /// D22/D24: the detail strip's height when shown. D24: at rest it takes no space; it slides in over the
    /// footer slot (key, free bar, buttons), which is exactly this tall, so the popover never resizes.
    public static let stripHeight = 118.0
    /// D24: the footer slot below the map that the strip overlays; the same height as the strip.
    public static let footerHeight = stripHeight
    /// D24: strip fade (Reduce Motion: none).
    public static let stripFade = 0.2
    /// Space between the map and the strip (the popover's VStack spacing).
    public static let stripGap = 10.0
    /// Below this, a measured map frame is treated as not laid out yet (MapTransform.usable).
    public static let minMapSide = 64.0
}
