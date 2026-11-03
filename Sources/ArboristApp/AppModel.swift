#if os(macOS)
import AppKit
import ArboristCleanup
import ArboristCore
import SwiftUI
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    /// The last finished scan, or the scan in progress built up repo by repo (every repo).
    @Published var scanned: ScanResult?
    /// Repos hidden by the header filter (D18), persisted in UserDefaults by repo path.
    @Published private(set) var filter = VisibleSet.atLaunch().repos
    /// Legend state filter (D21). Session-only: not persisted, so each launch starts with every state.
    @Published private(set) var states = VisibleSet.atLaunch().states
    /// Repo filter AND state filter (D21).
    var visible: VisibleSet { VisibleSet(repos: filter, states: states) }
    /// What the popover shows: `scanned` with both filters applied. Map, counts, Clear and List all use this.
    var result: ScanResult? { scanned.map(visible.apply) }
    /// The repos are selected but the state filter leaves nothing.
    var nothingMatches: Bool { scanned.map { !filter.isEmpty($0.repos) && visible.nothingMatches($0) } ?? false }
    /// True when there are repos but the filter hides all of them.
    var filterHidesEverything: Bool { scanned.map { filter.isEmpty($0.repos) } ?? false }
    @Published var scanning = false
    /// D26: the repo filter menu, an in-popover panel (not a system popover).
    @Published var repoMenuOpen = false
    /// Repos measured so far in the running scan, and how many there are (nil until discovered).
    @Published private(set) var progress: (done: Int, total: Int?)?
    /// Set when `result` came from the on-disk cache and no fresh scan has finished yet.
    @Published private(set) var resultIsCached = false
    /// Last scan failure (timeout); cleared when a scan starts.
    @Published private(set) var scanError: String?
    @Published var freeBytes: Int64?
    @Published var config = ArboristConfig.load()
    @Published var selection: String?   // path of the selected repo/worktree/cache
    /// The worktree list under the popover (List / Hide list), toggled through the action router (D22).
    @Published var showList = false
    private var timer: Timer?
    private var notifiedLow = false
    private var scanID = 0
    private var layoutPending = false

    /// Shared hover state (D15), injected as its own environment object.
    let hover = HoverModel()
    /// True in the `--hover-sweep` test hook: every cleanup entry point refuses to run (D15).
    let cleanupDisabled: Bool

    /// Test hook (DEBUG only): one scan or the cache, no timers, no notifications, cleanup disabled.
    init(sweepWith result: ScanResult) {
        cleanupDisabled = true
        self.scanned = result
        filter = .all
        freeBytes = result.volume?.freeBytes
        relayout()
    }

    /// Changes the filter, persists it and re-lays out the map. The caller animates (or not, for Reduce Motion).
    func setFilter(_ f: RepoFilter) {
        guard f != filter else { return }
        hover.reset()
        filter = f
        if !cleanupDisabled { filter.save() }
        relayout()
    }

    /// Changes the legend state filter (session only) and re-lays out the map. The caller animates.
    func setStates(_ s: StateFilter) {
        guard s != states else { return }
        hover.reset()
        states = s
        relayout()
    }

    /// Repos that left the scan drop out of the exclusions quietly (only once a scan has finished).
    private func pruneFilter() {
        guard let s = scanned else { return }
        let p = filter.pruned(to: s.repos)
        if p != filter { filter = p; if !cleanupDisabled { filter.save() } }
    }

    #if DEBUG
    /// Sweep/snapshot hook only: `--filter name[,name]`, not persisted.
    func applyFilterNames(_ names: [String]) {
        precondition(cleanupDisabled)
        guard let s = scanned else { return }
        setFilter(RepoFilter.only(names: names, among: s.repos))
    }

    /// Sweep/snapshot hook only: `--state ready|uncommitted|clean|stale[,..]`.
    func applyStateList(_ list: String) -> Bool {
        precondition(cleanupDisabled)
        guard let s = StateFilter.parse(list) else { return false }
        setStates(s); return true
    }

    /// Snapshot hook only: show the "cached, scan in progress" state without scanning.
    func simulateCachedScanning(done: Int, total: Int) {
        precondition(cleanupDisabled)
        resultIsCached = true; scanning = true; progress = (done, total)
    }
    #endif

    init() {
        cleanupDisabled = false
        refreshFree()
        // Draw the last scan straight away, marked as cached, then refresh in the background (D11).
        if let cached = ScanCache.load() {
            scanned = cached
            resultIsCached = true
            relayout()
        }
        rescan()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFree() }
        }
    }

    var freeLabel: String { freeBytes.map(Format.bytes) ?? "—" }
    var stage: LeafStage { config.stage(freeBytes: freeBytes ?? Int64.max) }

    /// e.g. "12/34 repos", or "Finding repos…" before discovery finishes.
    var progressLabel: String? {
        guard scanning, let p = progress else { return nil }
        guard let total = p.total else { return "Finding repos…" }
        return "\(p.done)/\(total) repos"
    }

    /// Leaf map for the popover, rebuilt as repos arrive (coalesced) and when a scan finishes.
    @Published private(set) var leafMap: LeafMap?

    // MARK: Cleanup (D14). Only reachable from a click in this UI, and always through the confirm sheet.

    /// Worktrees "Clear N" would remove or prune: merged or upstream gone, and nothing uncommitted, unpushed or locked.
    var clearPlan: [CleanupItem] { cleanupDisabled ? [] : (scanned.map { Cleanup.plan($0, visible: visible) } ?? []) }
    /// Set to show the confirm sheet. Nothing runs until the sheet's Remove button is clicked.
    @Published var pendingCleanup: [CleanupItem]?
    /// What happened in the last run, shown until dismissed.
    @Published var cleanupResults: [CleanupOutcome]?
    @Published private(set) var cleaning = false

    func requestClear() {
        guard !cleanupDisabled else { assertionFailure("cleanup is disabled in this mode"); return }
        let plan = clearPlan
        if !plan.isEmpty { pendingCleanup = plan }
    }
    func requestRemove(_ ref: WorktreeRef) {
        guard !cleanupDisabled else { assertionFailure("cleanup is disabled in this mode"); return }
        if let item = Cleanup.item(ref) { pendingCleanup = [item] }
    }
    /// Called only by the confirm sheet. Each item is re-checked inside `Cleanup.execute` just before it runs.
    func confirmCleanup(_ items: [CleanupItem]) {
        pendingCleanup = nil
        precondition(!cleanupDisabled, "cleanup is disabled in this mode")
        guard !cleaning, !items.isEmpty else { return }
        cleaning = true
        Task.detached(priority: .userInitiated) {
            var outcomes: [CleanupOutcome] = []
            for item in items { outcomes.append(Cleanup.execute(item)) }
            CleanupLog.append(outcomes)
            let done = outcomes
            await MainActor.run {
                self.cleanupResults = done
                self.cleaning = false
                self.refreshFree()
                self.rescan()
            }
        }
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        scanError = nil
        progress = (0, nil)
        scanID += 1
        let id = scanID
        let cfg = config
        let previous = scanned
        var partial: [Repo] = []
        Task {
            // Events arrive here on the main actor, in order; a newer scan makes older events no-ops.
            let stream = Scanner(config: cfg).events(timeout: cfg.scanTimeoutSeconds)
            for await event in stream {
                guard id == self.scanID else { return }
                switch event {
                case .volume(let v):
                    if let v { self.freeBytes = v.freeBytes; self.checkLowSpace() }
                case .discovered(let n):
                    self.progress = (0, n)
                case .repo(let repo, let done, let total):
                    partial.append(repo)
                    self.progress = (done, total)
                    // Fresh repos replace their cached versions; the rest of the last scan stays
                    // on screen until this one finishes, so the map fills in rather than resetting.
                    let fresh = Set(partial.map(\.path))
                    let kept = (previous?.repos ?? []).filter { !fresh.contains($0.path) }
                    var r = ScanResult(scannedAt: previous?.scannedAt ?? Date(), roots: cfg.expandedRoots,
                                       volume: previous?.volume ?? DiskUsage.volume(for: ArboristConfig.home),
                                       repos: (partial + kept).sorted { $0.size.total > $1.size.total },
                                       caches: previous?.caches ?? [], skippedPaths: 0)
                    if let v = self.freeBytes, var vol = r.volume { vol.freeBytes = v; r.volume = vol }
                    self.scanned = r
                    self.scheduleRelayout()
                case .caches:
                    break
                case .finished(let r):
                    self.scanned = r
                    self.pruneFilter()
                    self.resultIsCached = false
                    self.freeBytes = r.volume?.freeBytes ?? self.freeBytes
                    self.relayout()
                    self.checkLowSpace()
                    let toSave = r
                    // Hook mode (cleanup disabled) never writes the user's cache.
                    if !self.cleanupDisabled { Task.detached(priority: .utility) { try? ScanCache.save(toSave) } }
                case .failed(let message):
                    self.scanError = message
                }
            }
            if id == self.scanID { self.scanning = false; self.progress = nil }
        }
    }

    private func relayout() {
        guard let r = result else { leafMap = nil; return }
        leafMap = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }

    /// Rebuilds the leaf map at most every 0.4 s while repos stream in.
    private func scheduleRelayout() {
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutPending = false
                self.relayout()
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
        guard let free = freeBytes, !cleanupDisabled else { return } // hook mode: no notifications
        let threshold = Int64(config.lowSpaceThresholdGB * 1_000_000_000)
        if free >= threshold { notifiedLow = false; return }
        guard !notifiedLow else { return }
        notifiedLow = true
        // UNUserNotificationCenter needs a real app bundle; under `swift run` there is none.
        guard Bundle.main.bundleIdentifier != nil else { NSSound.beep(); return }
        // Build everything on the main actor, then hand only Sendable values to the callback,
        // which runs on a background queue (D11: fixes the Sendable warnings here).
        let body = "\(Format.bytes(free)) free, below your \(Int(config.lowSpaceThresholdGB)) GB threshold."
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Low disk space"
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "arborist.lowspace", content: c, trigger: nil))
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
