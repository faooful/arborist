@testable import ArboristCore
import XCTest

@MainActor
final class FakeEffects: PopoverActionEffects {
    var isScanning = false
    var log: [String] = []
    func openSettings(_ steps: [SettingsOpening.Step]) { log.append("settings \(steps)") }
    func terminate() { log.append("terminate") }
    func rescan() { log.append("rescan"); isScanning = true }
    func toggleList() { log.append("list") }
}

/// D22: Settings, Quit, Rescan and List go through the router.
final class ActionRouterTests: XCTestCase, @unchecked Sendable {
    func testSettingsActivatesOpensAndFronts() {
        MainActor.assumeIsolated {
            let f = FakeEffects()
            XCTAssertEqual(PopoverActionRouter(effects: f).perform(.settings), .fired(.settings))
            XCTAssertEqual(f.log, ["settings \([SettingsOpening.Step.becomeRegular, .activate, .openSettingsAction, .orderFront, .fallbackWindow])"])
            let g = FakeEffects()
            PopoverActionRouter(effects: g, osMajor: 13).perform(.settings)
            XCTAssertTrue(g.log[0].contains("showSettingsSelector"), "macOS 13 uses the showSettingsWindow: selector")
        }
    }

    func testSettingsStepOrder() {
        MainActor.assumeIsolated {
            let s = SettingsOpening.steps(osMajor: 15)
            XCTAssertLessThan(s.firstIndex(of: .activate)!, s.firstIndex(of: .openSettingsAction)!, "activate before opening")
            XCTAssertLessThan(s.firstIndex(of: .openSettingsAction)!, s.firstIndex(of: .orderFront)!)
            XCTAssertEqual(s.last, .fallbackWindow)
            XCTAssertTrue(SettingsOpening.shouldBecomeAccessory(otherVisibleWindows: 0))
            XCTAssertFalse(SettingsOpening.shouldBecomeAccessory(otherVisibleWindows: 1))
        }
    }

    func testQuitTerminatesUnlessDryRun() {
        MainActor.assumeIsolated {
            let f = FakeEffects()
            XCTAssertEqual(PopoverActionRouter(effects: f, dryRunQuit: true).perform(.quit), .dryRun(.quit))
            XCTAssertEqual(f.log, [], "hook mode never quits")
            XCTAssertEqual(PopoverActionRouter(effects: f).perform(.quit), .fired(.quit))
            XCTAssertEqual(f.log, ["terminate"])
        }
    }

    func testRescanSkipsWhileScanning() {
        MainActor.assumeIsolated {
            let f = FakeEffects(), r = PopoverActionRouter(effects: f)
            XCTAssertTrue(r.isEnabled(.rescan))
            XCTAssertEqual(r.perform(.rescan), .fired(.rescan))
            XCTAssertFalse(r.isEnabled(.rescan), "disabled while the scan runs")
            XCTAssertEqual(r.perform(.rescan), .skipped(.rescan, reason: "a scan is already running"))
            XCTAssertEqual(f.log, ["rescan"])
        }
    }

    func testListToggles() {
        MainActor.assumeIsolated {
            let f = FakeEffects(), r = PopoverActionRouter(effects: f)
            r.perform(.list); r.perform(.list)
            XCTAssertEqual(f.log, ["list", "list"])
            XCTAssertEqual(PopoverActionOutcome.fired(.list).log, "list: fired")
            XCTAssertEqual(PopoverActionOutcome.dryRun(.quit).log, "quit: dry run (not performed)")
        }
    }
}
