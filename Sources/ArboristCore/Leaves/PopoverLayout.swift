/// Fixed popover geometry (D17). The map has an explicit size so it can't collapse when the window
/// sizes itself to its content (MenuBarExtra `.window` windows use the content's ideal size).
public enum PopoverLayout {
    public static let width = 480.0
    public static let padding = 16.0
    public static let mapWidth = width - 2 * padding // 448
    public static let mapHeight = 400.0
    /// Below this, a measured map frame is treated as not laid out yet (MapTransform.usable).
    public static let minMapSide = 64.0
}
