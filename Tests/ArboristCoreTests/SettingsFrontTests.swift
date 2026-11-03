@testable import ArboristCore
import XCTest

@MainActor
final class FakeWindowDriver: SettingsWindowDriver {
    var panelIsKey: Bool
    var log: [String] = []
    init(panelIsKey: Bool) { self.panelIsKey = panelIsKey }
    func closePanel() { log.append("closePanel"); panelIsKey = false }
    func activateApp() { log.append("activate") }
    func makeKeyAndOrderFront() { log.append("makeKeyAndOrderFront") }
    func orderFrontRegardless() { log.append("orderFrontRegardless") }
}

/// D23: the Settings window is fronted in order: close the panel, activate, then make key.
final class SettingsFrontTests: XCTestCase, @unchecked Sendable {
    func testPanelKeyClosesItFirst() {
        MainActor.assumeIsolated {
            let d = FakeWindowDriver(panelIsKey: true)
            SettingsOpening.front(d)
            XCTAssertEqual(d.log, ["closePanel", "activate", "makeKeyAndOrderFront", "orderFrontRegardless"])
        }
    }

    func testNoPanelSkipsClose() {
        MainActor.assumeIsolated {
            let d = FakeWindowDriver(panelIsKey: false)
            XCTAssertEqual(SettingsOpening.front(d), [.activate, .makeKeyAndOrderFront, .orderFrontRegardless])
            XCTAssertEqual(d.log, ["activate", "makeKeyAndOrderFront", "orderFrontRegardless"])
        }
    }

    func testActivateAlwaysBeforeMakeKey() {
        for panel in [true, false] {
            let s = SettingsOpening.frontSteps(panelIsKey: panel)
            XCTAssertLessThan(s.firstIndex(of: .activate)!, s.firstIndex(of: .makeKeyAndOrderFront)!)
            if panel { XCTAssertEqual(s.first, .closePanel) }
        }
    }
}
