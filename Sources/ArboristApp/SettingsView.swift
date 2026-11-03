#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Scan folders") {
                ForEach(model.config.roots, id: \.self) { root in
                    HStack {
                        Text(root).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove") {
                            model.config.roots.removeAll { $0 == root }
                            model.saveConfig()
                        }.disabled(model.config.roots.count <= 1)
                    }
                }
                Button("Add folder…") { addFolder() }
                Stepper("Search depth: \(model.config.maxDepth)", value: $model.config.maxDepth, in: 1...8)
                    .onChange(of: model.config.maxDepth) { _ in model.saveConfig() }
            }
            Section("Low space alert") {
                Stepper("Notify below \(Int(model.config.lowSpaceThresholdGB)) GB free",
                        value: $model.config.lowSpaceThresholdGB, in: 1...500, step: 5)
                    .onChange(of: model.config.lowSpaceThresholdGB) { _ in model.saveConfig() }
            }
            Text("Shared with the arborist CLI: \(ArboristConfig.fileURL.path)")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var p = url.path
        if p.hasPrefix(ArboristConfig.home) { p = "~" + p.dropFirst(ArboristConfig.home.count) }
        if !model.config.roots.contains(p) { model.config.roots.append(p); model.saveConfig() }
    }
}
#endif
