@testable import ArboristCore
import Foundation
import XCTest

/// D15: the sweep's ground truth (plain point-in-polygon on drawn outlines in view coordinates) agrees
/// with what HoverTracker hovers, on the busy sample.
final class HoverSweepTruthTests: XCTestCase {
    let map: LeafMap = {
        let r = LeafSample.busy
        return LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    }()

    func testNoMismatchesUnderSeveralTransforms() {
        for t in [MapTransform.identity, .fit(map, into: Pt(448, 400), origin: Pt(16, 52)),
                  .fit(map, into: Pt(300, 260)), .fit(map, into: Pt(700, 400))] {
            let report = HoverSweep.Report(HoverSweep.run(map, path: HoverSweep.path(in: map, rows: 7, perRow: 40), transform: t))
            XCTAssertEqual(report.mismatches, 0, "\(t): \(report.summary)")
            XCTAssertGreaterThan(report.frames.filter { $0.underPointer != nil }.count, 100)
        }
    }

    func testGapFramesAreMarkedAndSnapped() throws {
        let frames = HoverSweep.run(map, path: HoverSweep.path(in: map))
        for f in frames where f.inGap { XCTAssertNil(f.underPointer) }
        for f in frames where !f.inGap { XCTAssertNil(f.snappedTo) }
        let s = String(decoding: HoverSweep.json(frames), as: UTF8.self)
        for key in ["\"frames\"", "\"hoveredCount\"", "\"mismatches\"", "\"gapFrames\"", "\"underPointer\"", "\"inGap\"", "\"snappedTo\""] {
            XCTAssertTrue(s.contains(key), key)
        }
    }

    /// Runs the real CLI: `arborist render --busy --hover-sweep DIR`, then reads frames.json.
    func testCLISweepHasNoMismatches() throws {
        let bin = try XCTUnwrap(Self.cliBinary(), "arborist binary next to the test bundle (build it with swift build)")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["render", "--busy", "--hover-sweep", dir.path]
        p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let r = try JSONDecoder().decode(HoverSweep.Report.self, from: Data(contentsOf: dir.appendingPathComponent("frames.json")))
        XCTAssertEqual(r.frames.count, 50)
        XCTAssertEqual(r.mismatches, 0, r.summary)
        XCTAssertGreaterThan(r.hoveredCount, 40)
    }

    static func cliBinary() -> URL? {
        // The test runner (Linux: …/debug/arboristPackageTests.xctest; macOS: inside the .xctest bundle) lives
        // in the build products directory, next to the arborist executable.
        var dir = URL(fileURLWithPath: CommandLine.arguments.first { $0.contains(".xctest") } ?? Bundle(for: HoverSweepTruthTests.self).bundlePath)
        for _ in 0..<6 {
            dir = dir.deletingLastPathComponent()
            let u = dir.appendingPathComponent("arborist")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
        }
        return nil
    }
}
