#if os(macOS)
import AppKit
import ArboristCore
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var result: ScanResult?
    @Published var scanning = false
    @Published var freeBytes: Int64?
    @Published var config = ArboristConfig.load()
    @Published var selection: String?   // path of the selected repo/worktree/cache
    private var timer: Timer?
    private var notifiedLow = false

    init() {
        refreshFree()
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFree() }
        }
    }

    var freeLabel: String { freeBytes.map(Format.bytes) ?? "—" }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let cfg = config
        Task.detached(priority: .utility) {
            let r = Scanner(config: cfg).scan()
            await MainActor.run {
                self.result = r
                self.scanning = false
                self.freeBytes = r.volume?.freeBytes ?? self.freeBytes
                self.checkLowSpace()
            }
        }
    }

    func refreshFree() {
        freeBytes = DiskUsage.volume(for: ArboristConfig.home)?.freeBytes
        checkLowSpace()
    }

    func saveConfig() {
        try? config.save()
        checkLowSpace()
    }

    /// Notifies once each time free space drops below the threshold.
    private func checkLowSpace() {
        guard let free = freeBytes else { return }
        let threshold = Int64(config.lowSpaceThresholdGB * 1_000_000_000)
        if free >= threshold { notifiedLow = false; return }
        guard !notifiedLow else { return }
        notifiedLow = true
        // UNUserNotificationCenter needs a real app bundle; under `swift run` there is none.
        guard Bundle.main.bundleIdentifier != nil else { NSSound.beep(); return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Low disk space"
            c.body = "\(Format.bytes(free)) free, below your \(Int(self.config.lowSpaceThresholdGB)) GB threshold."
            center.add(UNNotificationRequest(identifier: "arborist.lowspace", content: c, trigger: nil))
        }
    }

    // Read-only actions.
    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
