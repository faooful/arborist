import Foundation

public enum DiskUsage {
    /// Directory names whose contents tools can regenerate.
    public static let rebuildableNames: Set<String> = [
        "node_modules", ".next", "dist", "target", ".venv", "DerivedData", ".build",
    ]

    public static func isRebuildable(_ name: String) -> Bool { rebuildableNames.contains(name) }

    /// Size of a worktree split into rebuildable and source, in one walk.
    /// Every directory is listed once: a rebuildable folder (node_modules, .build, …) is summed as it is
    /// walked, and nested rebuildable folders inside it are not walked again. Nested git repos/worktrees
    /// (a directory holding its own `.git`) are skipped so they aren't counted twice. Unreadable paths
    /// are skipped and counted in `skipped`. Returns early, partially counted, when `cancel` is set.
    public static func measureWorktree(_ root: String, skipped: inout Int, cancel: CancelFlag? = nil) -> SizeSplit {
        var split = SizeSplit()
        guard let top = DirLister.list(root) else { skipped += 1; return split }
        func walk(_ dir: String, _ entries: [DirEntry], rebuildable: Bool) {
            if cancel?.isCancelled == true { return }
            for e in entries {
                switch e.kind {
                case .symlink, .other: continue
                case .file:
                    if rebuildable { split.rebuildable += e.allocated } else { split.source += e.allocated }
                case .dir:
                    let child = dir + "/" + e.name
                    guard let sub = DirLister.list(child) else { skipped += 1; continue }
                    if rebuildable { walk(child, sub, rebuildable: true); continue }
                    if isRebuildable(e.name) { walk(child, sub, rebuildable: true); continue }
                    // Nested repo or worktree: measured on its own. `.git` itself is source.
                    if e.name != ".git", sub.contains(where: { $0.name == ".git" }) { continue }
                    walk(child, sub, rebuildable: false)
                }
            }
        }
        walk(root, top, rebuildable: false)
        return split
    }

    /// Total allocated bytes of a directory tree, not following symlinks, in one walk.
    public static func treeSize(_ url: URL, skipped: inout Int, cancel: CancelFlag? = nil) -> Int64 {
        var total: Int64 = 0
        func walk(_ dir: String) {
            if cancel?.isCancelled == true { return }
            guard let entries = DirLister.list(dir) else { skipped += 1; return }
            for e in entries {
                switch e.kind {
                case .file: total += e.allocated
                case .dir: walk(dir + "/" + e.name)
                case .symlink, .other: continue
                }
            }
        }
        walk(url.path)
        return total
    }

    /// Free and total space of the volume holding `path`.
    public static func volume(for path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        #if os(macOS)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
           let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity {
            return VolumeInfo(path: path, freeBytes: free, totalBytes: Int64(total))
        }
        #endif
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = (a[.systemFreeSize] as? NSNumber)?.int64Value,
              let total = (a[.systemSize] as? NSNumber)?.int64Value else { return nil }
        return VolumeInfo(path: path, freeBytes: free, totalBytes: total)
    }
}
