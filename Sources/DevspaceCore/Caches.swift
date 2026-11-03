import Foundation

public enum Caches {
    /// Well-known shared dev caches, relative to the home folder. Only existing ones are reported.
    public static let candidates: [(String, [String])] = [
        ("npm", [".npm"]),
        ("pnpm", ["Library/pnpm/store", "Library/Caches/pnpm", ".local/share/pnpm/store", ".pnpm-store"]),
        ("Yarn", ["Library/Caches/Yarn"]),
        ("Homebrew", ["Library/Caches/Homebrew"]),
        ("Xcode DerivedData", ["Library/Developer/Xcode/DerivedData"]),
    ]

    public static func scan(home: String, skipped: inout Int) -> [CacheEntry] {
        var out: [CacheEntry] = []
        let fm = FileManager.default
        for (name, rels) in candidates {
            var total: Int64 = 0
            var paths: [String] = []
            for rel in rels {
                let p = home + "/" + rel
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                total += DiskUsage.treeSize(URL(fileURLWithPath: p), skipped: &skipped)
                paths.append(p)
            }
            if !paths.isEmpty { out.append(CacheEntry(name: name, path: paths.first, bytes: total)) }
        }
        if let docker = dockerBytes() { out.append(CacheEntry(name: "Docker", path: nil, bytes: docker)) }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Asks the Docker CLI (if installed and the daemon is running) rather than reading
    /// Docker's container folder, which would trigger a macOS privacy prompt.
    static func dockerBytes() -> Int64? {
        guard let out = Shell.run(["docker", "system", "df", "--format", "{{.Size}}"], timeout: 8) else { return nil }
        let sizes = out.split(separator: "\n").compactMap { parseDockerSize(String($0)) }
        return sizes.isEmpty ? nil : sizes.reduce(0, +)
    }

    /// Parses Docker's human sizes like "1.2GB", "512MB", "0B", "3.4kB".
    public static func parseDockerSize(_ s: String) -> Int64? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) {
            guard let n = Double(t.dropLast(u.count)) else { return nil }
            return Int64(n * m)
        }
        return nil
    }
}
