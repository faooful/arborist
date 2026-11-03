import Foundation

/// Menu bar icon stage: the leaf wilts as free space drops.
public enum LeafStage: String, Codable, CaseIterable, Sendable {
    case healthy, droop, wilted, dry

    public var title: String {
        switch self { case .healthy: "healthy"; case .droop: "drooping"; case .wilted: "wilted"; case .dry: "dry" }
    }

    /// Stages are multiples of the low-space threshold: healthy above `healthy`×, droop between
    /// `droop`× and `healthy`×, wilted between `wilted`× and `droop`×, dry below `wilted`×.
    /// A value exactly on a boundary belongs to the healthier stage.
    public static func stage(freeBytes: Int64, thresholdGB: Double, multipliers m: StageMultipliers = .default) -> LeafStage {
        let free = Double(freeBytes) / 1e9
        if free > thresholdGB * m.healthy { return .healthy }
        if free >= thresholdGB * m.droop { return .droop }
        if free >= thresholdGB * m.wilted { return .wilted }
        return .dry
    }

    public static func accessibilityLabel(_ stage: LeafStage, freeBytes: Int64) -> String {
        "Arborist: leaf \(stage.title), \(Format.bytes(freeBytes)) free"
    }
}

public struct StageMultipliers: Codable, Equatable, Sendable {
    public var healthy: Double
    public var droop: Double
    public var wilted: Double
    public static let `default` = StageMultipliers(healthy: 3, droop: 1.5, wilted: 1)
    public init(healthy: Double, droop: Double, wilted: Double) { self.healthy = healthy; self.droop = droop; self.wilted = wilted }
}

/// Monochrome template glyph for a stage, in a unit box (0…1, y down). Healthy/droop/wilted are
/// filled; dry is outline only (the "brown outline" look, which reads as hollow in a template image).
public struct LeafGlyph: Equatable, Sendable {
    public var outline: [Pt]
    public var midrib: [Pt]
    public var stem: [Pt]
    public var filled: Bool

    public static func glyph(_ stage: LeafStage) -> LeafGlyph {
        // Leaf grows along a spine from the stem; bend (radians over the length) sets how far it droops.
        let (base, angle, bend, length, widthK, crinkle): (Pt, Double, Double, Double, Double, Double) = {
            switch stage {
            case .healthy: return (Pt(0.5, 0.92), -.pi / 2 + 0.12, 0.25, 0.70, 0.30, 0)
            case .droop:   return (Pt(0.42, 0.92), -.pi / 2 + 0.25, 1.55, 0.70, 0.28, 0)
            case .wilted:  return (Pt(0.40, 0.94), -.pi / 2 + 0.20, 3.3, 0.66, 0.20, 0.04)
            case .dry:     return (Pt(0.12, 0.84), -0.22, 0.6, 0.78, 0.22, 0.06)
            }
        }()
        let n = 40
        var spine: [Pt] = [base], tangents: [Double] = []
        var p = base
        for i in 0...n {
            let u = Double(i) / Double(n), th = angle + bend * u * u
            tangents.append(th)
            if i > 0 { p = p + Pt(cos(th), sin(th)) * (length / Double(n)); spine.append(p) }
        }
        let stemLen = 6
        var left: [Pt] = [], right: [Pt] = []
        for i in stemLen...n {
            let u = Double(i - stemLen) / Double(n - stemLen)
            var w = widthK * length * pow(sin(.pi * u), 0.85) * (1 - 0.25 * u)
            if crinkle > 0 { w *= 1 - crinkle * 10 * abs(sin(u * 23)) * 0.1 }
            let th = tangents[i], nrm = Pt(-sin(th), cos(th))
            left.append(spine[i] + nrm * w); right.append(spine[i] - nrm * w)
        }
        let outline = left + right.reversed()
        return LeafGlyph(outline: outline, midrib: Array(spine[stemLen...]), stem: Array(spine[0...stemLen]), filled: stage != .dry)
    }
}
