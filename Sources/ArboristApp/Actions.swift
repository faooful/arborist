#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// D22: the app side of the action seam. Settings, Quit, Rescan and List go through `PopoverActionRouter`
/// (Core, unit-tested with a fake); this is what they actually do.
extension AppModel: PopoverActionEffects {
    var isScanning: Bool { scanning }
    func openSettings(_ steps: [SettingsOpening.Step]) { SettingsOpener.shared.run(steps, model: self) }
    func terminate() {
        precondition(!cleanupDisabled, "hook mode never quits")
        NSApp.terminate(nil)
    }
    func toggleList() { showList.toggle() }

    var router: PopoverActionRouter {
        PopoverActionRouter(effects: self, dryRunQuit: cleanupDisabled,
                            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

/// Opens the Settings window from a menu-bar-only app and brings it to the front. The MenuBarExtra pitfall:
/// an accessory app's Settings window opens behind the frontmost app (or the `showSettingsWindow:` action
/// finds no responder), so we become a regular app, activate, open, then order the window front; if no
/// Settings window shows up, we host SettingsView in our own window. Back to accessory when it closes.
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()
    /// macOS 14+: the SwiftUI openSettings action, captured by `SettingsActionBridge` in the popover.
    var openAction: (() -> Void)?
    /// What happened on the last open (the `--action-check` hook logs it).
    private(set) var lastReport = ""
    private var fallback: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func run(_ steps: [SettingsOpening.Step], model: AppModel, then done: (@MainActor (String) -> Void)? = nil) {
        var log: [String] = []
        for step in steps {
            switch step {
            case .becomeRegular:
                NSApp.setActivationPolicy(.regular); log.append("policy=regular")
            case .activate:
                NSApp.activate(ignoringOtherApps: true); log.append("activated")
            case .openSettingsAction:
                if let a = openAction { a(); log.append("openSettings") } else {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); log.append("showSettingsWindow: (no openSettings bridge)")
                }
            case .showSettingsSelector:
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); log.append("showSettingsWindow:")
            case .orderFront, .fallbackWindow:
                break // after a short delay, below
            }
        }
        // The Settings scene creates its window asynchronously.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var w = Self.settingsWindow()
                if w == nil, steps.contains(.fallbackWindow) {
                    w = self.showFallback(model: model); log.append("fallback window")
                }
                if let w, steps.contains(.orderFront) {
                    w.makeKeyAndOrderFront(nil); w.orderFrontRegardless(); log.append("ordered front")
                    self.watchClose(w)
                }
                let key = w.map { $0 == NSApp.keyWindow } ?? false
                let front = w.map { win in NSApp.orderedWindows.first { $0.isVisible } == win } ?? false
                self.lastReport = (log + ["settingsWindow=\(w != nil)", "key=\(key)", "front=\(front)"]).joined(separator: ", ")
                done?(self.lastReport)
            }
        }
    }

    /// The SwiftUI Settings window (its identifier contains "Settings"), or our fallback.
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.isVisible && (w.identifier?.rawValue.contains("Settings") == true || w.identifier?.rawValue == "arborist-settings"
                            || w.title.contains("Settings"))
        }
    }

    private func showFallback(model: AppModel) -> NSWindow {
        if let f = fallback { return f }
        let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView().environmentObject(model)))
        w.identifier = NSUserInterfaceItemIdentifier("arborist-settings")
        w.title = "Arborist Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        fallback = w
        return w
    }

    private func watchClose(_ w: NSWindow) {
        if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated {
                let others = NSApp.windows.filter { $0 !== w && $0.isVisible && $0.styleMask.contains(.titled) }.count
                if SettingsOpening.shouldBecomeAccessory(otherVisibleWindows: others) { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }
}

/// macOS 14+: hands the SwiftUI openSettings action to SettingsOpener. Invisible.
@available(macOS 14.0, *)
struct SettingsActionBridge: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { let o = openSettings; SettingsOpener.shared.openAction = { o() } }
    }
}

/// D22: the one button style for every popover button: hover and pressed states, a pointing-hand cursor,
/// greyed with no hover when disabled; Reduce Motion: no fade.
struct HoverButtonStyle: ButtonStyle {
    enum Kind { case plain, dark, icon, link }
    var kind: Kind = .plain
    var height: CGFloat? = 22

    func makeBody(configuration: Configuration) -> some View { Body(configuration: configuration, kind: kind, height: height) }

    struct Body: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat?
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        @State private var cursorPushed = false

        var body: some View {
            let hot = enabled && hovering, down = enabled && configuration.isPressed
            configuration.label
                .font(.system(size: kind == .dark ? 12 : 11, weight: kind == .dark ? .medium : .regular))
                .foregroundColor(fg(hot))
                .padding(.horizontal, kind == .icon ? 4 : (kind == .dark ? 14 : (kind == .link ? 4 : 8)))
                .frame(height: kind == .dark ? 28 : height)
                .background(RoundedRectangle(cornerRadius: kind == .dark ? 7 : 6).fill(bg(hot: hot, down: down)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: LeafPalette.cardStroke), lineWidth: kind == .plain ? 0.6 : 0))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: hot)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: down)
                .onHover { inside in
                    hovering = inside
                    setCursor(inside && enabled)
                }
                .onChange(of: enabled) { e in setCursor(e && hovering) }
                .onDisappear { setCursor(false) }
        }

        private func setCursor(_ hand: Bool) {
            if hand && !cursorPushed { NSCursor.pointingHand.push(); cursorPushed = true }
            if !hand && cursorPushed { NSCursor.pop(); cursorPushed = false }
        }

        private func fg(_ hot: Bool) -> Color {
            switch kind {
            case .dark: return Color(hex: LeafPalette.labelOnDark)
            case .plain: return Theme.ink
            case .icon, .link: return hot ? Theme.ink : Theme.ink2
            }
        }

        private func bg(hot: Bool, down: Bool) -> Color {
            switch kind {
            case .dark: return Color(hex: LeafPalette.button).opacity(down ? 0.75 : (hot ? 0.88 : 1))
            case .plain: return down ? Theme.line : (hot ? Theme.line.opacity(0.55) : Color(hex: LeafPalette.background))
            case .icon, .link: return down ? Theme.line : (hot ? Theme.line.opacity(0.6) : .clear)
            }
        }
    }
}
#endif
