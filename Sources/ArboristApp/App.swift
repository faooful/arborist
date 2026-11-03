#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

@main
struct ArboristApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Menu bar only: no main window (D7).
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Text(model.freeLabel)
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
