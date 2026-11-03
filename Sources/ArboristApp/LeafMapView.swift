#if os(macOS)
import ArboristCleanup
import ArboristCore
import SwiftUI

/// Draws the worktree leaf map (D12, D13, D15, D22).
///
/// Hover (D15): `HoverModel` is the only source of truth, fed by `MouseTracking` (an NSTrackingArea, because
/// SwiftUI hover didn't fire in the MenuBarExtra window). The pointer always maps to the leaf under it at once
/// (D22: no corridor, grace or dwell); in a far gap or off the map hover clears after 80 ms (D16). The hovered
/// leaf gets a ring, a tooltip follows the pointer, and the docked DetailStrip below the map shows the pinned
/// or hovered leaf. Click pins; Esc or empty space unpins. Reduce Motion: no fades.
struct LeafMapView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: HoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let map: LeafMap
    let result: ScanResult

    var body: some View {
        // D17: the map has an explicit, clipped frame (448×400), so the popover window, which sizes itself
        // to the content's ideal size, can't collapse it. One MapTransform (D15), from the size this view
        // really gets, places the drawing and maps pointer events back; a frame below the minimum is
        // ignored (nothing drawn, last good transform kept).
        GeometryReader { g in
            if let t = MapTransform.usable(map, into: Pt(g.size.width, g.size.height)) {
            content
                .frame(width: map.width, height: map.height, alignment: .topLeading)
                .scaleEffect(t.scale, anchor: .topLeading)
                .offset(x: t.dx, y: t.dy)
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
                // Same frame as the drawing's container, so the tracking area covers exactly what is drawn.
                .background(MouseTracking(onMove: { p in hover.pointer(view: p, in: map) }, onExit: { hover.exit() }))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in hover.click(view: p, in: map) }
                .onAppear { hover.transform = t }
                .onChange(of: t) { nt in hover.transform = nt }
            }
        }
        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.mapHeight)
        // Only the leaf drawing is clipped; the tooltip is drawn by TooltipOverlay above the popover (D22).
        .clipped()
        .background(GeometryReader { g in
            Color.clear
                .onAppear { hover.mapOrigin = Pt(g.frame(in: .named(PopoverCoords.name)).minX, g.frame(in: .named(PopoverCoords.name)).minY) }
                .onChange(of: g.frame(in: .named(PopoverCoords.name))) { f in hover.mapOrigin = Pt(f.minX, f.minY) }
        })
        .onExitCommand { hover.unpin() } // D22: Esc unpins
        .onDisappear { hover.reset() }
        .onAppear { hover.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { r in hover.reduceMotion = r }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Worktree map: \(result.headline). The list has every worktree.")
    }

    /// Everything in layout coordinates; LeafMapView.body places it with the transform.
    /// D22: other leaves dim only slightly; the hovered leaf gets a 2 pt dark ring, the pinned one a stronger
    /// ring, in the strip's accent colour. Drawing only: nothing here takes hit-testing.
    @ViewBuilder private var content: some View {
        let v = hover.visible
        let ringed = Set([v.hovered, v.pinned].compactMap { $0 })
        ZStack(alignment: .topLeading) {
            LeafCanvas(map: map, only: nil)
                .opacity(ringed.isEmpty ? 1 : LeafPalette.dimOthers)
            if !ringed.isEmpty {
                LeafCanvas(map: map, only: ringed).allowsHitTesting(false)
                LeafRings(map: map, hovered: v.hovered, pinned: v.pinned).allowsHitTesting(false)
            }
            ForEach(map.groupLabels, id: \.name) { g in
                Text(g.name).font(.system(size: LeafText.groupSize, weight: .medium)).foregroundColor(Theme.ink3)
                    .fixedSize().position(x: g.at.x, y: g.at.y - 4)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion || hover.instant ? nil : .easeInOut(duration: HoverTracker.duration(reduceMotion: false)), value: ringed)
    }
}

/// The popover's named coordinate space (D19).
enum PopoverCoords { static let name = "popover" }

/// D22: the rings on the hovered and pinned leaves.
struct LeafRings: View {
    let map: LeafMap
    let hovered: String?
    let pinned: String?

    var body: some View {
        Canvas { ctx, _ in
            for leaf in map.leaves {
                let w = leaf.item.id == pinned ? LeafPalette.ringPinned : (leaf.item.id == hovered ? LeafPalette.ringHover : 0)
                guard w > 0 else { continue }
                ctx.stroke(LeafCanvas.path(leaf.outline), with: .color(Color(hex: LeafPalette.ring)),
                           style: StrokeStyle(lineWidth: w, lineJoin: .round))
            }
        }
        .frame(width: map.width, height: map.height)
    }
}

/// D22: the tooltip that follows the pointer (branch, repo, size). Drawn in an overlay on the popover root,
/// placed by Core against the whole popover; it never takes hit-testing.
struct TooltipOverlay: View {
    @EnvironmentObject var hover: HoverModel
    let result: ScanResult

    var body: some View {
        let v = hover.visible
        ZStack(alignment: .topLeading) {
            if let id = v.hovered, let o = v.tooltipOrigin, let ref = WorktreeList.find(result, path: id) {
                let t = LeafTooltip(HoverCard(ref))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.branch).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    Text(t.repo).font(.system(size: 10.5)).foregroundColor(Theme.ink2).lineLimit(1)
                    Text(t.size).font(.system(size: 10.5)).foregroundColor(Theme.ink).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(width: TooltipPlacement.size.x, height: TooltipPlacement.size.y, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: LeafPalette.cardFill)).shadow(color: .black.opacity(0.12), radius: 4, y: 2))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: LeafPalette.cardStroke), lineWidth: 0.6))
                .offset(x: o.x, y: o.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// All leaves (or just `only`) with their branch labels.
struct LeafCanvas: View {
    let map: LeafMap
    let only: Set<String>?

    var body: some View {
        Canvas { ctx, _ in
            for leaf in map.leaves where only == nil || only!.contains(leaf.item.id) { draw(leaf, in: &ctx) }
        }
        .frame(width: map.width, height: map.height)
    }

    static func path(_ pts: [Pt]) -> Path {
        var p = Path()
        guard let f = pts.first else { return p }
        p.move(to: CGPoint(x: f.x, y: f.y))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
        p.closeSubpath()
        return p
    }

    private func draw(_ leaf: Leaf, in ctx: inout GraphicsContext) {
        let st = leaf.item.state, shape = Self.path(leaf.outline)
        ctx.fill(shape, with: .color(Color(hex: LeafPalette.fill(st))))
        if st == .stale { ctx.stroke(shape, with: .color(Color(hex: LeafPalette.staleStroke)), lineWidth: 0.4) }
        if !leaf.inner.isEmpty {
            ctx.fill(Self.path(leaf.inner), with: .color(Color(hex: LeafPalette.rebuildableShade, opacity: LeafPalette.rebuildableOpacity(st))))
        }
        let (vc, vo) = LeafPalette.vein(st)
        ctx.drawLayer { layer in
            layer.clip(to: shape)
            for v in leaf.veins {
                var p = Path()
                p.move(to: CGPoint(x: v.p0.x, y: v.p0.y))
                p.addQuadCurve(to: CGPoint(x: v.p1.x, y: v.p1.y), control: CGPoint(x: v.c.x, y: v.c.y))
                layer.stroke(p, with: .color(Color(hex: vc, opacity: vo * v.opacity)), style: StrokeStyle(lineWidth: v.width, lineCap: .round))
            }
        }
        if let name = leaf.labelLines.first {
            let lc = LeafPalette.isDark(st) ? Color(hex: LeafPalette.labelOnDark) : Color(hex: "#1c1e21")
            ctx.draw(Text(name).font(.system(size: LeafText.leafSize, weight: .medium)).foregroundColor(lc),
                     at: CGPoint(x: leaf.centroid.x, y: leaf.centroid.y))
        }
    }
}

/// D24: the detail strip. Nothing at rest; on hover or pin it fades in (0.2 s, none with Reduce Motion) over
/// the fixed footer slot below the map. Shows the pinned leaf, else the hovered one. Fixed rows and columns
/// from Core's StripLayout: only the values swap, single-line and truncated, with no animation on content.
struct DetailStrip: View {
    @EnvironmentObject var hover: HoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let result: ScanResult

    var body: some View {
        let v = hover.visible
        let ref = v.strip.flatMap { WorktreeList.find(result, path: $0) }
        ZStack(alignment: .topLeading) {
            if let ref {
                StripContent(card: HoverCard(ref), ref: ref, pinned: v.pinned != nil)
                    .transaction { $0.animation = nil } // values swap in place, never animate
                    .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: LeafPalette.cardFill)))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(v.pinned != nil ? Color(hex: LeafPalette.ring) : Color(hex: LeafPalette.cardStroke), lineWidth: v.pinned != nil ? 1.2 : 0.6))
                    .transition(.opacity)
            }
        }
        .frame(width: PopoverLayout.mapWidth, alignment: .topLeading)
        .animation(reduceMotion || hover.instant ? nil : .easeInOut(duration: PopoverLayout.stripFade), value: ref != nil)
        .onPreferenceChange(StripFramesKey.self) { hover.drawnStripFrames = $0.isEmpty ? nil : $0 }
    }
}

/// D24: the strip's drawn text and button frames (popover coordinates), for the sweep.
struct StripFramesKey: PreferenceKey {
    static let defaultValue: [Rect] = []
    static func reduce(value: inout [Rect], nextValue: () -> [Rect]) { value += nextValue() }
}

extension View {
    /// D24: a fixed frame from StripLayout, reported to the sweep as drawn.
    func stripFrame(_ r: Rect, alignment: Alignment = .topLeading) -> some View {
        frame(width: r.w, height: r.h, alignment: alignment)
            .clipped()
            .background(GeometryReader { g in
                let f = g.frame(in: .named(PopoverCoords.name))
                Color.clear.preference(key: StripFramesKey.self, value: [Rect(x: f.minX, y: f.minY, w: f.width, h: f.height)])
            })
            .padding(EdgeInsets(top: r.y, leading: r.x, bottom: 0, trailing: 0)) // layout, so the geometry is real
    }
}

struct StripContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var hover: HoverModel
    let card: HoverCard
    let ref: WorktreeRef
    let pinned: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 7) {
                Text(card.branch).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink)
                    .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text(card.pill).font(.system(size: 10, weight: .medium)).lineLimit(1).fixedSize()
                    .foregroundColor(Color(hex: LeafPalette.pillText(card.status)))
                    .padding(.horizontal, 6).frame(height: 14)
                    .background(Capsule().fill(Color(hex: LeafPalette.dot(card.status), opacity: 0.2)))
                Text(card.repo).font(.system(size: 11)).foregroundColor(Theme.ink2).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if pinned {
                    Button { hover.unpin() } label: { Text("Pinned · Esc").font(.system(size: 10)) }
                        .buttonStyle(HoverButtonStyle(kind: .link, height: 16))
                        .foregroundColor(Color(hex: LeafPalette.ring))
                        .help("Unpin (Esc, or click empty space on the map)")
                        .fixedSize()
                }
            }
            .stripFrame(StripLayout.row("title"), alignment: .leading)
            Text(card.path).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.ink2)
                .lineLimit(1).truncationMode(.middle).help(card.fullPath)
                .stripFrame(StripLayout.row("path"), alignment: .leading)
            Color.clear.stripFrame(StripLayout.row("stats"))
            let stats = [("Size", card.size), ("Changes", card.changes), ("Sync", card.sync), ("Last commit", card.lastCommit)]
            ForEach(stats.indices, id: \.self) { k in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stats[k].0).font(.system(size: 10)).foregroundColor(Theme.ink2).lineLimit(1)
                    Text(stats[k].1).font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundColor(Theme.ink)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help(k == 0 ? (card.rebuildable ?? "") : "")
                .stripFrame(StripLayout.columns[k])
            }
            Text(card.message.joined(separator: " ")).font(.system(size: 11)).foregroundColor(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .stripFrame(StripLayout.row("message"), alignment: .leading)
            // Fixed frames from StripLayout (the sweep's reach path ends on the first one).
            let y = PopoverLayout.stripHeight - StripLayout.padding - StripLayout.row
            ForEach(StripLayout.buttons.indices, id: \.self) { i in
                let b = StripLayout.buttons[i]
                button(b.name)
                    .stripFrame(Rect(x: StripLayout.padding + b.x, y: y, w: b.w, h: StripLayout.row), alignment: .center)
            }
        }
        .frame(width: PopoverLayout.mapWidth, height: PopoverLayout.stripHeight, alignment: .topLeading)
    }

    @ViewBuilder private func button(_ name: String) -> some View {
        switch name {
        case "Reveal in Finder":
            Button(name) { model.reveal(ref.worktree.path) }.buttonStyle(HoverButtonStyle())
        case "Copy remove command":
            Button(name) { if let c = card.removeCommand { model.copy(c) } }
                .buttonStyle(HoverButtonStyle())
                .disabled(card.removeCommand == nil)
                .help(card.removeCommand ?? "The main worktree can't be removed.")
        default:
            RemoveButton(ref: ref, showReason: false).buttonStyle(HoverButtonStyle())
        }
    }
}

/// Menu bar glyph for a wilt stage, as a template image so it follows light and dark mode.
enum LeafIcon {
    static func image(_ stage: LeafStage) -> NSImage {
        let g = LeafGlyph.glyph(stage)
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            func bez(_ pts: [Pt], close: Bool) -> NSBezierPath {
                let b = NSBezierPath()
                for (i, p) in pts.enumerated() {
                    let q = NSPoint(x: p.x * rect.width, y: p.y * rect.height)
                    i == 0 ? b.move(to: q) : b.line(to: q)
                }
                if close { b.close() }
                b.lineCapStyle = .round; b.lineJoinStyle = .round
                return b
            }
            NSColor.black.set()
            let outline = bez(g.outline, close: true)
            if g.filled { outline.fill() } else { outline.lineWidth = 1.1; outline.stroke() }
            let stem = bez(g.stem, close: false); stem.lineWidth = 1.3; stem.stroke()
            if g.filled {
                // Cut the midrib out of the fill so it reads at 18 pt.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let rib = bez(g.midrib, close: false); rib.lineWidth = 0.8; rib.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
#endif
