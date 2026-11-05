#if os(macOS) && DEBUG
import AppKit
import ArboristCleanup
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
        // D26: the open repo menu: capture it, sample its background (opaque, light) and check its colours.
        let menuChecks = openRepoMenu(model, host: host, to: dir + "/menu.png")
        let header = (hover.drawnHeader ?? []).map {
            LegendMeasure(label: $0.label, natural: $0.natural, frame: Rect(x: $0.frame.x - PopoverLayout.padding, y: $0.frame.y, w: $0.frame.w, h: $0.frame.h))
        }
        if header.isEmpty { fail("header not measured") }
        let report = HoverSweep.Report(frames, cases: LayoutCase.all(model.result ?? scan, map: map), header: header, menu: menuChecks)
        do { try HoverSweep.json(report).write(to: URL(fileURLWithPath: dir + "/frames.json")) } catch { fail("\(error)") }
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        window.orderOut(nil)
        print(report.summary)
        print("frames in \(dir)")
    }

    /// D26: opens the repo menu panel, captures it to `png`, and returns RepoMenuStyle's contrast checks plus
    /// one for the rendered panel: a pixel inside it must be the opaque menu background (not the map behind).
    static func openRepoMenu(_ model: AppModel, host: NSView, to png: String) -> [RepoMenuStyle.Contrast] {
        model.repoMenuOpen = true
        settle(host); settle(host)
        capture(host, marker: nil, to: png)
        var checks = RepoMenuStyle.checks()
        guard let f = model.hover.drawnRepoMenu, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fail("repo menu not drawn")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / host.bounds.width
        // Top row, between "None" and the hint: plain panel background.
        let px = Int((f.x + f.w / 2) * sx), py = Int((f.y + 5) * sx)
        let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
        let hex = c.map { String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255)) } ?? "#000000"
        let want = RepoMenuStyle.ratio(hex, RepoMenuStyle.background)
        // Opaque in the light palette: the sampled pixel matches the panel colour (ratio ≈ 1), and the names on it pass.
        checks.append(RepoMenuStyle.Contrast(what: "panel background sampled \(hex)", fg: hex, bg: RepoMenuStyle.background,
                                             ratio: want <= 1.05 ? 99 : 0, minimum: 1))
        checks.append(RepoMenuStyle.Contrast(what: "name on sampled panel", fg: RepoMenuStyle.name, bg: hex,
                                             ratio: RepoMenuStyle.ratio(RepoMenuStyle.name, hex), minimum: 4.5))
        model.repoMenuOpen = false
        settle(host)
        print("repo menu: frame \(f), sampled background \(hex)")
        return checks
    }

    /// D27 `--confirm-check`: opens the single-worktree confirm and the Clear N confirm in the real PopoverView
    /// (key window, offscreen), and for each: hit-tests the drawn Cancel/Remove frames against the map and footer
    /// (Core `HitOrder` on the frames AppKit laid out), clicks each button with real mouse events, clicks the map
    /// beneath (must do nothing), and presses Esc and Return. Cleanup stays disabled: Remove is recorded by a hook.
    static func confirmCheck() {
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("confirm-check: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        precondition(model.cleanupDisabled, "confirm-check must run with cleanup disabled")
        if let st = requestedValue(for: "--state"), !model.applyStateList(st) { fail("bad --state \(st)") }
        var confirmed: [[CleanupItem]] = []
        model.confirmHook = { confirmed.append($0) }
        model.hover.instant = true
        let host = NSHostingView(rootView: PopoverView().environmentObject(model).environmentObject(model.hover))
        host.frame.size = host.fittingSize
        let window = KeyableWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settle(host)
        guard let tracking = findTracking(in: host) else { fail("map tracking view not found") }
        let mapFrame = tracking.convert(tracking.bounds, to: host)
        let map = Rect(x: mapFrame.minX, y: mapFrame.minY, w: mapFrame.width, h: mapFrame.height)
        let footer = model.hover.drawnFooterButtons ?? []
        func log(_ s: String) { print("confirm-check: " + s) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { log((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }

        func item(_ name: String, _ bytes: Int64, _ kind: CleanupItem.Kind) -> CleanupItem {
            CleanupItem(repo: "grove", repoPath: "/tmp/grove", path: "/tmp/grove-wt/\(name)", branch: name, head: nil, bytes: bytes, kind: kind)
        }
        let cases: [(String, [CleanupItem])] = [
            ("single", [item("codex/native-hosting-resume", 0, .pruneOnly)]),
            ("clear 3", [item("a", 1_200_000_000, .remove), item("b", 300_000_000, .remove), item("c", 0, .pruneOnly)]),
            ("clear 12", (0..<12).map { item("batch-\($0)", 100_000_000, $0 % 3 == 0 ? .pruneOnly : .remove) }),
        ]
        func point(_ r: Rect) -> NSPoint {
            let x = r.x + r.w / 2, y = r.y + r.h / 2
            return NSPoint(x: x, y: host.isFlipped ? host.bounds.height - y : y) // window coordinates are y-up
        }
        // D27b: a click as AppKit delivers it: the mouseUp is queued before the mouseDown is dispatched, so a
        // control that tracks the mouse in its own loop (NSCell-style) sees it, as with a real click. Then the
        // run loop drains so any async action lands before the check (polled, max 0.5 s).
        func click(_ r: Rect) {
            func ev(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: point(r), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { fail("no mouse event") }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            settle(host)
            // If nothing consumed the queued mouseUp, deliver it now.
            while let e = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true) { window.sendEvent(e) }
            settle(host)
        }
        func waitFor(_ ok: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(0.5)
            while !ok() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return ok()
        }
        func key(_ code: UInt16, _ chars: String) {
            for t in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: t, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
                settle(host)
            }
        }
        func open(_ items: [CleanupItem]) -> [(name: String, rect: Rect)] {
            model.pendingCleanup = items
            settle(host); settle(host)
            return model.hover.drawnConfirmButtons ?? []
        }

        for (name, items) in cases {
            // D27b: Remove as the very first click on a fresh confirm too (not only after Cancel).
            if let remove = open(items).first(where: { $0.name == "Remove" }) {
                click(remove.rect)
                check(waitFor { model.pendingCleanup == nil && confirmed.last == items }, "\(name): first click on Remove confirms")
                confirmed.removeAll()
            }
            let buttons = open(items)
            // D30: the confirm hugs its rows; only a long list hits the cap (and scrolls).
            if let p = model.hover.drawnConfirmPanel {
                let bound = ConfirmLayout.heightBound(rows: items.count)
                check(p.h <= bound, "\(name): confirm height \(Int(p.h)) ≤ \(Int(bound)) for \(items.count) row(s)")
                if items.count == 1 { check(p.h < ConfirmLayout.chromeHeight + ConfirmLayout.listMaxHeight / 2, "\(name): no empty middle (height \(Int(p.h)))") }
            } else {
                check(false, "\(name): confirm frame reported")
            }
            check(buttons.count == 2, "\(name): Cancel and Remove drawn \(buttons.map { "\($0.name) \($0.rect)" })")
            let layers = HitOrder.popover(size: Pt(host.bounds.width, host.bounds.height), map: map, footer: footer, confirm: buttons)
            check(HitOrder.failures(layers, buttons: buttons).isEmpty, "\(name): hit order reaches both buttons")
            for b in buttons {
                let p = point(b.rect)
                let hit = host.hitTest(host.superview.map { host.convert(p, to: $0) } ?? p)
                log("\(name): AppKit hitTest at \(b.name) → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
            // The map beneath must ignore a click while the confirm is open.
            let pinned0 = model.hover.visible.pinned
            click(Rect(x: map.x + 4, y: map.y + 4, w: 2, h: 2))
            check(model.pendingCleanup != nil && model.hover.visible.pinned == pinned0, "\(name): map click ignored, confirm still open")
            if let cancel = buttons.first(where: { $0.name == "Cancel" }) {
                click(cancel.rect)
                check(model.pendingCleanup == nil && confirmed.isEmpty, "\(name): Cancel click closes, nothing removed")
            }
            let buttons2 = open(items)
            if let remove = buttons2.first(where: { $0.name == "Remove" }) {
                click(remove.rect)
                check(waitFor { model.pendingCleanup == nil && confirmed.last == items }, "\(name): Remove click confirms \(items.count)")
            }
            confirmed.removeAll()
            _ = open(items); key(53, "\u{1b}")
            check(model.pendingCleanup == nil && confirmed.isEmpty, "\(name): Esc cancels")
            _ = open(items); key(36, "\r")
            check(model.pendingCleanup == nil && confirmed.last == items, "\(name): Return confirms")
            confirmed.removeAll()
        }
        log("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    /// D28 `--remove-trial`: creates a throwaway repo under a temp dir with one merged worktree at
    /// /tmp/arborist-trial-remove, scans only that, hosts the real PopoverView, and removes the worktree through
    /// the app path (`confirmCleanup` → `Cleanup.execute` → `applyRemovals`). Asserts the leaf is gone in the
    /// first frame after the removal finishes, then that the confirming `git worktree list` keeps it gone.
    /// Touches nothing but its own temp repo; never writes the scan cache.
    static func removeTrial() {
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("remove-trial: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        func log(_ s: String) { print("remove-trial: " + s) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { log((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
        let base = NSTemporaryDirectory() + "arborist-trial-\(UUID().uuidString)"
        let wtPath = "/tmp/arborist-trial-remove"
        defer { try? FileManager.default.removeItem(atPath: base) }
        guard let t = TrialRepo.make(in: base, worktree: wtPath) else { fail("could not create the trial repo") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let scan = Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3)).scan()
        let model = AppModel(sweepWith: scan, allowCleanup: true)
        model.hover.instant = true
        let host = NSHostingView(rootView: PopoverView().environmentObject(model).environmentObject(model.hover))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle(host)
        func hasLeaf() -> Bool { model.leafMap?.leaves.contains { URL(fileURLWithPath: $0.item.id).resolvingSymlinksInPath().path == URL(fileURLWithPath: t.worktree).resolvingSymlinksInPath().path } ?? false }
        check(hasLeaf(), "trial leaf on the map before removal")
        let count0 = model.result?.worktreeCount ?? 0, ready0 = model.clearPlan.count
        guard let ref = WorktreeList.find(scan, path: t.worktree) else {
            let listed = scan.repos.flatMap(\.worktrees).map(\.path).joined(separator: ", ")
            fail("trial worktree \(t.worktree) not in the scan (git listed: \(listed))")
        }
        guard let item = Cleanup.item(ref) else {
            let w = ref.worktree
            fail("trial worktree not ready to clean: blocker \(String(describing: Cleanup.blocker(w))), status \(w.status), stale reasons \(w.staleReasons), branch \(w.branch ?? "detached"), path \(w.path)")
        }
        model.confirmCleanup([item])
        let end = Date().addingTimeInterval(20)
        while model.cleanupResults == nil && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(model.cleanupResults?.first?.succeeded == true, "git removed it: \(model.cleanupResults?.first?.summary ?? "no result")")
        // The very next frame: one layout pass, no rescan yet.
        settle(host)
        capture(host, marker: nil, to: base + "/after.png")
        check(!hasLeaf(), "leaf gone in the next frame")
        check(model.result?.worktreeCount == count0 - 1, "worktree count \(count0) → \(model.result?.worktreeCount ?? -1)")
        check(model.clearPlan.count == ready0 - 1, "Clear N \(ready0) → \(model.clearPlan.count)")
        check(model.hover.visible.pinned == nil && model.hover.visible.strip == nil, "no pin or strip on the removed leaf")
        while model.removalsConfirmed == 0 && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(model.removalsConfirmed == 1 && model.reappeared.isEmpty && !hasLeaf(), "rescan of the repo confirms it is gone")
        check(!FileManager.default.fileExists(atPath: t.worktree), "folder gone on disk")
        log("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }

    /// D29 `--motion-capture DIR`: PNG frames of the breeze (pointer moving, then stopped and settled) and of a
    /// leaf blowing away (and the Reduce Motion fade), from the real PopoverView, for review on the Mac. The
    /// spring runs on a manual clock so frames are repeatable. Cleanup disabled; no cache writes.
    static func motionCapture(into dir: String) {
        let limit = deadlineSeconds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            FileHandle.standardError.write(Data("motion-capture: timed out after \(Int(limit)) s\n".utf8))
            exit(2)
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        precondition(model.cleanupDisabled, "motion-capture must run with cleanup disabled")
        guard let map = model.leafMap, let leaf = map.leaves.first(where: { !$0.item.id.isEmpty }) else { fail("no leaf map") }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let hover = model.hover
        let host = NSHostingView(rootView: PopoverView().environmentObject(model).environmentObject(hover))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        settle(host)
        func log(_ s: String) { print("motion-capture: " + s) }
        var failures = 0
        func check(_ ok: Bool, _ what: String) { log((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
        func shot(_ name: String) { settle(host); capture(host, marker: nil, to: dir + "/" + name + ".png"); log("wrote \(name).png") }

        // Wind: sweep the pointer across the leaf's centre (view coordinates), 16 ms apart.
        let t = hover.transform, c = t.toView(leaf.centroid)
        check(!hover.windActive, "idle before the pointer moves (no timeline)")
        var clock = 1000.0
        for i in 0..<6 {
            clock += 0.016
            hover.wind.manualTime = clock
            hover.pointer(view: CGPoint(x: c.x - 60 + Double(i) * 24, y: c.y), in: map, at: clock)
            hover.wind.step(to: clock)
            if i % 2 == 1 { shot(String(format: "wind-moving-%d", i / 2)) }
        }
        check(hover.windActive && !hover.wind.spring.settled, "breeze active while the pointer moves")
        for (name, dt) in [("wind-stopped-0.1s", 0.1), ("wind-stopped-0.4s", 0.3)] {
            clock += dt; hover.wind.manualTime = clock; hover.wind.step(to: clock); shot(name)
        }
        var n = 0
        while !hover.wind.spring.settled && n < 600 { clock += 1.0 / 60; hover.wind.manualTime = clock; hover.wind.step(to: clock); n += 1 }
        hover.windSettled()
        shot("wind-settled")
        check(hover.wind.spring.settled && !hover.windActive, "settled \(String(format: "%.2f", 0.5 + Double(n) / 60)) s after stopping; timeline off")
        hover.wind.manualTime = nil

        // Blow-away (and the Reduce Motion fade) of one leaf, at fixed progress.
        for fade in [false, true] {
            for p in [0.0, 0.25, 0.5, 0.75, 1.0] {
                var g = ExitGhost(map: map, ids: [leaf.item.id], transform: hover.transform, start: 0, fade: fade)
                g.fixedProgress = p
                model.setGhost(g)
                shot(String(format: "%@-%03d", fade ? "fade" : "blow", Int(p * 100)))
            }
        }
        model.setGhost(nil)
        let end = BlowAway.frame(leaf.centroid, size: Pt(map.width, map.height), id: leaf.item.id, t: 1)
        check(end.opacity == 0, "blow-away ends transparent past the edge (dx \(Int(end.dx)), dy \(Int(end.dy)))")
        log("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
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
        // D23: really launch (a window can only become key in an active, launched app). Still no status item:
        // the App scene isn't created.
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let scan = ScanCache.load() ?? Scanner(config: ArboristConfig.load()).scan()
        let model = AppModel(sweepWith: scan)
        // D23: host the real PopoverView once, offscreen, so SettingsActionBridge registers openSettings (14+).
        let bridgeHost = NSHostingView(rootView: PopoverView().environmentObject(model).environmentObject(model.hover))
        let bridgeWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 480, height: 700),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        bridgeWindow.contentView = bridgeHost
        bridgeWindow.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
        // D33: the header Refresh button is drawn, ≥ 24 pt, and AppKit hit-tests it (nothing covers it); a
        // click mid-scan queues one rescan.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var refreshOK = false
        if let f = model.hover.drawnRefresh {
            let y = bridgeHost.isFlipped ? f.y + f.h / 2 : bridgeHost.bounds.height - (f.y + f.h / 2)
            let hit = bridgeHost.hitTest(NSPoint(x: f.x + f.w / 2, y: y))
            refreshOK = f.w >= 24 && f.h >= 24 && hit != nil
            log("refresh: frame \(f), hitTest → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        } else {
            log("refresh: not drawn")
        }
        // D34: footer icons share a centre line; the refresh icon spins during the scan.
        let icons = model.hover.drawnFooterIcons
        log("footer icons: " + icons.map { "\($0.name) \($0.rect) cy=\($0.rect.y + $0.rect.h / 2)" }.joined(separator: ", "))
        log("footer icons verdict: " + (icons.count == 2 && FooterIconLayout.aligned(icons.map(\.rect)) ? "OK" : "FAIL"))
        log("refresh spinning during scan: \(model.hover.refreshSpinning) (scanning=\(model.scanning))")
        let click = model.requestRescan()
        log("refresh: click while scanning=\(model.scanning) → \(click), queued=\(model.rescanQueued)")
        log("refresh verdict: " + (refreshOK && (click == .rescan || model.rescanQueued) ? "OK" : "FAIL"))

        // D23: how this process was launched and who is frontmost. On macOS 14+ activation is cooperative: only
        // the active app can yield (NSApp.yieldActivation(to:) is called by the *yielding* app on itself), so a
        // process started from Terminal can't make Terminal yield. Launched via `open` (scripts/action-check.sh)
        // LaunchServices activates it, the way a user launch or a click in its own menu bar window does.
        let front0 = NSWorkspace.shared.frontmostApplication
        log("launch: bundle=\(Bundle.main.bundleIdentifier ?? "none"), frontmost=\(front0?.localizedName ?? "none")"
            + " (pid \(front0?.processIdentifier ?? 0), self \(ProcessInfo.processInfo.processIdentifier)), active=\(NSApp.isActive)")

        var done = false
        SettingsOpener.shared.run(SettingsOpening.steps(osMajor: router.osMajor), model: model) { report in
            log("settings: fired; " + report)
            done = true
        }
        let until = Date().addingTimeInterval(5)
        while !done && Date() < until { pumpEvents(0.05) }
        if !done { log("settings: no report within 5 s") }
        // D23: retry activation + key for up to ~1 s, pumping real AppKit events (activation arrives as events).
        if let w = SettingsOpener.settingsWindow() {
            var tries = 0
            while !(NSApp.isActive && w.isKeyWindow) && tries < 10 {
                SettingsOpener.activateApp(); w.makeKeyAndOrderFront(nil)
                pumpEvents(0.1); tries += 1
            }
            let front = NSWorkspace.shared.frontmostApplication
            let ok = NSApp.isActive && w.isKeyWindow
            log("settings: after \(tries) retries active=\(NSApp.isActive), key=\(w.isKeyWindow), frontmost=\(front?.localizedName ?? "none")")
            log("settings verdict: " + (ok ? "PROVEN (front and key)"
                : front?.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    ? "HARNESS: activation refused while \(front?.localizedName ?? "another app") is frontmost (macOS 14 cooperative activation); run scripts/action-check.sh or click the gear"
                    : "BUG: app is frontmost but the Settings window isn't key"))
        }
        // Let the rescan finish (or time out) so its progress is logged too; it never writes the cache here.
        let scanUntil = Date().addingTimeInterval(40)
        while model.scanning && Date() < scanUntil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        // The queued rescan (D33) runs once; wait for it too, then 1 s, and the icon must be still.
        while model.scanning && Date() < scanUntil.addingTimeInterval(40) { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        log("rescan finished=\(!model.scanning), repos=\(model.scanned?.repos.count ?? 0), cached=\(model.resultIsCached), queued=\(model.rescanQueued)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        log("refresh spinning 1 s after: \(model.hover.refreshSpinning), scanning=\(model.scanning)")
        log("spin verdict: " + (!model.hover.refreshSpinning && !model.scanning ? "OK (stopped)" : "FAIL (still spinning)"))
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        bridgeWindow.orderOut(nil)
        log(done ? "done" : "done (settings unverified)")
    }

    /// Runs the AppKit event loop for `seconds` (not just the run loop): activation and key changes arrive as events.
    static func pumpEvents(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
        NSApp.updateWindows()
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
        // D26: `--repo-menu` captures the popover with the repo filter menu open.
        if CommandLine.arguments.contains("--repo-menu") {
            let checks = openRepoMenu(model, host: host, to: png)
            print("menu contrast failures: \(checks.filter(\.fails).count)")
            model.repoMenuOpen = true; settle(host)
        }
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

    /// D27: a borderless window that can be key, so the confirm's Esc/Return shortcuts receive key events.
    final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data("hover-sweep: \(m)\n".utf8)); exit(1)
    }
}
#endif
