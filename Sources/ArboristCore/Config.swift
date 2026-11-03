import Foundation

/// Shared by the CLI and the app: ~/.config/arborist/config.json
public struct ArboristConfig: Codable, Equatable, Sendable {
    public var roots: [String]
    public var lowSpaceThresholdGB: Double
    public var maxDepth: Int
    /// Menu bar leaf stages, as multiples of the low-space threshold (D10).
    public var leafStages: StageMultipliers
    /// Show the free-space text next to the menu bar leaf.
    public var showFreeText: Bool
    /// Seconds before the app gives up on a scan and shows an error with Retry (D11).
    public var scanTimeoutSeconds: Double

    public static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    public static var defaults: ArboristConfig {
        ArboristConfig(roots: ["~", "~/Documents"], lowSpaceThresholdGB: 20, maxDepth: 4)
    }
    public init(roots: [String], lowSpaceThresholdGB: Double, maxDepth: Int,
                leafStages: StageMultipliers = .default, showFreeText: Bool = true, scanTimeoutSeconds: Double = 180) {
        self.roots = roots; self.lowSpaceThresholdGB = lowSpaceThresholdGB; self.maxDepth = maxDepth
        self.leafStages = leafStages; self.showFreeText = showFreeText
        self.scanTimeoutSeconds = scanTimeoutSeconds
    }

    /// Missing keys fall back to defaults, so older or hand-written config files keep working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        roots = try c.decodeIfPresent([String].self, forKey: .roots) ?? d.roots
        lowSpaceThresholdGB = try c.decodeIfPresent(Double.self, forKey: .lowSpaceThresholdGB) ?? d.lowSpaceThresholdGB
        maxDepth = try c.decodeIfPresent(Int.self, forKey: .maxDepth) ?? d.maxDepth
        leafStages = try c.decodeIfPresent(StageMultipliers.self, forKey: .leafStages) ?? d.leafStages
        showFreeText = try c.decodeIfPresent(Bool.self, forKey: .showFreeText) ?? d.showFreeText
        scanTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .scanTimeoutSeconds) ?? d.scanTimeoutSeconds
    }

    public func stage(freeBytes: Int64) -> LeafStage {
        LeafStage.stage(freeBytes: freeBytes, thresholdGB: lowSpaceThresholdGB, multipliers: leafStages)
    }

    public static var fileURL: URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/arborist/config.json")
    }
    public static func load() -> ArboristConfig {
        guard let d = try? Data(contentsOf: fileURL), let c = try? JSONDecoder().decode(ArboristConfig.self, from: d) else { return defaults }
        return c
    }
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.fileURL, options: .atomic)
    }

    public static func expand(_ p: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        return p
    }
    public var expandedRoots: [String] { roots.map(Self.expand) }
}
