import Foundation

/// Shared by the CLI and the app: ~/.config/devspace/config.json
public struct DevspaceConfig: Codable, Equatable, Sendable {
    public var roots: [String]
    public var lowSpaceThresholdGB: Double
    public var maxDepth: Int

    public static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    public static var defaults: DevspaceConfig {
        DevspaceConfig(roots: ["~", "~/Documents"], lowSpaceThresholdGB: 20, maxDepth: 4)
    }
    public init(roots: [String], lowSpaceThresholdGB: Double, maxDepth: Int) {
        self.roots = roots; self.lowSpaceThresholdGB = lowSpaceThresholdGB; self.maxDepth = maxDepth
    }

    public static var fileURL: URL {
        URL(fileURLWithPath: home).appendingPathComponent(".config/devspace/config.json")
    }
    public static func load() -> DevspaceConfig {
        guard let d = try? Data(contentsOf: fileURL), let c = try? JSONDecoder().decode(DevspaceConfig.self, from: d) else { return defaults }
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
