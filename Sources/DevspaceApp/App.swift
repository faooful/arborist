#if os(macOS)
import AppKit
import DevspaceCore
import SwiftUI

@main
struct DevspaceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("devspace", id: "main") {
            MainView().environmentObject(model)
                .frame(minWidth: 720, minHeight: 640)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Text(model.freeLabel)
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(model.freeLabel) free")
        if let r = model.result { Text(Format.summarySentence(r)) }
        Divider()
        Button("Open devspace") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(model.scanning ? "Scanning…" : "Rescan") { model.rescan() }.disabled(model.scanning)
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
#else
// The app is macOS-only. On Linux this target builds a stub so `swift build` covers the rest.
@main
enum DevspaceAppStub {
    static func main() { print("DevspaceApp runs on macOS only. Use the `devspace` CLI here.") }
}
#endif
