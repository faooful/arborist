import XCTest
@testable import ArboristCore

final class DeclutterLayoutTests: XCTestCase {
    var busy: LeafMap { LeafLayout.layout(LeafLayout.groups(from: LeafSample.busy)) }

    func testGroupLabelsNeverCollideAndStayInBounds() {
        for seed in ["arborist", "a", "b", "c", "d"] {
            let m = LeafLayout.layout(LeafLayout.groups(from: LeafSample.busy), seed: seed)
            XCTAssertFalse(m.groupLabels.isEmpty)
            for (i, a) in m.groupLabels.enumerated() {
                XCTAssertFalse(a.vertical, "no rotated side labels")
                XCTAssertTrue(a.rect.inside(width: m.width, height: m.height), "\(a.name) out of bounds")
                for b in m.groupLabels[(i + 1)...] { XCTAssertFalse(a.rect.intersects(b.rect), "\(a.name) hits \(b.name) (seed \(seed))") }
            }
        }
    }

    func testPlaceLabelsDropsTheLoserOfACollision() {
        let a = GroupLabel(name: "figma-find", at: Pt(100, 10)), b = GroupLabel(name: "lexicon", at: Pt(130, 10))
        let edge = GroupLabel(name: "outputs.space", at: Pt(2, 10))
        let kept = LeafLayout.placeLabels([(1, b), (5, a), (9, edge)], width: 448, height: 400)
        XCTAssertEqual(kept.map(\.name), ["figma-find"], "bigger group wins, the label off the edge is dropped")
    }

    func testLeafTextIsBranchOnlyAndFitsAt10_5() {
        let m = busy
        XCTAssertGreaterThan(m.leaves.filter { !$0.labelLines.isEmpty }.count, 10)
        for l in m.leaves {
            XCTAssertFalse(l.showSize, "no sizes on leaves")
            XCTAssertNil(l.subLabel)
            XCTAssertLessThanOrEqual(l.labelLines.count, 1)
            if let t = l.labelLines.first {
                XCTAssertEqual(t, l.item.name)
                XCTAssertTrue(LeafText.fits(t, in: l.outline, at: l.centroid, size: 10.5), t)
            } else {
                XCTAssertFalse(LeafText.fits(l.item.name, in: l.outline, at: l.centroid, size: 10.5), "\(l.item.name) fits but has no text")
            }
        }
    }

    func testTextFitMeasure() {
        let square = [Pt(0, 0), Pt(60, 0), Pt(60, 40), Pt(0, 40)]
        XCTAssertTrue(LeafText.fits("main", in: square, at: Pt(30, 20)))
        XCTAssertFalse(LeafText.fits("feat-t5b-handover", in: square, at: Pt(30, 20)))
        XCTAssertGreaterThan(LeafText.width("mmmm", size: 10.5), LeafText.width("iiii", size: 10.5))
    }

    func testZeroByteWorktreesKeepAFixedMinimumLeaf() {
        let r = LeafSample.busy
        let zero = r.repos.flatMap(\.worktrees).filter { $0.size.total == 0 }
        XCTAssertGreaterThanOrEqual(zero.count, 3)
        let m = busy
        XCTAssertEqual(m.leaves.count, r.worktreeCount, "nothing folded into 'other'")
        for w in zero {
            let l = try! XCTUnwrap(m.leaves.first { $0.item.id == w.path })
            XCTAssertGreaterThan(Geo.area(l.outline), LeafLayout.minLeaf * LeafLayout.minLeaf * 0.5, w.path)
        }
    }

    func testCardNeverCoversTheHoveredLeafWhenThereIsRoom() {
        let m = busy
        for l in m.leaves {
            let (x0, y0, x1, y1) = Geo.bbox(l.outline)
            let leaf = Rect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
            let size = Pt(LeafSVG.cardWidth, 190)
            let o = LeafSVG.cardOrigin(avoiding: leaf, size: size, in: Pt(m.width, m.height))
            let card = Rect(x: o.x, y: o.y, w: size.x, h: size.y)
            XCTAssertTrue(card.inside(width: m.width, height: m.height))
            let g = 14.0
            let roomX = leaf.x >= size.x + g || leaf.x + leaf.w <= m.width - size.x - g
            let roomY = leaf.y >= size.y + g || leaf.y + leaf.h <= m.height - size.y - g
            if roomX || roomY { XCTAssertFalse(card.intersects(leaf), l.item.name) }
        }
    }
}

final class HoverTrackerTests: XCTestCase {
    func testEnterMoveLeaveWithDebounce() {
        var h = HoverTracker()
        XCTAssertTrue(h.pointer("a", at: 0))
        XCTAssertEqual(h.hovered, "a"); XCTAssertEqual(h.card, "a")
        // Crossing a gutter to a neighbour: no flicker, the card goes straight to b.
        XCTAssertFalse(h.pointer(nil, at: 0.30))
        XCTAssertEqual(h.hovered, "a"); XCTAssertNotNil(h.clearAt)
        XCTAssertTrue(h.pointer("b", at: 0.35))
        XCTAssertEqual(h.card, "b"); XCTAssertNil(h.clearAt)
        XCTAssertFalse(h.settle(at: 1), "nothing pending")
        // Real leave: clears only after the delay.
        h.pointer(nil, at: 2)
        XCTAssertFalse(h.settle(at: 2.05)); XCTAssertEqual(h.hovered, "b")
        XCTAssertTrue(h.settle(at: 2 + HoverTracker.leaveDelay))
        XCTAssertNil(h.hovered); XCTAssertNil(h.card)
        XCTAssertFalse(h.pointer(nil, at: 3), "leaving when nothing is hovered changes nothing")
    }

    func testAppearanceAndReduceMotion() {
        var h = HoverTracker()
        XCTAssertEqual(h.appearance(of: "x", reduceMotion: false).opacity, 1)
        h.pointer("a", at: 0)
        XCTAssertEqual(h.appearance(of: "a", reduceMotion: false).scale, 1.03, accuracy: 1e-9)
        XCTAssertEqual(h.appearance(of: "a", reduceMotion: true).scale, 1)
        XCTAssertEqual(h.appearance(of: "b", reduceMotion: false).opacity, 0.88, accuracy: 1e-9)
        XCTAssertEqual(h.appearance(of: "b", reduceMotion: false).scale, 1)
        XCTAssertGreaterThanOrEqual(HoverTracker.duration(reduceMotion: false), 0.15)
        XCTAssertLessThanOrEqual(HoverTracker.duration(reduceMotion: false), 0.2)
    }
}

final class HoverCardFormatTests: XCTestCase {
    func testMiddleAbbreviation() {
        let p = "~/conductor/workspaces/property-management/feat-t5b-handover"
        let m = Format.middle(p, max: 38)
        XCTAssertLessThanOrEqual(m.count, 38)
        XCTAssertTrue(m.hasPrefix("~/conductor/")); XCTAssertTrue(m.hasSuffix("/feat-t5b-handover")); XCTAssertTrue(m.contains("…"))
        XCTAssertEqual(Format.middle("~/code/app", max: 38), "~/code/app")
        let noSlash = Format.middle(String(repeating: "x", count: 60), max: 20)
        XCTAssertEqual(noSlash.count, 20)
    }

    func testSyncAndAge() {
        XCTAssertEqual(Format.sync(ahead: 1, behind: 766, hasUpstream: true, gone: false), "1 ahead · 766 behind")
        XCTAssertEqual(Format.sync(ahead: 0, behind: 3, hasUpstream: true, gone: false), "3 behind")
        XCTAssertEqual(Format.sync(ahead: 0, behind: 0, hasUpstream: true, gone: false), "Up to date")
        XCTAssertEqual(Format.sync(ahead: nil, behind: nil, hasUpstream: false, gone: false), "No upstream")
        XCTAssertEqual(Format.sync(ahead: nil, behind: nil, hasUpstream: false, gone: true), "Upstream deleted")
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        XCTAssertEqual(Format.age(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-86400), now: now), "1 day ago")
        XCTAssertEqual(Format.age(now.addingTimeInterval(-86400 * 185), now: now), "6 months ago")
        XCTAssertEqual(Format.files(0), "None"); XCTAssertEqual(Format.files(1), "1 file"); XCTAssertEqual(Format.files(5), "5 files")
    }

    func testWordBoundaryWrap() {
        let msg = "fix(wasm): preserve hot-update chunks when the dev server restarts after a config change"
        let l = Format.wrap(msg, width: 40, maxLines: 2)
        XCTAssertEqual(l.count, 2)
        XCTAssertTrue(l.allSatisfy { $0.count <= 40 })
        XCTAssertTrue(l[1].hasSuffix("…"))
        let words = Set(msg.split(separator: " ").map(String.init))
        for w in (l[0] + " " + l[1].dropLast()).split(separator: " ") { XCTAssertTrue(words.contains(String(w)), "cut mid-word: \(w)") }
        XCTAssertEqual(Format.wrap("short message", width: 40, maxLines: 2), ["short message"])
        XCTAssertEqual(Format.wrap("", width: 40, maxLines: 2), [])
        XCTAssertEqual(Format.wrap(String(repeating: "a", count: 50), width: 10, maxLines: 2), ["aaaaaaaaa…"])
    }
}
