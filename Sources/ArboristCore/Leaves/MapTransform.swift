/// The one mapping between layout space (where `LeafLayout` puts the leaves, `map.width × map.height`)
/// and the view the map is drawn in (D15). Drawing applies `toView`; every pointer position goes
/// through `toMap` before hit-testing, so drawing and hit-testing can't disagree.
///
/// The fit is aspect-fit: the layout is scaled uniformly to the largest size that fits the view and
/// centred (letterboxed) in it. `origin` is where the view itself sits inside the coordinate space the
/// pointer is reported in (for example the header height when points are in popover coordinates).
/// Both spaces have a top-left origin with y down.
public struct MapTransform: Equatable, Sendable {
    public var scale: Double
    public var dx: Double
    public var dy: Double

    public init(scale: Double, dx: Double, dy: Double) { self.scale = scale; self.dx = dx; self.dy = dy }

    public static let identity = MapTransform(scale: 1, dx: 0, dy: 0)

    public static func fit(_ layout: Pt, into view: Pt, origin: Pt = Pt(0, 0)) -> MapTransform {
        guard layout.x > 0, layout.y > 0, view.x > 0, view.y > 0 else { return MapTransform(scale: 1, dx: origin.x, dy: origin.y) }
        let s = min(view.x / layout.x, view.y / layout.y)
        return MapTransform(scale: s, dx: origin.x + (view.x - layout.x * s) / 2, dy: origin.y + (view.y - layout.y * s) / 2)
    }

    public static func fit(_ map: LeafMap, into view: Pt, origin: Pt = Pt(0, 0)) -> MapTransform {
        fit(Pt(map.width, map.height), into: view, origin: origin)
    }

    public func toView(_ p: Pt) -> Pt { Pt(p.x * scale + dx, p.y * scale + dy) }
    public func toMap(_ p: Pt) -> Pt { Pt((p.x - dx) / scale, (p.y - dy) / scale) }
    public func toView(_ r: Rect) -> Rect { Rect(x: r.x * scale + dx, y: r.y * scale + dy, w: r.w * scale, h: r.h * scale) }
}

extension LeafMap {
    /// Hit-test a point given in view coordinates.
    public func hit(view p: Pt, _ t: MapTransform, radius: Double = LeafMap.hitRadius) -> Leaf? {
        hit(at: t.toMap(p), radius: radius / t.scale)
    }
}
