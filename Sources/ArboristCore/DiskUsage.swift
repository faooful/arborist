import Foundation

public enum DiskUsage {
    /// Directory names whose contents tools can regenerate.
    public static let rebuildableNames: Set<String> = [
        "node_modules", ".next", "dist", "target", ".venv", "DerivedData", ".build",
    ]

    public static func isRebuildable(_ name: String) -> Bool { rebuildableNames.contains(name) }

    /// Size of a worktree split into rebuildable and source. Nested git repos/worktrees
    /// (a directory holding its own `.git`) are skipped so they aren't counted twice.
    /// Unreadable paths are skipped and counted in `skipped`.
    public static func measureWorktree(_ root: String, skipped: inout Int) -> SizeSplit {
        var split = SizeSplit()
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var localSkipped = 0
        guard let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [],
                                     errorHandler: { _, _ in localSkipped += 1; return true }) else {
            skipped += 1
            return split
        }
        while let url = en.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { localSkipped += 1; continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                let name = url.lastPathComponent
                if isRebuildable(name) {
                    en.skipDescendants()
                    split.rebuildable += treeSize(url, skipped: &localSkipped)
                } else if name != ".git", fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    en.skipDescendants() // nested repo or worktree, measured on its own
                }
                continue
            }
            split.source += fileBytes(v)
        }
        skipped += localSkipped
        return split
    }

    /// Total allocated bytes of a directory tree, not following symlinks.
    public static func treeSize(_ url: URL, skipped: inout Int) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var total: Int64 = 0
        var localSkipped = 0
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                      errorHandler: { _, _ in localSkipped += 1; return true }) else { return 0 }
        while let u = en.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { localSkipped += 1; continue }
            if v.isSymbolicLink == true || v.isDirectory == true { continue }
            total += fileBytes(v)
        }
        skipped += localSkipped
        return total
    }

    static func fileBytes(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
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
