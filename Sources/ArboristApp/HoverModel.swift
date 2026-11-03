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
    /// Sweep hook: every change applies with no animation, so a captured frame is the settled state.
    var instant = false
    /// One pending leave timer at a time; a newer event cancels it. A main-actor Task, so the timer
    /// never touches this model off the main actor.
    private var settleWork: Task<Void, Never>?

    /// Wall clock for real events. Nonisolated so it can be used anywhere (Swift 6).
    nonisolated static func now() -> Double { Date().timeIntervalSinceReferenceDate }

    var hovered: String? { visible.hovered }
    var cardOpacity: Double { tracker.cardOpacity }

    /// Layout → view mapping of the map as it is drawn right now (D15). Set by LeafMapView from its real size.
    var transform = MapTransform.identity { didSet { updateSpace() } }
    /// The map's top-left in the popover's coordinate space, and the popover's size (D19). Set from the
    /// "popover" named coordinate space; the card is placed against the whole popover, not the clipped map.
    var mapOrigin = Pt(0, 0) { didSet { updateSpace() } }
    var popoverSize: Pt? { didSet { updateSpace() } }

    private func updateSpace() {
        let s = popoverSize.map { CardSpace(mapOrigin: mapOrigin, size: $0, transform: transform) }
        if s != tracker.space { tracker.space = s }
    }
    /// Sweep hook: the space measured from AppKit's real layout.
    func setSpace(_ s: CardSpace) { mapOrigin = s.mapOrigin; transform = s.transform; popoverSize = s.size }

    /// Pointer at `p` in the map view's own coordinates (top-left, y down). Mouse events and the sweep both
    /// come in here; the point goes through the same transform the drawing uses.
    func pointer(view p: CGPoint, in map: LeafMap, at t: Double? = nil, animated: Bool = true) {
        let q = transform.toMap(Pt(p.x, p.y))
        move(to: CGPoint(x: q.x, y: q.y), in: map, at: t ?? Self.now(), animated: animated)
    }

    func click(view p: CGPoint, in map: LeafMap) {
        let q = transform.toMap(Pt(p.x, p.y))
        click(at: CGPoint(x: q.x, y: q.y), in: map)
    }

    /// Pointer moved over the map (map coordinates). Real mouse events and the sweep both call this.
    func move(to p: CGPoint, in map: LeafMap, at t: Double? = nil, animated: Bool = true) {
        settleWork?.cancel()
        tracker.move(to: Pt(p.x, p.y), in: map, at: t ?? Self.now())
        publish(animated)
        // D16: in a far gap the tracker sets a clear deadline; the same cancellable timer applies it.
        if tracker.clearAt != nil { scheduleSettle(animated) }
    }

    /// Pointer left the map: clear after the grace period unless it comes back.
    func exit(at t: Double? = nil, animated: Bool = true) {
        tracker.exit(at: t ?? Self.now())
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
    /// The card's measured height; placement uses the taller of it and the Core slot (every row, D19).
    func measuredCard(_ size: CGSize) {
        let s = Pt(max(LeafSVG.cardSlot.x, size.width), max(LeafSVG.cardSlot.y, size.height))
        if s != tracker.cardSize { tracker.cardSize = s }
    }

    /// Test hook: applies a due leave right away (time is simulated by the sweep).
    func settle(at t: Double, animated: Bool) {
        if tracker.settle(at: t) { publish(animated) }
    }

    private func scheduleSettle(_ animated: Bool) {
        settleWork?.cancel()
        let remaining = max(0, (tracker.clearAt ?? (Self.now() + HoverTracker.leaveDelay)) - Self.now())
        let delay = UInt64((remaining + 0.005) * 1_000_000_000)
        settleWork = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.settle(at: HoverModel.now(), animated: animated)
        }
    }

    private func publish(_ animated: Bool) {
        let next = tracker.visible
        guard next != visible else { return }
        if animated && !instant {
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
    var onMove: @MainActor (CGPoint) -> Void
    var onExit: @MainActor () -> Void

    func makeNSView(context: Context) -> TrackingNSView {
        let v = TrackingNSView()
        v.onMove = onMove; v.onExit = onExit
        return v
    }
    func updateNSView(_ v: TrackingNSView, context: Context) {
        v.onMove = onMove; v.onExit = onExit
    }
    /// Takes exactly the size it is offered (it is a background of the map's fixed frame), and never
    /// contributes a zero or ideal size of its own (D17).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TrackingNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? PopoverLayout.mapWidth, height: proposal.height ?? PopoverLayout.mapHeight)
    }

    final class TrackingNSView: NSView {
        // NSView and its event methods are main-actor isolated, so these are called on the main actor.
        var onMove: @MainActor (CGPoint) -> Void = { _ in }
        var onExit: @MainActor () -> Void = {}
        private var area: NSTrackingArea?

        override var isFlipped: Bool { true } // top-left origin, like the map
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
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
