import ArboristCleanup
@testable import ArboristCore
import Foundation
import XCTest

/// D21: legend state filters, "Ready to clean", and the VisibleSet shared by the map and Cleanup.plan.
final class StateFilterTests: XCTestCase, @unchecked Sendable {
    let scan = LeafSample.busy
    var worktrees: [Worktree] { scan.repos.flatMap(\.worktrees) }
    func paths(_ r: ScanResult) -> Set<String> { Set(r.repos.flatMap { $0.worktrees.map(\.path) }) }

    func testToggleOnlyShowAll() {
        var s = StateFilter.all
        XCTAssertTrue(s.isAll)
        for k in [StateKey.uncommitted, .clean, .stale] { XCTAssertTrue(s.isActive(k)) }
        XCTAssertFalse(s.isActive(.ready))
        s.toggle(.clean)
        XCTAssertFalse(s.isActive(.clean)); XCTAssertTrue(s.isActive(.stale)); XCTAssertFalse(s.isAll)
        let r = VisibleSet(states: s).apply(scan)
        XCTAssertFalse(r.repos.flatMap(\.worktrees).contains { StateKey.colour($0) == .clean })
        XCTAssertEqual(r.worktreeCount, worktrees.filter { StateKey.colour($0) != .clean }.count)
        s.toggle(.clean)
        XCTAssertTrue(s.isAll)
        s = .only(.stale)
        XCTAssertEqual(VisibleSet(states: s).apply(scan).worktreeCount, worktrees.filter { StateKey.colour($0) == .stale }.count)
        XCTAssertTrue(s.isActive(.stale)); XCTAssertFalse(s.isActive(.clean))
        s.toggle(.ready); XCTAssertTrue(s.readyOnly)
        s.toggle(.clean); XCTAssertEqual(s, .only(.clean))   // a colour while ready-only: just that colour
        s.toggle(.ready); s.toggle(.ready); XCTAssertTrue(s.isAll)
        s = .only(.uncommitted); s.showAll(); XCTAssertEqual(s, .all)
        XCTAssertEqual(VisibleSet().apply(scan), scan)
    }

    func testReadyIsExactlyTheCleanupPlan() {
        let plan = Cleanup.plan(scan)
        XCTAssertFalse(plan.isEmpty)
        let ready = VisibleSet(states: .only(.ready))
        XCTAssertEqual(paths(ready.apply(scan)), Set(plan.map(\.path)))
        XCTAssertEqual(ready.count(.ready, in: scan), plan.count)
        XCTAssertEqual(VisibleSet().count(.ready, in: scan), plan.count)       // legend N = Clear N
        XCTAssertEqual(Cleanup.plan(scan, visible: ready), plan)               // Clear N with ready-only: same set
        for w in worktrees { XCTAssertEqual(CleanupSafety.isReady(w), Cleanup.blocker(w) == nil) }
    }

    func testANDWithRepoFilter() throws {
        let plan = Cleanup.plan(scan)
        let repoWithReady = try XCTUnwrap(scan.repos.first { r in plan.contains { $0.repo == r.name } })
        let other = try XCTUnwrap(scan.repos.first { $0.path != repoWithReady.path })
        let v = VisibleSet(repos: .only(names: [repoWithReady.name, other.name], among: scan.repos), states: .only(.ready))
        let shown = v.apply(scan)
        let expected = Set((repoWithReady.worktrees + other.worktrees).filter(CleanupSafety.isReady).map(\.path))
        XCTAssertEqual(paths(shown), expected)
        XCTAssertEqual(Set(Cleanup.plan(scan, visible: v).map(\.path)), expected)
        XCTAssertEqual(v.count(.ready, in: scan), expected.count)
        XCTAssertEqual(shown.worktreeCount, expected.count)
        let cleanOnly = VisibleSet(repos: v.repos, states: .only(.clean))
        let cleanShown = paths(cleanOnly.apply(scan))
        XCTAssertTrue(Cleanup.plan(scan, visible: cleanOnly).allSatisfy { cleanShown.contains($0.path) })
        let map = LeafLayout.layout(LeafLayout.groups(from: shown), staleCount: shown.totals.staleWorktrees)
        XCTAssertEqual(Set(map.leaves.map(\.item.id)), expected)
    }

    func testNothingMatches() {
        let v = VisibleSet(repos: .only(names: [scan.repos[0].name], among: scan.repos), states: StateFilter(hidden: [.uncommitted, .clean, .stale]))
        XCTAssertTrue(v.nothingMatches(scan))
        XCTAssertFalse(VisibleSet().nothingMatches(scan))
    }

    func testStateFilterIsSessionOnly() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "arborist-state-\(UUID().uuidString)"))
        var session = VisibleSet.atLaunch(d)
        session.repos.toggle(scan.repos[0].path); session.repos.save(d)
        session.states = .only(.ready)
        let relaunch = VisibleSet.atLaunch(d)
        XCTAssertEqual(relaunch.states, .all)
        XCTAssertEqual(relaunch.repos, session.repos)
        XCTAssertEqual(Set(d.dictionaryRepresentation().keys.filter { $0.hasPrefix("arborist.") }), [RepoFilter.defaultsKey])
    }

    func testParse() {
        XCTAssertEqual(StateFilter.parse("ready"), .only(.ready))
        XCTAssertEqual(StateFilter.parse("clean,stale"), StateFilter(hidden: [.uncommitted]))
        XCTAssertEqual(StateFilter.parse("uncommitted"), .only(.uncommitted))
        XCTAssertNil(StateFilter.parse("bogus"))
    }

    func testCLISweepWithReady() throws {
        let bin = try XCTUnwrap(HoverSweepTruthTests.cliBinary())
        let names = Array(Set(Cleanup.plan(scan).map(\.repo))).sorted()
        let ready = Set(Cleanup.plan(scan).map(\.path))
        for args in [["--state", "ready"], ["--state", "ready", "--filter", names.prefix(2).joined(separator: ",")]] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rsweep-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = Process()
            p.executableURL = bin
            p.arguments = ["render", "--busy"] + args + ["--hover-sweep", dir.path]
            p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(args)")
            let r = try JSONDecoder().decode(HoverSweep.Report.self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))
            XCTAssertEqual(r.mismatches, 0, r.summary)
            XCTAssertEqual(r.stripMismatches, 0, r.summary)
            XCTAssertEqual(r.tooltipClipped, 0, r.summary)
            XCTAssertEqual(r.reachFailures, 0, r.summary)
            XCTAssertEqual(r.buttonHits, 1, "D22: the pin + reach path ends on a strip button. " + r.summary)
            for f in r.frames { if let h = f.hovered { XCTAssertTrue(ready.contains(h), h) } }
            XCTAssertGreaterThan(r.hoveredCount, 0)
        }
    }

}
