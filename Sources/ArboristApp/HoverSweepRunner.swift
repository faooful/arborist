#if os(macOS) && DEBUG
import AppKit
import ArboristCore
import SwiftUI

/// `--hover-sweep DIR` test hook (D15), DEBUG builds only, and only with ARBORIST_HOVER_SWEEP=1 set.
///
/// It loads the scan cache (or runs one scan), then sweeps the pointer across the map through
/// `HoverModel.move`/`exit`, the same calls the NSTrackingArea makes. After each step it renders the real
/// PopoverView offscreen with ImageRenderer, writing frame-NNN.png plus frames.json. It never creates the menu
/// bar item, and cleanup is disabled: the model refuses every cleanup call, and this checks that nothing ran.
@MainActor
enum HoverSweepRunner {
    static func requestedDirectory() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--hover-sweep"), i + 1 < args.count else { return nil }
        guard ProcessInfo.processInfo.environment["ARBORIST_HOVER_SWEEP"] == "1" else {
            FileHandle.standardError.write(Data("--hover-sweep needs ARBORIST_HOVER_SWEEP=1\n".utf8))
            exit(2)
        }
        return args[i + 1]
    }

    /// Hard deadline: the sweep exits on its own even if rendering hangs (the Mac has no `timeout`).
    static let deadlineSeconds = 60.0

    static func run(into dir: String) {
        // Fires on a background queue, so it works even while the main thread is stuck in a render.
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("hover-sweep: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited) // no Dock icon, no menu bar item
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        precondition(model.cleanupDisabled, "sweep must run with cleanup disabled")
        guard let map = model.leafMap else { fail("no leaf map (empty scan?)") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let hover = model.hover
        hover.setCardSize(LeafSVG.cardSlot)
        hover.instant = true // no animations: every frame shows its settled state

        // The real view, hosted like the popover: NSHostingView in an offscreen borderless window.
        let root = PopoverView().environmentObject(model).environmentObject(hover)
        let host = NSHostingView(rootView: root)
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless() // offscreen; needed so AppKit lays out and draws the hosted views
        settle(host)

        // The map view's real frame and transform, as laid out (not a guess): the tracking view is the
        // map's frame, and LeafMapView has published the transform it draws with.
        guard let tracking = findTracking(in: host) else { fail("map tracking view not found") }
        let transform = hover.transform
        print("map view frame in popover: \(tracking.convert(tracking.bounds, to: host)), transform: \(transform)")

        let path = HoverSweep.path(in: map)
        var frames: [HoverSweep.Frame] = []
        var t = 0.0, last = Pt(-1, -1)
        for (i, p) in path.enumerated() {
            if let p {
                last = p
                // A view point delivered the way mouseMoved delivers it: through the tracking view's callback.
                let vp = transform.toView(p)
                tracking.onMove(CGPoint(x: vp.x, y: vp.y))
            } else {
                hover.exit(at: t, animated: false)
                hover.settle(at: t, animated: false)
            }
            // Instant mode (D16): apply a pending clear right away, as if the grace had passed.
            if let c = hover.tracker.clearAt { hover.settle(at: max(c, HoverModel.now()), animated: false) }
            settle(host)
            frames.append(HoverSweep.frame(i, pointer: p, last: last, t: t, tracker: hover.tracker, map: map, transform: transform))
            let marker = p.map { tracking.convert(CGPoint(x: transform.toView($0).x, y: transform.toView($0).y), to: host) }
            capture(host, marker: marker, to: dir + String(format: "/frame-%03d.png", i))
            t += p == nil ? HoverTracker.leaveDelay + 0.01 : 1.0 / 30
        }
        let report = HoverSweep.Report(frames)
        do { try HoverSweep.json(report).write(to: URL(fileURLWithPath: dir + "/frames.json")) } catch { fail("\(error)") }
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        window.orderOut(nil)
        print(report.summary)
        print("frames in \(dir)")
    }

    /// Lets SwiftUI apply the latest state and lay out.
    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
    }

    private static func findTracking(in v: NSView) -> MouseTracking.TrackingNSView? {
        if let t = v as? MouseTracking.TrackingNSView { return t }
        for s in v.subviews { if let t = findTracking(in: s) { return t } }
        return nil
    }

    /// cacheDisplay of the hosting view, plus a red crosshair at the pointer (host coordinates).
    private static func capture(_ host: NSView, marker: CGPoint?, to path: String) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap rep") }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let m = marker, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            let cg = ctx.cgContext
            let sx = CGFloat(rep.pixelsWide) / host.bounds.width, sy = CGFloat(rep.pixelsHigh) / host.bounds.height
            // The bitmap context is y-up; host coordinates are y-down when the host is flipped.
            let p = CGPoint(x: m.x * sx, y: host.isFlipped ? CGFloat(rep.pixelsHigh) - m.y * sy : m.y * sy)
            cg.setStrokeColor(NSColor.systemRed.cgColor); cg.setLineWidth(1.5 * sx)
            cg.strokeEllipse(in: CGRect(x: p.x - 5 * sx, y: p.y - 5 * sx, width: 10 * sx, height: 10 * sx))
            cg.move(to: CGPoint(x: p.x - 9 * sx, y: p.y)); cg.addLine(to: CGPoint(x: p.x + 9 * sx, y: p.y))
            cg.move(to: CGPoint(x: p.x, y: p.y - 9 * sx)); cg.addLine(to: CGPoint(x: p.x, y: p.y + 9 * sx))
            cg.strokePath()
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
    }

    private static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data("hover-sweep: \(m)\n".utf8)); exit(1)
    }
}
#endif
