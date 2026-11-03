#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

/// Entry point. Normally starts the menu bar app. In DEBUG builds, `--hover-sweep DIR` together with
/// `ARBORIST_HOVER_SWEEP=1` runs the hover test hook instead and exits, without creating the menu bar item (D15).
@main
enum Entry {
    static func main() {
        #if DEBUG
        if let dir = HoverSweepRunner.requestedDirectory() {
            MainActor.assumeIsolated { HoverSweepRunner.run(into: dir) }
            exit(0)
        }
        #endif
        ArboristApp.main()
    }
}

struct ArboristApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Menu bar only: no main window (D7).
        MenuBarExtra {
            PopoverView().environmentObject(model).environmentObject(model.hover)
        } label: {
            // Wilting leaf (D10) plus optional free-space text.
            HStack(spacing: 3) {
                Image(nsImage: LeafIcon.image(model.stage))
                if model.config.showFreeText { Text(model.freeLabel) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LeafStage.accessibilityLabel(model.stage, freeBytes: model.freeBytes ?? 0))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
#else
// The app is macOS-only. On Linux this target builds a stub so `swift build` covers the rest.
@main
enum ArboristAppStub {
    static func main() { print("ArboristApp runs on macOS only. Use the `arborist` CLI here.") }
}
#endif
