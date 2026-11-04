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

    /// D28: removed worktrees awaiting the confirming `git worktree list`, and ones that reappeared.
    @Published private(set) var pendingRemovals: [PendingRemoval] = []
    @Published private(set) var reappeared: [String] = []
    /// D28: the removed leaves as they were drawn, fading out over 0.2 s above the re-laid-out map.
    /// Drawing only: the model (map, counts, hit-testing) has already dropped them.
    @Published private(set) var exitGhost: ExitGhost?
    /// D28: the last confirming re-list finished (for the trial check).
    @Published private(set) var removalsConfirmed = 0
    /// False in hook modes: never write the user's scan cache.
    private var writesCache = true

    /// Test hook (DEBUG only): one scan or the cache, no timers, no notifications, cleanup disabled
    /// (`allowCleanup` only for `--remove-trial`, which removes a throwaway worktree it created itself).
    init(sweepWith result: ScanResult, allowCleanup: Bool = false) {
        cleanupDisabled = !allowCleanup
        writesCache = false
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
    @Published var pendingCleanup: [CleanupItem]? {
        didSet { hover.blocked = pendingCleanup != nil; if pendingCleanup != nil { repoMenuOpen = false } }
    }
    /// D27 test hook (`--confirm-check`): records a confirmed batch instead of running it (cleanup disabled).
    var confirmHook: (([CleanupItem]) -> Void)?
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
        if let h = confirmHook { h(items); return }
        precondition(!cleanupDisabled, "cleanup is disabled in this mode")
        guard !cleaning, !items.isEmpty else { return }
        cleaning = true
        let logs = writesCache // hook modes never touch the user's cleanup log
        Task.detached(priority: .userInitiated) {
            var outcomes: [CleanupOutcome] = []
            for item in items { outcomes.append(Cleanup.execute(item)) }
            if logs { CleanupLog.append(outcomes) }
            let done = outcomes
            await MainActor.run {
                self.cleanupResults = done
                self.cleaning = false
                self.applyRemovals(done)
                self.refreshFree()
            }
        }
    }

    /// D28: drop every succeeded item from the model at once (failed/skipped stay, their reasons in the
    /// results), clear a hover/pin/selection on it, save the cache, then confirm with a background
    /// `git worktree list` of only the affected repos.
    func applyRemovals(_ outcomes: [CleanupOutcome]) {
        guard let s = scanned else { return }
        let paths = outcomes.filter(\.succeeded).map(\.item.path)
        guard !paths.isEmpty else { return }
        let (next, dropped) = OptimisticRemoval.apply(s, removed: paths)
        let v = hover.visible
        if [v.pinned, v.hovered, v.strip].contains(where: { OptimisticRemoval.clears($0, removed: dropped) }) { hover.reset() }
        if OptimisticRemoval.clears(selection, removed: dropped) { selection = nil }
        // D29: the removed leaves blow away (0.7 s; a plain 0.2 s fade with Reduce Motion). Drawing only:
        // the model, map and hit layer drop them right now.
        if !hover.instant, let old = leafMap {
            let fade = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let g = ExitGhost(map: old, ids: Set(old.leaves.map(\.item.id).filter { OptimisticRemoval.clears($0, removed: dropped) }),
                              transform: hover.transform, start: HoverModel.now(), fade: fade)
            showGhost(g)
        }
        scanned = next
        relayout()
        pendingRemovals += dropped
        saveCache(next)
        let repos = OptimisticRemoval.repos(dropped)
        Task.detached(priority: .utility) {
            var listed: [String: [String]?] = [:]
            for r in repos { listed[r] = OptimisticRemoval.list(r) }
            let lists = listed
            await MainActor.run { self.confirmRemovals(dropped, listed: lists) }
        }
    }

    private func confirmRemovals(_ dropped: [PendingRemoval], listed: [String: [String]?]) {
        let ids = Set(dropped.map(\.path))
        pendingRemovals.removeAll { ids.contains($0.path) }
        guard let s = scanned else { return }
        let c = OptimisticRemoval.confirm(s, pending: dropped, listed: listed)
        if !c.restored.isEmpty {
            reappeared += c.restored
            scanned = c.result
            relayout()
            saveCache(c.result)
        }
        removalsConfirmed += 1
    }

    func clearReappeared() { reappeared = [] }

    /// D29 DEBUG capture: pin the ghost at a progress (nil = clear it).
    func setGhost(_ g: ExitGhost?) { exitGhost = g }

    /// D29: shows an exit ghost and drops it once its animation is done.
    func showGhost(_ g: ExitGhost) {
        exitGhost = g
        DispatchQueue.main.asyncAfter(deadline: .now() + g.duration + 0.05) { [weak self] in
            MainActor.assumeIsolated { if self?.exitGhost?.id == g.id, self?.exitGhost?.fixedProgress == nil { self?.exitGhost = nil } }
        }
    }

    private func saveCache(_ r: ScanResult) {
        guard writesCache, !cleanupDisabled else { return }
        Task.detached(priority: .utility) { try? ScanCache.save(r) }
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
                    self.saveCache(toSave)
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
/// D28: removed leaves drawn where they were, fading out (cosmetic; never hit-testable).
struct ExitGhost: Identifiable {
    let id = UUID()
    let map: LeafMap
    let ids: Set<String>
    let transform: MapTransform
    /// Wall-clock start (HoverModel.now()) and Reduce Motion (plain fade).
    let start: Double
    let fade: Bool
    /// DEBUG capture: draw at this progress (0…1) instead of the clock.
    var fixedProgress: Double? = nil
    var duration: Double { fade ? BlowAway.fadeDuration : BlowAway.duration }
}

#endif
