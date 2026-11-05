import XCTest
@testable import ArboristCore

/// D34: scan timeout default, migration, adaptive value, partial results and child-process cancel.
final class ScanTimeoutTests: XCTestCase, @unchecked Sendable {
    private func decode(_ json: String) throws -> ArboristConfig {
        try JSONDecoder().decode(ArboristConfig.self, from: Data(json.utf8))
    }

    func testOldDefaultMigratesCustomKeptIdempotent() throws {
        XCTAssertEqual(try decode(#"{"scanTimeoutSeconds": 180}"#).scanTimeoutSeconds, 600)
        XCTAssertEqual(try decode(#"{"scanTimeoutSeconds": 240}"#).scanTimeoutSeconds, 240)
        XCTAssertEqual(try decode(#"{"scanTimeoutSeconds": 60}"#).scanTimeoutSeconds, 60)
        XCTAssertEqual(try decode("{}").scanTimeoutSeconds, 600)
        // Save and reload: stays 600.
        let once = try decode(#"{"scanTimeoutSeconds": 180}"#)
        let again = try JSONDecoder().decode(ArboristConfig.self, from: JSONEncoder().encode(once))
        XCTAssertEqual(again, once)
    }

    func testAdaptiveTimeout() {
        XCTAssertEqual(ScanTimeout.effective(configured: 600, lastFullDuration: nil), 600)
        XCTAssertEqual(ScanTimeout.effective(configured: 600, lastFullDuration: 100), 600)
        XCTAssertEqual(ScanTimeout.effective(configured: 600, lastFullDuration: 355), 710)
        XCTAssertEqual(ScanTimeout.effective(configured: 600, lastFullDuration: 5000), 1800)
        XCTAssertEqual(ScanTimeout.effective(configured: 3600, lastFullDuration: 5000), 3600, "custom above cap kept")
        XCTAssertEqual(ScanTimeout.effective(configured: 60, lastFullDuration: 0), 60)
    }

    private func repo(_ name: String, _ bytes: Int64) -> Repo {
        var w = Worktree(path: "/r/\(name)", isMain: true, branch: "main", head: "x", lastCommitDate: nil, dirty: false,
                         unpushedCommits: nil, hasUpstream: false, stale: false, staleReasons: [], size: SizeSplit(),
                         removeCommand: nil)
        w.size.rebuildable = bytes
        return Repo(name: name, path: "/r/\(name)", defaultBranch: "main", worktrees: [w])
    }

    func testPartialMergeKeepsFreshAndMarksStaleCache() {
        let prev = ScanResult(scannedAt: Date(), roots: ["/r"], volume: nil,
                              repos: [repo("a", 1), repo("b", 2), repo("c", 3)], caches: [], skippedPaths: 0)
        let m = PartialScan.merge(previous: prev, fresh: [repo("b", 50)], roots: ["/r"], volume: nil)
        XCTAssertEqual(m.result.repos.map(\.name), ["b", "c", "a"])
        XCTAssertEqual(m.result.repos.first?.size.total, 50, "fresh replaces cached")
        XCTAssertEqual(m.staleCache, ["/r/a", "/r/c"])
        let none = PartialScan.merge(previous: nil, fresh: [repo("x", 1)], roots: [], volume: nil)
        XCTAssertEqual(none.staleCache, [])
    }

    func testCancelKillsRunningChildProcess() {
        let flag = CancelFlag()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
        CancelFlag.current = flag
        let out = Shell.run(["sleep", "10"], timeout: 20)
        CancelFlag.current = nil
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "child was killed, not waited out")
        CancelFlag.current = flag
        XCTAssertNil(Shell.run(["echo", "hi"]), "no new child starts after cancel")
        CancelFlag.current = nil
        XCTAssertEqual(Shell.run(["echo", "hi"]), "hi")
    }

    func testTimeoutWaitsForWorkerSoRetryNeverOverlaps() async {
        let running = EventLog()
        do {
            _ = try await Deadline.run(timeout: 0.2) { cancel -> Int in
                running.add(.failed("start"))
                CancelFlag.current = cancel
                _ = Shell.run(["sleep", "10"], timeout: 20)   // a stuck git call
                running.add(.failed("stop"))
                return 0
            }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(running.all.count, 2, "worker had stopped before the timeout was reported")
        }
    }
}
