import Foundation

/// D29: the cursor as a breeze. A damped 2D spring (the gust) is pushed by pointer velocity and pulled back
/// to rest; each leaf near the pointer sways by the gust times a distance falloff. Drawing only: nothing here
/// touches hit areas, hover or selection. When the spring is settled the app stops animating (no timers).
public struct Spring2D: Equatable, Sendable {
    public var pos = Pt(0, 0), vel = Pt(0, 0)
    /// Stiffness and damping (per second); slightly under-damped so a gust rustles once or twice, then stops.
    public var stiffness = 90.0, damping = 11.0
    public static let restEpsilon = 0.004, velEpsilon = 0.01
    public init() {}

    /// At rest: no visible motion left. The app pauses its timeline when this is true.
    public var settled: Bool {
        abs(pos.x) < Self.restEpsilon && abs(pos.y) < Self.restEpsilon && abs(vel.x) < Self.velEpsilon && abs(vel.y) < Self.velEpsilon
    }

    /// A pointer impulse (gust strength, already clamped by `Wind.impulse`).
    public mutating func push(_ dv: Pt) { vel = Pt(vel.x + dv.x, vel.y + dv.y) }

    /// Semi-implicit Euler in fixed sub-steps (stable for any frame dt). Snaps exactly to rest once settled,
    /// so an idle spring stays bit-for-bit still.
    public mutating func advance(_ dt: Double) {
        guard !settled else { pos = Pt(0, 0); vel = Pt(0, 0); return }
        var left = min(max(dt, 0), 0.25)
        while left > 0 {
            let h = min(left, 1.0 / 240)
            let ax = -stiffness * pos.x - damping * vel.x, ay = -stiffness * pos.y - damping * vel.y
            vel = Pt(vel.x + ax * h, vel.y + ay * h)
            pos = Pt(pos.x + vel.x * h, pos.y + vel.y * h)
            left -= h
        }
        // Keep the gust bounded whatever the input.
        pos = Pt(max(-1, min(1, pos.x)), max(-1, min(1, pos.y)))
        if settled { pos = Pt(0, 0); vel = Pt(0, 0) }
    }
}

public enum Wind {
    /// Leaves within this distance (map points) of the pointer feel the breeze.
    public static let radius = 120.0
    /// Subtle: at most 3.5° of rotation and 2.5 pt of offset, at full gust right under the pointer.
    public static let maxAngle = 3.5, maxOffset = 2.5
    /// Pointer speed (pt/s) that gives a full-strength push, and the max impulse per event.
    public static let fullSpeed = 900.0, maxImpulse = 3.0

    /// 1 at the pointer, smoothly to 0 at `radius`, 0 beyond. Always in [0, 1].
    public static func falloff(_ d: Double) -> Double {
        guard d.isFinite, d < radius else { return 0 }
        let x = max(0, d) / radius
        let s = 1 - x * x
        return s * s
    }

    /// The impulse a pointer move gives the spring: the move's velocity, scaled and clamped.
    public static func impulse(from a: Pt, to b: Pt, dt: Double) -> Pt {
        guard dt > 0.0005 else { return Pt(0, 0) }
        var vx = (b.x - a.x) / dt / fullSpeed * maxImpulse, vy = (b.y - a.y) / dt / fullSpeed * maxImpulse
        let m = (vx * vx + vy * vy).squareRoot()
        if m > maxImpulse { vx *= maxImpulse / m; vy *= maxImpulse / m }
        return Pt(vx, vy)
    }

    /// One leaf's sway: rotation (degrees, about its centroid) and offset (map points). Bounded by
    /// maxAngle/maxOffset. A per-leaf phase from its id keeps neighbours from moving in lockstep.
    public static func sway(leaf c: Pt, id: String, pointer: Pt?, gust: Pt) -> (angle: Double, dx: Double, dy: Double) {
        guard let p = pointer else { return (0, 0, 0) }
        let d = ((c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y)).squareRoot()
        let f = falloff(d)
        guard f > 0 else { return (0, 0, 0) }
        let phase = 0.75 + 0.5 * Double(abs(id.hashValueStable) % 100) / 100 // 0.75…1.25
        let g = Pt(max(-1, min(1, gust.x)), max(-1, min(1, gust.y)))
        let angle = max(-maxAngle, min(maxAngle, (g.x * 0.8 - g.y * 0.2) * maxAngle * f * phase / 1.25))
        return (angle, g.x * maxOffset * f * phase / 1.25, g.y * maxOffset * f * phase / 1.25)
    }
}

/// D29: a removed leaf blowing away: it lifts, tumbles and drifts toward the nearest map edge while it fades.
public enum BlowAway {
    public static let duration = 0.7
    /// Reduce Motion: a plain fade, this long.
    public static let fadeDuration = 0.2

    /// The unit direction from `c` toward the nearest edge of a `size` map (left, right, top or bottom).
    public static func nearestEdge(_ c: Pt, size: Pt) -> Pt {
        let d = [(c.x, Pt(-1, 0)), (size.x - c.x, Pt(1, 0)), (c.y, Pt(0, -1)), (size.y - c.y, Pt(0, 1))]
        return d.min { $0.0 < $1.0 }!.1
    }

    public struct Frame: Equatable, Sendable {
        public var dx: Double, dy: Double, angle: Double, scale: Double, opacity: Double
    }

    /// The leaf at progress `t` (0…1, clamped). Ends past the nearest edge, fully transparent.
    public static func frame(_ c: Pt, size: Pt, id: String, t raw: Double) -> Frame {
        let t = max(0, min(1, raw))
        let dir = nearestEdge(c, size: size)
        let toEdge = dir.x < 0 ? c.x : dir.x > 0 ? size.x - c.x : dir.y < 0 ? c.y : size.y - c.y
        let travel = toEdge + 60
        let ease = t * t * (3 - 2 * t) * 0.4 + t * t * 0.6 // eases out of rest, accelerates away
        let lift = sin(.pi * min(t * 1.6, 1)) * 10 // rises a little first
        let spin = (id.hashValueStable % 2 == 0 ? 1.0 : -1.0) * 220 * ease
        let sideways = sin(t * .pi * 2) * 6 // drift across the main direction
        return Frame(dx: dir.x * travel * ease + dir.y * sideways,
                     dy: dir.y * travel * ease + dir.x * sideways - lift,
                     angle: spin, scale: 1 + 0.08 * sin(.pi * t), opacity: max(0, 1 - t * t))
    }
}

extension String {
    /// A hash that is the same on every run (Swift's `hashValue` is seeded per process).
    var hashValueStable: Int { unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7fff_ffff } }
}
