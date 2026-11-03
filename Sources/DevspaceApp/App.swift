#if os(macOS)
import AppKit
import DevspaceCore
import SwiftUI

@main
struct DevspaceApp: App {
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
enum DevspaceAppStub {
    static func main() { print("DevspaceApp runs on macOS only. Use the `devspace` CLI here.") }
}
#endif
