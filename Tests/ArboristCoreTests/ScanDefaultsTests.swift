import XCTest
@testable import ArboristCore

/// D32: default roots ~, ~/go, /tmp at depth 8; old defaults migrate, custom configs don't.
final class ScanDefaultsTests: XCTestCase, @unchecked Sendable {
    func decode(_ json: String) throws -> ArboristConfig { try JSONDecoder().decode(ArboristConfig.self, from: Data(json.utf8)) }

    func testDefaults() {
        XCTAssertEqual(ArboristConfig.defaults.roots, ["~", "~/go", "/tmp"])
        XCTAssertEqual(ArboristConfig.defaults.maxDepth, 8)
    }
    func testOldDefaultMigrates() throws {
        for json in [#"{"roots":["~","/tmp"],"maxDepth":4,"lowSpaceThresholdGB":30}"#,
                     #"{"roots":["~","/tmp"]}"#, #"{"roots":["~","~/Documents"],"maxDepth":4}"#] {
            let c = try decode(json)
            XCTAssertEqual(c.roots, ["~", "~/go", "/tmp"], json); XCTAssertEqual(c.maxDepth, 8, json)
        }
        XCTAssertEqual(try decode(#"{"roots":["~","/tmp"],"lowSpaceThresholdGB":30}"#).lowSpaceThresholdGB, 30)
    }
    func testCustomUntouched() throws {
        let a = try decode(#"{"roots":["~","/tmp"],"maxDepth":6}"#)
        XCTAssertEqual(a.roots, ["~", "/tmp"]); XCTAssertEqual(a.maxDepth, 6)
        let b = try decode(#"{"roots":["~/code"],"maxDepth":4}"#)
        XCTAssertEqual(b.roots, ["~/code"]); XCTAssertEqual(b.maxDepth, 4)
    }
    func testAlreadyNewIsUnchangedAndIdempotent() throws {
        let c = try decode(#"{"roots":["~","~/go","/tmp"],"maxDepth":8}"#)
        XCTAssertEqual(c.roots, ArboristConfig.defaults.roots); XCTAssertEqual(c.maxDepth, 8)
        let again = try JSONDecoder().decode(ArboristConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(again, c)
        let migrated = try decode(#"{"roots":["~","/tmp"],"maxDepth":4}"#)
        XCTAssertEqual(try JSONDecoder().decode(ArboristConfig.self, from: JSONEncoder().encode(migrated)), migrated)
    }

    var base = ""
    override func setUp() { base = NSTemporaryDirectory() + "arborist-go-\(UUID().uuidString)" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: base) }
    func makeRepo(_ path: String) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = Shell.run(["git", "-C", path, "init", "-q", "-b", "main"])
        _ = Shell.run(["git", "-C", path, "-c", "user.name=T", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "i"])
    }

    func testDepthFiveRepoUnderGoFoundOnceWithNestedRoots() {
        let home = base + "/home", go = home + "/go"
        makeRepo(go + "/src/github.com/acme/widget") // depth 5 from home, 4 from go
        makeRepo(go + "/pkg/mod/github.com/acme/cached@v1") // module cache: never listed
        for roots in [[home, go], [go, home]] {
            let r = Scanner(config: ArboristConfig(roots: roots, lowSpaceThresholdGB: 1, maxDepth: 8), prLookup: nil).scan()
            let paths = r.repos.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            XCTAssertEqual(paths, ["widget"], "\(roots)")
        }
        // At the old depth 4, from home alone, it was missed; ~/go as a root finds it.
        XCTAssertTrue(Scanner(config: ArboristConfig(roots: [home], lowSpaceThresholdGB: 1, maxDepth: 4), prLookup: nil).scan().repos.isEmpty)
        XCTAssertEqual(Scanner(config: ArboristConfig(roots: [home, go], lowSpaceThresholdGB: 1, maxDepth: 4), prLookup: nil).scan().repos.count, 1)
    }

    func testHelpSummaryFollowsDefaults() {
        XCTAssertEqual(ArboristConfig.defaultsSummary, "default roots: ~, ~/go and /tmp; depth 8")
    }
}
