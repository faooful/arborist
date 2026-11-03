#if os(macOS) && DEBUG
import AppKit
import ArboristCore
import SwiftUI

/// `--hover-sweep DIR` and `--action-check` test hooks (D15, D22), DEBUG builds only, and only with ARBORIST_HOVER_SWEEP=1 set.
///
/// It loads the scan cache (or runs one scan), then sweeps the pointer across the map through
/// `HoverModel.move`/`exit`, the same calls the NSTrackingArea makes. After each step it renders the real
/// PopoverView offscreen with ImageRenderer, writing frame-NNN.png plus frames.json. It never creates the menu
/// bar item, and cleanup is disabled: the model refuses every cleanup call, and this checks that nothing ran.
@MainActor
enum HoverSweepRunner {
    static func requestedDirectory() -> String? { requestedValue(for: "--hover-sweep") }

    /// `flag VALUE` from the arguments, only with ARBORIST_HOVER_SWEEP=1 (DEBUG builds only).
    static func requestedValue(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        guard ProcessInfo.processInfo.environment["ARBORIST_HOVER_SWEEP"] == "1" else {
            FileHandle.standardError.write(Data("\(flag) needs ARBORIST_HOVER_SWEEP=1\n".utf8))
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
        if let f = requestedValue(for: "--filter") { model.applyFilterNames(f.split(separator: ",").map(String.init)) }
        if let st = requestedValue(for: "--state"), !model.applyStateList(st) { FileHandle.standardError.write(Data("bad --state \(st)\n".utf8)); exit(2) }
        guard let map = model.leafMap, !map.leaves.isEmpty else { fail("no leaf map (empty scan or filter?)") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let hover = model.hover
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
        let sizeBefore = host.fittingSize

        // The map view's real frame and transform, as laid out (not a guess): the tracking view is the
        // map's frame, and LeafMapView has published the transform it draws with.
        guard let tracking = findTracking(in: host) else { fail("map tracking view not found") }
        let transform = hover.transform
        let mapFrame = tracking.convert(tracking.bounds, to: host)
        print("map view frame in popover: \(mapFrame), transform: \(transform)")
        // D22: the panel is checked against the real popover (AppKit's layout, not a guess).
        let y0 = host.isFlipped ? mapFrame.minY : host.bounds.height - mapFrame.maxY
        hover.setSpace(PopoverSpace(mapOrigin: Pt(mapFrame.minX, y0), size: Pt(host.bounds.width, host.bounds.height), transform: transform))
        print("popover space: \(hover.tracker.space.map { "\($0)" } ?? "none")")

        // D22: the same steps as the CLI: serpentine, pin + reach to a strip button, leave.
        let space = hover.tracker.space!
        let (steps, pinLeaf) = HoverSweep.steps(map, space: space)
        let reachAt = steps.lastIndex { if case .move = $0 { return true }; return false }
        var frames: [HoverSweep.Frame] = []
        var t = 0.0, last = Pt(-1, -1), pinTruth: String?
        for (i, step) in steps.enumerated() {
            var p: Pt?
            switch step {
            case .move(let q):
                p = q; last = q
                let vp = transform.toView(q)
                if HoverSweep.onMap(q, map) {
                    // A view point delivered the way mouseMoved delivers it: through the tracking view's callback.
                    tracking.onMove(CGPoint(x: vp.x, y: vp.y))
                } else {
                    tracking.onExit() // the pointer left the map's tracking area (onto the strip)
                }
            case .click(let q):
                p = q; last = q
                let vp = transform.toView(q)
                hover.click(view: CGPoint(x: vp.x, y: vp.y), in: map)
                pinTruth = pinTruth == nil ? pinLeaf : nil
            case .leave:
                tracking.onExit()
            case .escape:
                hover.unpin(); pinTruth = nil
            }
            // Instant mode (D16): apply a pending clear right away.
            if let c = hover.tracker.clearAt { hover.settle(at: max(c, HoverModel.now()), animated: false) }
            settle(host)
            // D24: what SwiftUI actually drew: the map's frame now, and the strip's measured frames.
            let mf = tracking.convert(tracking.bounds, to: host)
            let my = host.isFlipped ? mf.minY : host.bounds.height - mf.maxY
            let sf = hover.visible.strip == nil ? nil : hover.drawnStripFrames
            let drawn = HoverSweep.Drawn(mapFrame: Rect(x: mf.minX, y: my, w: mf.width, h: mf.height),
                                         stripHeight: sf == nil ? 0 : PopoverLayout.stripHeight, stripFrames: sf,
                                         slotFrame: hover.drawnSlotFrame, footerButtons: hover.drawnFooterButtons,
                                         restFrames: hover.visible.strip == nil ? hover.drawnRestFrames : nil,
                                         legend: hover.visible.strip == nil ? hover.drawnLegend : nil,
                                         transition: hover.panelTransition)
            frames.append(HoverSweep.frame(i, pointer: p, last: last, t: t, tracker: hover.tracker, map: map, transform: transform,
                                           pinTruth: pinTruth, reachTarget: i == reachAt, drawn: drawn))
            let marker = p.map { tracking.convert(CGPoint(x: transform.toView($0).x, y: transform.toView($0).y), to: host) }
            capture(host, marker: marker, to: dir + String(format: "/frame-%03d.png", i))
            t += p == nil ? HoverTracker.leaveDelay + 0.01 : 1.0 / 30
            // D22: the popover never resizes on hover.
            if host.fittingSize != sizeBefore { fail("popover resized on hover: \(sizeBefore) → \(host.fittingSize) at frame \(i)") }
        }
        let report = HoverSweep.Report(frames, cases: LayoutCase.all(model.result ?? scan, map: map))
        do { try HoverSweep.json(report).write(to: URL(fileURLWithPath: dir + "/frames.json")) } catch { fail("\(error)") }
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        window.orderOut(nil)
        print(report.summary)
        print("frames in \(dir)")
    }

    /// `--action-check` (D22): runs Settings, Quit (dry run), Rescan and List through the real router and
    /// AppModel, and logs what fired. Settings logs whether a Settings window appeared and became key / front.
    /// Never quits; cleanup disabled; no menu bar item (the App scene isn't created, so Settings uses the
    /// fallback window unless the selector finds a Settings scene).
    static func actionCheck() {
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("action-check: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory) // like the menu bar app; never a status item here
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        precondition(model.cleanupDisabled, "action-check must run with cleanup disabled")
        let router = model.router
        precondition(router.dryRunQuit, "hook mode must never quit")
        func log(_ s: String) { print("action-check: " + s) }

        log(router.perform(.quit).log)
        let list0 = model.showList
        log(router.perform(.list).log + " (showList \(list0) → \(model.showList))")
        router.perform(.list)
        let r = router.perform(.rescan)
        log(r.log + " (scanning=\(model.scanning), progress=\(model.progressLabel ?? "none"))")
        log(router.perform(.rescan).log + " (second tap while scanning)")

        var done = false
        SettingsOpener.shared.run(SettingsOpening.steps(osMajor: router.osMajor), model: model) { report in
            log("settings: fired; " + report)
            done = true
        }
        let until = Date().addingTimeInterval(5)
        while !done && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if !done { log("settings: no report within 5 s") }
        // Let the rescan finish (or time out) so its progress is logged too; it never writes the cache here.
        let scanUntil = Date().addingTimeInterval(40)
        while model.scanning && Date() < scanUntil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        log("rescan finished=\(!model.scanning), repos=\(model.scanned?.repos.count ?? 0), cached=\(model.resultIsCached)")
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        log(done ? "done" : "done (settings unverified)")
    }

    /// `--snapshot PNG` (D17): the popover in the cached + scanning state, hosted and sized the way the
    /// MenuBarExtra window sizes it (the content's fitting size). Prints the popover size and the map frame;
    /// exits 3 if the map isn't 448×400.
    static func snapshot(to png: String) {
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("snapshot: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        precondition(model.cleanupDisabled, "snapshot must run with cleanup disabled")
        if let f = requestedValue(for: "--filter") { model.applyFilterNames(f.split(separator: ",").map(String.init)) }
        if let st = requestedValue(for: "--state"), !model.applyStateList(st) { FileHandle.standardError.write(Data("bad --state \(st)\n".utf8)); exit(2) }
        let total = scan.repos.count
        model.simulateCachedScanning(done: max(0, total - 2), total: total)
        let host = NSHostingView(rootView: PopoverView().environmentObject(model).environmentObject(model.hover))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle(host)
        host.frame.size = host.fittingSize
        settle(host)
        let size = host.fittingSize
        print("popover size: \(Int(size.width.rounded()))×\(Int(size.height.rounded()))")
        var ok = false
        if let tracking = findTracking(in: host) {
            let f = tracking.convert(tracking.bounds, to: host)
            print("map frame: x \(Int(f.minX.rounded())) y \(Int(f.minY.rounded())) \(Int(f.width.rounded()))×\(Int(f.height.rounded()))")
            ok = abs(f.width - PopoverLayout.mapWidth) < 0.5 && abs(f.height - PopoverLayout.mapHeight) < 0.5
        } else {
            print("map frame: none (no map in this state)")
        }
        print("transform: \(model.hover.transform)")
        capture(host, marker: nil, to: png)
        window.orderOut(nil)
        print("wrote \(png)")
        if !ok { FileHandle.standardError.write(Data("snapshot: map is not 448×400\n".utf8)); exit(3) }
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
