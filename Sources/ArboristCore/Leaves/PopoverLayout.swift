/// Fixed popover geometry (D17). The map has an explicit size so it can't collapse when the window
/// sizes itself to its content (MenuBarExtra `.window` windows use the content's ideal size).
public enum PopoverLayout {
    public static let width = 480.0
    public static let padding = 16.0
    public static let mapWidth = width - 2 * padding // 448
    public static let mapHeight = 400.0
    /// D24: the one shared slot below the map: the legend and storage bar at rest, the leaf details on
    /// hover or pin, crossfaded at the same size. Exactly as tall as StripLayout's rhythm.
    public static let stripHeight = StripLayout.height
    public static let footerHeight = stripHeight
    /// D24: crossfade between legend and details (Reduce Motion: none).
    public static let stripFade = 0.2
    /// D24: the header row, and the footer buttons' own row below the slot.
    public static let headerHeight = 26.0, footerRowHeight = 28.0
    /// D24: the popover's fixed total height (header, map, slot, footer row); the List and cleanup results
    /// only appear below it when asked for.
    public static let height = padding + headerHeight + stripGap + mapHeight + stripGap + stripHeight + stripGap + footerRowHeight + padding
    /// Space between the map and the strip (the popover's VStack spacing).
    public static let stripGap = 10.0
    /// Below this, a measured map frame is treated as not laid out yet (MapTransform.usable).
    public static let minMapSide = 64.0
}
