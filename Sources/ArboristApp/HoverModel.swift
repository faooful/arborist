#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// The single source of truth for hover (D15). Both the map's mouse tracking and the List rows feed it,
/// and so does the `--hover-sweep` test hook. Every visible change is published in one animation transaction.
@MainActor
final class HoverModel: ObservableObject {
    @Published private(set) var visible = HoverTracker().visible
    private(set) var tracker = HoverTracker()
    var reduceMotion = false
    /// One pending leave timer at a time; a newer event cancels it.
    private var settleWork: DispatchWorkItem?

    static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    var hovered: String? { visible.hovered }
    var cardOpacity: Double { tracker.cardOpacity }

    /// Layout → view mapping of the map as it is drawn right now (D15). Set by LeafMapView from its real size.
    var transform = MapTransform.identity

    /// Pointer at `p` in the map view's own coordinates (top-left, y down). Mouse events and the sweep both
    /// come in here; the point goes through the same transform the drawing uses.
    func pointer(view p: CGPoint, in map: LeafMap, at t: Double = HoverModel.now(), animated: Bool = true) {
        let q = transform.toMap(Pt(p.x, p.y))
        move(to: CGPoint(x: q.x, y: q.y), in: map, at: t, animated: animated)
    }

    func click(view p: CGPoint, in map: LeafMap) {
        let q = transform.toMap(Pt(p.x, p.y))
        click(at: CGPoint(x: q.x, y: q.y), in: map)
    }

    /// Pointer moved over the map (map coordinates). Real mouse events and the sweep both call this.
    func move(to p: CGPoint, in map: LeafMap, at t: Double = HoverModel.now(), animated: Bool = true) {
        settleWork?.cancel()
        tracker.move(to: Pt(p.x, p.y), in: map, at: t)
        publish(animated)
    }

    /// Pointer left the map: clear after the grace period unless it comes back.
    func exit(at t: Double = HoverModel.now(), animated: Bool = true) {
        tracker.exit(at: t)
        scheduleSettle(animated)
    }

    func click(at p: CGPoint, in map: LeafMap) {
        settleWork?.cancel()
        tracker.click(at: Pt(p.x, p.y), in: map)
        publish(true)
    }

    /// A List row hovered (id) or left (nil).
    func row(_ id: String?) {
        settleWork?.cancel()
        tracker.pointer(id, at: Self.now())
        publish(true)
        if id == nil { scheduleSettle(true) }
    }

    func reset() {
        settleWork?.cancel()
        tracker.reset()
        publish(false)
    }

    func setCardSize(_ size: Pt) { tracker.cardSize = size }

    /// Test hook: applies a due leave right away (time is simulated by the sweep).
    func settle(at t: Double, animated: Bool) {
        if tracker.settle(at: t) { publish(animated) }
    }

    private func scheduleSettle(_ animated: Bool) {
        settleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle(at: HoverModel.now(), animated: animated) }
        }
        settleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverTracker.leaveDelay + 0.005, execute: w)
    }

    private func publish(_ animated: Bool) {
        let next = tracker.visible
        guard next != visible else { return }
        if animated {
            withAnimation(.easeInOut(duration: HoverTracker.duration(reduceMotion: reduceMotion))) { visible = next }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { visible = next }
        }
    }
}

/// Mouse tracking that doesn't depend on SwiftUI hover (D15). SwiftUI's hover never fired in the
/// MenuBarExtra window on Joseph's Mac. This view owns an NSTrackingArea with `.activeAlways`, so it gets
/// mouseMoved even when the popover window isn't key. It returns nil from hitTest, so clicks still reach
/// SwiftUI.
struct MouseTracking: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let v = TrackingNSView()
        v.onMove = onMove; v.onExit = onExit
        return v
    }
    func updateNSView(_ v: TrackingNSView, context: Context) {
        v.onMove = onMove; v.onExit = onExit
    }

    final class TrackingNSView: NSView {
        var onMove: (CGPoint) -> Void = { _ in }
        var onExit: () -> Void = {}
        private var area: NSTrackingArea?

        override var isFlipped: Bool { true } // top-left origin, like the map
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
            updateTrackingAreas()
        }
        override func updateTrackingAreas() {
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
            super.updateTrackingAreas()
        }
        override func mouseEntered(with e: NSEvent) { onMove(convert(e.locationInWindow, from: nil)) }
        override func mouseMoved(with e: NSEvent) { onMove(convert(e.locationInWindow, from: nil)) }
        override func mouseExited(with e: NSEvent) { onExit() }
    }
}
#endif
