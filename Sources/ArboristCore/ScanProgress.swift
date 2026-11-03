import Foundation

/// What a running scan reports, in order (D11).
public enum ScanEvent: Sendable {
    case volume(VolumeInfo?)
    case discovered(repos: Int)
    case repo(Repo, done: Int, total: Int)
    case caches([CacheEntry])
    case finished(ScanResult)
    case failed(String)
}

public enum ScanError: Error, Equatable, LocalizedError {
    case timedOut(seconds: Int)
    public var errorDescription: String? {
        switch self { case .timedOut(let s): return "Scan didn't finish within \(s) s." }
    }
    static func describe(_ e: Error) -> String { (e as? LocalizedError)?.errorDescription ?? "\(e)" }
}

/// Runs blocking work on its own thread with a deadline. Whichever comes first, the work's result
/// or the deadline, resumes the caller; on timeout the work's CancelFlag is set so it can stop.
/// The caller never waits for a stuck worker.
public enum Deadline {
    public static func run<T: Sendable>(timeout: TimeInterval,
                                        _ work: @escaping @Sendable (CancelFlag) throws -> T) async throws -> T {
        let cancel = CancelFlag()
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            Thread.detachNewThread {
                let r = Result { try work(cancel) }
                if once.claim() { cont.resume(with: r) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard once.claim() else { return }
                cancel.cancel()
                cont.resume(throwing: ScanError.timedOut(seconds: Int(timeout.rounded())))
            }
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Last scan on disk, so the app can draw something immediately on launch (D11).
/// macOS: ~/Library/Caches/arborist/last-scan.json; elsewhere $XDG_CACHE_HOME or ~/.cache/arborist.
public enum ScanCache {
    public static var defaultURL: URL {
        let home = URL(fileURLWithPath: ArboristConfig.home)
        #if os(macOS)
        let dir = home.appendingPathComponent("Library/Caches/arborist")
        #else
        let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = (xdg.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".cache")).appendingPathComponent("arborist")
        #endif
        return dir.appendingPathComponent("last-scan.json")
    }

    public static func save(_ r: ScanResult, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try r.jsonData().write(to: url, options: .atomic)
    }

    /// nil when there is no cache or it can't be read (e.g. an older format).
    public static func load(from url: URL = defaultURL) -> ScanResult? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? ScanResult.decode(d)
    }
}
