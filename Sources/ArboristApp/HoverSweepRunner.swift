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
        // The popover's content width is 448; the map keeps its aspect ratio, as in LeafMapView.
        hover.transform = MapTransform.fit(map, into: Pt(448, 448 * map.height / map.width))
        let path = HoverSweep.path(in: map)
        var frames: [HoverSweep.Frame] = []
        var t = 0.0, last = CGPoint(x: -1, y: -1)
        for (i, p) in path.enumerated() {
            if let p {
                last = CGPoint(x: p.x, y: p.y)
                // In view coordinates through the transform, exactly like the NSTrackingArea's mouseMoved.
                let vp = hover.transform.toView(p)
                hover.pointer(view: CGPoint(x: vp.x, y: vp.y), in: map, at: t, animated: false)
            } else {
                hover.exit(at: t, animated: false)
                hover.settle(at: t, animated: false)
            }
            let tr = hover.tracker
            frames.append(HoverSweep.Frame(frame: i, x: last.x, y: last.y, t: t, hovered: tr.hovered,
                                           cardShown: tr.card != nil, cardX: tr.cardOrigin?.x, cardY: tr.cardOrigin?.y))
            render(model: model, to: dir + String(format: "/frame-%03d.png", i))
            t += p == nil ? HoverTracker.leaveDelay + 0.01 : 1.0 / 30
        }
        do { try HoverSweep.json(frames).write(to: URL(fileURLWithPath: dir + "/frames.json")) } catch { fail("\(error)") }
        precondition(model.pendingCleanup == nil && model.cleanupResults == nil && !model.cleaning, "cleanup must not run")
        print("\(frames.count) frames in \(dir)")
    }

    private static func render(model: AppModel, to path: String) {
        let view = PopoverView().environmentObject(model).environmentObject(model.hover)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { fail("ImageRenderer returned no image") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed") }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
    }

    private static func fail(_ m: String) -> Never {
        FileHandle.standardError.write(Data("hover-sweep: \(m)\n".utf8)); exit(1)
    }
}
#endif
