import Foundation
import XCTest
@testable import ArboristCore

/// Collects events from worker threads.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScanEvent] = []
    func add(_ e: ScanEvent) { lock.lock(); items.append(e); lock.unlock() }
    var all: [ScanEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

final class ScanProgressTests: XCTestCase {
    private func makeRepos(_ n: Int) throws -> String {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("arborist-prog-\(UUID().uuidString)").path
        for i in 0..<n {
            let repo = base + "/r\(i)"
            try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
            func g(_ a: String...) { _ = Shell.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a) }
            g("init", "-q", "-b", "main")
            try "x".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
            g("add", "."); g("commit", "-qm", "one")
            if i == 0 { g("worktree", "add", "-q", "-b", "side", base + "/r0-side") }
        }
        return base
    }

    func testProgressEventsArriveInOrderAndMatchResult() throws {
        guard Shell.run(["git", "--version"]) != nil else { throw XCTSkip("git not installed") }
        let base = try makeRepos(3)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let log = EventLog()
        let r = Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3))
            .scan(cancel: nil) { log.add($0) }
        let ev = log.all
        guard case .volume = ev.first else { return XCTFail("volume must come first: \(ev)") }
        guard case .discovered(let n) = ev[1] else { return XCTFail("then discovered") }
        XCTAssertEqual(n, 3)
        let repoEvents = ev.compactMap { e -> (Repo, Int, Int)? in if case let .repo(r, d, t) = e { return (r, d, t) }; return nil }
        XCTAssertEqual(repoEvents.map(\.1), [1, 2, 3], "done count climbs one per repo")
        XCTAssertTrue(repoEvents.allSatisfy { $0.2 == 3 })
        XCTAssertEqual(Set(repoEvents.map(\.0.path)), Set(r.repos.map(\.path)))
        let r0 = try XCTUnwrap(repoEvents.first { $0.0.name == "r0" }?.0)
        XCTAssertEqual(r0.worktrees.count, 2, "a repo is published only with all its worktrees")
        XCTAssertTrue(r0.worktrees[0].isMain)
        guard case .caches = ev[ev.count - 2], case .finished(let fin) = ev.last else { return XCTFail("caches then finished") }
        XCTAssertEqual(fin, r)
    }

    func testEventStreamFinishes() async throws {
        guard Shell.run(["git", "--version"]) != nil else { throw XCTSkip("git not installed") }
        let base = try makeRepos(2)
        defer { try? FileManager.default.removeItem(atPath: base) }
        var repos = 0, finished = false
        for await e in Scanner(config: ArboristConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3)).events(timeout: 60) {
            if case .repo = e { repos += 1 }
            if case .finished = e { finished = true }
        }
        XCTAssertEqual(repos, 2)
        XCTAssertTrue(finished)
    }

    func testDeadlineTimesOutAndCancelsWork() async throws {
        let started = Date()
        let stopped = EventLog()
        do {
            _ = try await Deadline.run(timeout: 0.2) { cancel -> Int in
                while !cancel.isCancelled { Thread.sleep(forTimeInterval: 0.01) }  // a stuck scan
                stopped.add(.failed("stopped"))
                return 1
            }
            XCTFail("should time out")
        } catch let e as ScanError {
            XCTAssertEqual(e, .timedOut(seconds: 0))
            XCTAssertEqual(e.errorDescription, "Scan didn't finish within 0 s.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stopped.all.count, 1, "the worker saw the cancel flag and stopped")
    }

    func testDeadlinePassesThroughResultsAndErrors() async throws {
        let v = try await Deadline.run(timeout: 5) { _ in 42 }
        XCTAssertEqual(v, 42)
        struct Boom: Error {}
        do { _ = try await Deadline.run(timeout: 5) { _ -> Int in throw Boom() }; XCTFail("should throw") }
        catch { XCTAssertTrue(error is Boom) }
    }

    func testScanTimeoutConfigDefaultsTo180() throws {
        XCTAssertEqual(ArboristConfig.defaults.scanTimeoutSeconds, 180)
        let c = try JSONDecoder().decode(ArboristConfig.self, from: Data(#"{"scanTimeoutSeconds": 30}"#.utf8))
        XCTAssertEqual(c.scanTimeoutSeconds, 30)
        XCTAssertEqual(c.maxDepth, ArboristConfig.defaults.maxDepth)
    }

    func testCacheRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arborist-cache-\(UUID().uuidString)/last-scan.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(ScanCache.load(from: url))
        let wt = Worktree(path: "/r/a", isMain: true, branch: "main", head: "abc", lastCommitDate: Date(timeIntervalSince1970: 1_700_000_000),
                          dirty: true, unpushedCommits: 2, hasUpstream: true, stale: false, staleReasons: [],
                          size: SizeSplit(rebuildable: 10, source: 20), removeCommand: nil)
        let r = ScanResult(scannedAt: Date(timeIntervalSince1970: 1_700_000_100), roots: ["/r"],
                           volume: VolumeInfo(path: "/", freeBytes: 10, totalBytes: 20),
                           repos: [Repo(name: "a", path: "/r/a", defaultBranch: "main", worktrees: [wt])],
                           caches: [CacheEntry(name: "npm", path: "/n", bytes: 5)], skippedPaths: 1)
        try ScanCache.save(r, to: url)
        XCTAssertEqual(ScanCache.load(from: url), r)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(ScanCache.load(from: url), "a bad cache is ignored, not fatal")
    }
}

final class TreeSizeTests: XCTestCase {
    /// Bytes for one file as the old code read them. On Linux, swift-corelibs reports allocated size
    /// as st_blocks × st_blksize (8× too big), so the reference uses lstat's st_blocks × 512 there;
    /// the walk itself is the old one unchanged.
    private func bytes(_ u: URL, _ v: URLResourceValues) -> Int64 {
        #if os(macOS)
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
        #else
        var st = stat(); lstat(u.path, &st); return Int64(st.st_blocks) * 512
        #endif
    }

    /// The pre-D11 algorithm (FileManager enumerator + per-file resource values), kept as the reference.
    private func oldTreeSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var total: Int64 = 0
        let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)!
        while let u = en.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true || v.isDirectory == true { continue }
            total += bytes(u, v)
        }
        return total
    }
    private func oldMeasure(_ root: URL) -> SizeSplit {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        var s = SizeSplit()
        let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)!
        while let u = en.nextObject() as? URL {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if DiskUsage.isRebuildable(u.lastPathComponent) { en.skipDescendants(); s.rebuildable += oldTreeSize(u) }
                else if u.lastPathComponent != ".git", FileManager.default.fileExists(atPath: u.appendingPathComponent(".git").path) { en.skipDescendants() }
                continue
            }
            s.source += bytes(u, v)
        }
        return s
    }

    func testMatchesOldTotalsOnFixtureTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("arborist-tree-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ rel: String, _ bytes: Int) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: u)
        }
        try write("src/main.swift", 50_000)
        try write("src/deep/a/b/c/d.txt", 3)
        try write(".hidden/file", 9_000)
        try write(".git/objects/pack/p", 70_000)
        try write("node_modules/pkg/index.js", 200_000)
        try write("node_modules/pkg/node_modules/inner/x.js", 33_000)   // nested rebuildable, counted once
        try write(".build/debug/obj.o", 120_000)
        try write("web/.next/cache/x", 100_000)
        try write("nested/.git/HEAD", 10)
        try write("nested/big.bin", 900_000)
        try write("empty.txt", 0)
        try fm.createDirectory(at: root.appendingPathComponent("emptydir"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link-to-big").path, withDestinationPath: root.appendingPathComponent("nested/big.bin").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("node_modules/loop").path, withDestinationPath: root.path)

        var skipped = 0
        XCTAssertEqual(DiskUsage.treeSize(root, skipped: &skipped), oldTreeSize(root))
        let new = DiskUsage.measureWorktree(root.path, skipped: &skipped)
        XCTAssertEqual(new, oldMeasure(root))
        XCTAssertEqual(skipped, 0)
        // The nested repo's 900 KB is left out: it equals the tree minus the nested folder.
        try fm.removeItem(at: root.appendingPathComponent("nested"))
        XCTAssertEqual(DiskUsage.measureWorktree(root.path, skipped: &skipped), new)
        #if !os(macOS)
        // And it agrees with du.
        let du = Shell.run(["du", "-s", "-B1", root.path]).flatMap { Int64($0.split(separator: "\t").first ?? "") }
        if let du { XCTAssertLessThanOrEqual(new.total, du) }
        #endif
    }

    func testCancelStopsTheWalk() throws {
        var skipped = 0
        let flag = CancelFlag(); flag.cancel()
        XCTAssertEqual(DiskUsage.treeSize(URL(fileURLWithPath: NSTemporaryDirectory()), skipped: &skipped, cancel: flag), 0)
    }
}
