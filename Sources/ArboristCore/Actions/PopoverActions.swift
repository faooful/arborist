import Foundation

/// D22: the popover's toolbar actions. The app routes Settings, Quit, Rescan and List through
/// `PopoverActionRouter`, so the decisions (skip a rescan while one runs, never quit in hook mode,
/// how Settings is brought to the front) are plain Core logic, unit-tested with a fake.
public enum PopoverAction: String, CaseIterable, Sendable {
    case settings, quit, rescan, list
}

/// What actually happens; the app implements it with NSApp / AppModel, tests with a fake.
@MainActor
public protocol PopoverActionEffects: AnyObject {
    /// True while a scan runs (Rescan is then disabled and skipped).
    var isScanning: Bool { get }
    /// Runs the steps that open the Settings window and bring it to the front.
    func openSettings(_ steps: [SettingsOpening.Step])
    func terminate()
    /// A full rescan that bypasses the cache and reports progress.
    func rescan()
    func toggleList()
}

/// What the router did with an action.
public enum PopoverActionOutcome: Equatable, Sendable {
    case fired(PopoverAction)
    case skipped(PopoverAction, reason: String)
    /// Hook mode: Quit is logged, never performed.
    case dryRun(PopoverAction)

    public var log: String {
        switch self {
        case .fired(let a): return "\(a.rawValue): fired"
        case .skipped(let a, let r): return "\(a.rawValue): skipped (\(r))"
        case .dryRun(let a): return "\(a.rawValue): dry run (not performed)"
        }
    }
}

@MainActor
public struct PopoverActionRouter {
    public let effects: PopoverActionEffects
    /// Debug hook mode: Quit never terminates.
    public var dryRunQuit: Bool
    public var osMajor: Int

    public init(effects: PopoverActionEffects, dryRunQuit: Bool = false, osMajor: Int = 14) {
        self.effects = effects; self.dryRunQuit = dryRunQuit; self.osMajor = osMajor
    }

    /// True when the action's button is enabled.
    public func isEnabled(_ a: PopoverAction) -> Bool { a == .rescan ? !effects.isScanning : true }

    @discardableResult
    public func perform(_ a: PopoverAction) -> PopoverActionOutcome {
        switch a {
        case .settings:
            effects.openSettings(SettingsOpening.steps(osMajor: osMajor))
            return .fired(a)
        case .quit:
            if dryRunQuit { return .dryRun(a) }
            effects.terminate()
            return .fired(a)
        case .rescan:
            guard !effects.isScanning else { return .skipped(a, reason: "a scan is already running") }
            effects.rescan()
            return .fired(a)
        case .list:
            effects.toggleList()
            return .fired(a)
        }
    }
}

/// How a menu-bar-only (accessory) app gets its Settings window in front of other apps. An accessory app's
/// Settings window opens behind the frontmost app, or not at all from a MenuBarExtra, unless the app becomes
/// a regular app and activates first; once Settings closes it goes back to accessory (no Dock icon).
public enum SettingsOpening {
    public enum Step: Equatable, Sendable {
        /// NSApp.setActivationPolicy(.regular)
        case becomeRegular
        /// NSApp.activate(ignoringOtherApps: true)
        case activate
        /// macOS 14+: the SwiftUI `openSettings` environment action.
        case openSettingsAction
        /// macOS 13: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case showSettingsSelector
        /// After a short delay: find the Settings window and makeKeyAndOrderFront + orderFrontRegardless.
        case orderFront
        /// If no Settings window appeared: show our own window hosting SettingsView.
        case fallbackWindow
    }

    public static func steps(osMajor: Int) -> [Step] {
        [.becomeRegular, .activate, osMajor >= 14 ? .openSettingsAction : .showSettingsSelector, .orderFront, .fallbackWindow]
    }

    /// After the Settings window closes: back to a menu-bar-only app unless another window is still open.
    public static func shouldBecomeAccessory(otherVisibleWindows: Int) -> Bool { otherVisibleWindows == 0 }
}

/// D23: bringing the found Settings window to the front *and key*. The MenuBarExtra panel holds key while the
/// gear is clicked, and on macOS 14+ activation is cooperative, so the order matters: close the panel, activate
/// (again, now that the window exists), then makeKeyAndOrderFront, then orderFrontRegardless.
@MainActor
public protocol SettingsWindowDriver: AnyObject {
    /// True if the MenuBarExtra panel (or another panel) is currently key.
    var panelIsKey: Bool { get }
    func closePanel()
    func activateApp()
    func makeKeyAndOrderFront()
    func orderFrontRegardless()
}

extension SettingsOpening {
    public enum FrontStep: Equatable, Sendable { case closePanel, activate, makeKeyAndOrderFront, orderFrontRegardless }

    public static func frontSteps(panelIsKey: Bool) -> [FrontStep] {
        (panelIsKey ? [.closePanel] : []) + [.activate, .makeKeyAndOrderFront, .orderFrontRegardless]
    }

    /// Runs `frontSteps` against the driver, in order; returns what ran.
    @MainActor @discardableResult
    public static func front(_ d: SettingsWindowDriver) -> [FrontStep] {
        let steps = frontSteps(panelIsKey: d.panelIsKey)
        for s in steps {
            switch s {
            case .closePanel: d.closePanel()
            case .activate: d.activateApp()
            case .makeKeyAndOrderFront: d.makeKeyAndOrderFront()
            case .orderFrontRegardless: d.orderFrontRegardless()
            }
        }
        return steps
    }
}
