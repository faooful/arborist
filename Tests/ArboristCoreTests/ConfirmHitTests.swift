@testable import ArboristCore
import XCTest

/// D27: the cleanup confirm's buttons are the topmost hit target; map and footer beneath take nothing.
final class ConfirmHitTests: XCTestCase, @unchecked Sendable {
    let size = Pt(480, 644)
    let map = Rect(x: 16, y: 48, w: 448, h: 380)
    let footer = [Rect(x: 16, y: 600, w: 72, h: 28), Rect(x: 96, y: 600, w: 64, h: 28)]

    func testButtonsAreTopmostWhileOpen() {
        let panel = Rect(x: 16, y: 200, w: ConfirmLayout.width, h: 180)
        let buttons = ConfirmLayout.buttons(panel: panel)
        XCTAssertEqual(buttons.map(\.name), ["Cancel", "Remove"])
        let layers = HitOrder.popover(size: size, map: map, footer: footer, confirm: buttons)
        XCTAssertEqual(HitOrder.failures(layers, buttons: buttons), [])
        // Map and footer beneath reach the dim layer, never themselves.
        XCTAssertEqual(HitOrder.topmost(at: Pt(30, 60), in: layers)?.name, "dim")
        XCTAssertEqual(HitOrder.topmost(at: Pt(40, 610), in: layers)?.name, "dim")
    }

    func testOldOrderFails() {
        // A map/catcher layer above the confirm (the bug) steals both buttons.
        let buttons = ConfirmLayout.buttons(panel: Rect(x: 16, y: 300, w: ConfirmLayout.width, h: 120))
        var layers = HitOrder.popover(size: size, map: map, footer: footer, confirm: buttons)
        layers.append(HitLayer(name: "catcher", z: ConfirmLayout.zIndex + 5, frame: Rect(x: 0, y: 0, w: 480, h: 644)))
        XCTAssertEqual(HitOrder.failures(layers, buttons: buttons), ["Cancel", "Remove"])
    }

    func testClosedConfirmLeavesMapHittable() {
        let layers = HitOrder.popover(size: size, map: map, footer: footer, confirm: nil)
        XCTAssertEqual(HitOrder.topmost(at: Pt(30, 60), in: layers)?.name, "map")
        XCTAssertEqual(HitOrder.topmost(at: Pt(40, 610), in: layers)?.name, "footer0")
    }

    func testPruneOnlyWording() {
        XCTAssertEqual(ConfirmWording.summary(bytes: [0], pruneOnly: [true]), "Already deleted on disk; removes the stale git entry.")
        XCTAssertFalse(ConfirmWording.summary(bytes: [0], pruneOnly: [true]).contains("0 B"))
        XCTAssertEqual(ConfirmWording.summary(bytes: [0, 0], pruneOnly: [true, true]), "Already deleted on disk; removes 2 stale git entries.")
        let mixed = ConfirmWording.summary(bytes: [1_000_000, 5_000_000_000], pruneOnly: [false, true])
        XCTAssertTrue(mixed.hasPrefix("Frees about \(Format.bytes(1_000_000))"), mixed)
        XCTAssertTrue(mixed.hasSuffix("· 1 already deleted"), mixed)
    }
}
