import Foundation

public enum Format {
    /// Decimal units, like Finder: 1 GB = 1,000,000,000 bytes.
    public static func bytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b), i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return "\(b) B" }
        return v >= 100 ? String(format: "%.0f %@", v, units[i]) : String(format: "%.1f %@", v, units[i])
    }

    /// One plain sentence describing the scan, used by the CLI and the app.
    public static func summarySentence(_ r: ScanResult) -> String {
        let t = r.totals
        let wt = r.repos.reduce(0) { $0 + $1.worktrees.count }
        var s = "\(r.repos.count) repos and \(wt) worktrees use \(bytes(t.projectsSource + t.projectsRebuildable)), of which \(bytes(t.projectsRebuildable)) is rebuildable; caches hold \(bytes(t.caches))"
        if t.staleWorktrees > 0 { s += ", and \(t.staleWorktrees) worktree\(t.staleWorktrees == 1 ? " looks" : "s look") stale" }
        return s + "."
    }

    public static func humanReport(_ r: ScanResult) -> String {
        var out: [String] = []
        if let v = r.volume { out.append("\(bytes(v.freeBytes)) free of \(bytes(v.totalBytes))") }
        out.append(summarySentence(r))
        out.append("")
        for repo in r.repos {
            out.append("\(pad(bytes(repo.size.total), 9))  \(repo.name)  (\(bytes(repo.size.rebuildable)) rebuildable)  \(repo.path)")
            for w in repo.worktrees {
                var flags: [String] = []
                if w.dirty { flags.append("dirty") }
                if let n = w.unpushedCommits, n > 0 { flags.append("\(n) unpushed") }
                if w.stale { flags.append("stale: " + w.staleReasons.map(\.rawValue).joined(separator: ",")) }
                let br = w.branch ?? "(detached)"
                out.append("  \(pad(bytes(w.size.total), 9))  \(br)\(w.isMain ? " [main]" : "")  \(flags.joined(separator: " · "))  \(w.path)")
            }
        }
        if !r.caches.isEmpty {
            out.append("")
            out.append("Shared caches")
            for c in r.caches { out.append("\(pad(bytes(c.bytes), 9))  \(c.name)") }
        }
        if r.skippedPaths > 0 { out.append("\n(\(r.skippedPaths) unreadable paths skipped)") }
        return out.joined(separator: "\n")
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
}
