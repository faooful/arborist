import XCTest
@testable import DevspaceCore

final class GitParsingTests: XCTestCase {
    func testParsesPorcelainWorktreeList() {
        let text = """
        worktree /Users/j/code/app
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/j/code/app-wt/feature x
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/x

        worktree /Users/j/code/app-wt/detached
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /Users/j/code/app-wt/gone
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/old
        prunable gitdir file points to non-existent location

        """
        let w = GitParsing.parseWorktreeList(text)
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[0].path, "/Users/j/code/app")
        XCTAssertEqual(w[0].branch, "main")
        XCTAssertEqual(w[1].path, "/Users/j/code/app-wt/feature x")
        XCTAssertEqual(w[1].branch, "feature/x")
        XCTAssertTrue(w[2].detached)
        XCTAssertNil(w[2].branch)
        XCTAssertTrue(w[3].prunable)
    }

    func testParsesWithoutTrailingBlankLineAndBare() {
        let w = GitParsing.parseWorktreeList("worktree /r.git\nbare\n\nworktree /r/wt\nHEAD abc\nbranch refs/heads/x")
        XCTAssertEqual(w.count, 2)
        XCTAssertTrue(w[0].bare)
        XCTAssertEqual(w[1].branch, "x")
    }

    func testShortRefAndFlags() {
        XCTAssertEqual(GitParsing.shortRef("refs/remotes/origin/main"), "main")
        XCTAssertEqual(GitParsing.shortRef("refs/heads/a/b"), "a/b")
        XCTAssertTrue(GitParsing.isUpstreamGone("[gone]"))
        XCTAssertFalse(GitParsing.isUpstreamGone("[ahead 2]"))
        XCTAssertTrue(GitParsing.isDirty(" M file.swift\n"))
        XCTAssertFalse(GitParsing.isDirty("\n"))
    }

    func testStaleRules() {
        XCTAssertEqual(GitParsing.staleReasons(branch: "f", defaultBranch: "main", isMain: false, mergedIntoDefault: true, upstreamGone: false, prunable: false), [.merged])
        XCTAssertEqual(GitParsing.staleReasons(branch: "f", defaultBranch: "main", isMain: false, mergedIntoDefault: false, upstreamGone: true, prunable: false), [.upstreamGone])
        XCTAssertEqual(GitParsing.staleReasons(branch: "main", defaultBranch: "main", isMain: true, mergedIntoDefault: true, upstreamGone: false, prunable: false), [])
        XCTAssertEqual(GitParsing.staleReasons(branch: "main", defaultBranch: "main", isMain: false, mergedIntoDefault: true, upstreamGone: false, prunable: false), [])
        XCTAssertEqual(GitParsing.staleReasons(branch: nil, defaultBranch: "main", isMain: false, mergedIntoDefault: false, upstreamGone: false, prunable: true), [.prunable])
    }
}

final class ClassificationTests: XCTestCase {
    func testRebuildableNames() {
        for n in ["node_modules", ".next", "dist", "target", ".venv", "DerivedData", ".build"] { XCTAssertTrue(DiskUsage.isRebuildable(n), n) }
        for n in ["src", "Sources", ".git", "build"] { XCTAssertFalse(DiskUsage.isRebuildable(n), n) }
    }

    func testMeasureSplitsRebuildableAndSkipsNestedRepos() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("devspace-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func write(_ rel: String, _ bytes: Int) throws {
            let u = root.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: u)
        }
        try write("src/main.swift", 50_000)
        try write("node_modules/pkg/index.js", 200_000)
        try write("web/.next/cache/x", 100_000)
        try write("nested/.git/HEAD", 10)
        try write("nested/big.bin", 900_000)
        var skipped = 0
        let s = DiskUsage.measureWorktree(root.path, skipped: &skipped)
        XCTAssertGreaterThanOrEqual(s.rebuildable, 300_000)
        XCTAssertGreaterThanOrEqual(s.source, 50_000)
        XCTAssertLessThan(s.source, 900_000, "nested repo should not be counted")
    }

    func testDockerSizes() {
        XCTAssertEqual(Caches.parseDockerSize("1.5GB"), 1_500_000_000)
        XCTAssertEqual(Caches.parseDockerSize("12kB"), 12_000)
        XCTAssertEqual(Caches.parseDockerSize("0B"), 0)
        XCTAssertNil(Caches.parseDockerSize("n/a"))
    }

    func testFormatAndQuote() {
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(Format.bytes(1_500_000_000), "1.5 GB")
        XCTAssertEqual(Shell.quote("/a/b"), "/a/b")
        XCTAssertEqual(Shell.quote("/a b/it's"), "'/a b/it'\\''s'")
    }

    func testJSONRoundTrip() throws {
        let r = ScanResult(scannedAt: Date(timeIntervalSince1970: 1_700_000_000), roots: ["/r"],
                           volume: VolumeInfo(path: "/", freeBytes: 10, totalBytes: 20),
                           repos: [Repo(name: "a", path: "/r/a", defaultBranch: "main", worktrees: [])],
                           caches: [CacheEntry(name: "npm", path: "/n", bytes: 5)], skippedPaths: 0)
        let data = try r.jsonData()
        XCTAssertEqual(try ScanResult.decode(data), r)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"totals\""))
    }
}

/// End-to-end against real git: a repo with a merged worktree and an unmerged dirty one.
final class ScannerIntegrationTests: XCTestCase {
    func testScanFindsWorktreesAndStaleness() throws {
        guard Shell.run(["git", "--version"]) != nil else { throw XCTSkip("git not installed") }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("devspace-int-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: base) }
        let repo = base + "/proj"
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        func g(_ dir: String, _ a: String...) { _ = Shell.run(["git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + a) }
        g(repo, "init", "-q", "-b", "main")
        try "hi".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        g(repo, "add", "."); g(repo, "commit", "-qm", "one")
        g(repo, "worktree", "add", "-q", "-b", "done", base + "/wt-done")
        try "x".write(toFile: base + "/wt-done/b.txt", atomically: true, encoding: .utf8)
        g(base + "/wt-done", "add", "."); g(base + "/wt-done", "commit", "-qm", "two")
        g(repo, "merge", "-q", "--ff-only", "done")
        g(repo, "worktree", "add", "-q", "-b", "wip", base + "/wt-wip")
        try "y".write(toFile: base + "/wt-wip/c.txt", atomically: true, encoding: .utf8)
        g(base + "/wt-wip", "add", "."); g(base + "/wt-wip", "commit", "-qm", "three")
        try "dirty".write(toFile: base + "/wt-wip/d.txt", atomically: true, encoding: .utf8)

        let r = Scanner(config: DevspaceConfig(roots: [base], lowSpaceThresholdGB: 1, maxDepth: 3)).scan()
        XCTAssertEqual(r.repos.count, 1, "worktrees must be grouped under one repo")
        let wts = r.repos[0].worktrees
        XCTAssertEqual(wts.count, 3)
        XCTAssertTrue(wts[0].isMain)
        let done = try XCTUnwrap(wts.first { $0.branch == "done" })
        let wip = try XCTUnwrap(wts.first { $0.branch == "wip" })
        XCTAssertEqual(done.staleReasons, [.merged])
        XCTAssertFalse(wip.stale)
        XCTAssertTrue(wip.dirty)
        XCTAssertNotNil(wip.lastCommitDate)
        XCTAssertTrue(wip.removeCommand?.contains("worktree remove") == true)
        // Still all there: the scan is read-only.
        XCTAssertTrue(fm.fileExists(atPath: base + "/wt-done/b.txt"))
    }
}

final class BlobLayoutTests: XCTestCase {
    func testBlobsFitAndDoNotOverlap() {
        let items: [(id: String, label: String, bytes: Int64, kind: Blob.Kind)] = [
            ("a", "a", 900, .project), ("b", "b", 400, .project), ("c", "c", 100, .rebuildable),
            ("d", "d", 50, .caches), ("f", "Free", 2000, .free), ("z", "z", 0, .project),
        ]
        let blobs = BlobLayout.layout(items, width: 600, height: 300)
        XCTAssertEqual(blobs.count, 5, "zero-byte items are dropped")
        XCTAssertEqual(blobs.first?.id, "f", "largest first")
        for b in blobs {
            XCTAssertGreaterThanOrEqual(b.x - b.r, -0.001); XCTAssertLessThanOrEqual(b.x + b.r, 600.001)
            XCTAssertGreaterThanOrEqual(b.y - b.r, -0.001); XCTAssertLessThanOrEqual(b.y + b.r, 300.001)
        }
        for i in blobs.indices { for j in blobs.indices where j > i {
            XCTAssertGreaterThanOrEqual(hypot(blobs[i].x - blobs[j].x, blobs[i].y - blobs[j].y), blobs[i].r + blobs[j].r - 0.001)
        } }
        // Area ~ bytes: a (900) vs b (400) radius ratio is 1.5.
        let a = blobs.first { $0.id == "a" }!, b = blobs.first { $0.id == "b" }!
        XCTAssertEqual(a.r / b.r, 1.5, accuracy: 0.01)
    }
}
