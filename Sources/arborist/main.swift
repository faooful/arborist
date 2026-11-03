import ArboristCore
import Foundation

let usage = """
arborist — read-only disk usage for dev repos, git worktrees and caches

USAGE:
  arborist scan [--json] [--root PATH ...] [--max-depth N]
  arborist free [--json]
  arborist config            print the config file path and contents
  arborist render [--sample|--busy|--from SCAN.json] [--filter NAME[,NAME]] [--state ready|uncommitted|clean|stale[,..]] [--hover N|PATH] --out FILE.svg   worktree leaf map as SVG (N: leaf drawn hovered)
  arborist render [--sample|--busy|--from SCAN.json] [--filter NAME[,NAME]] [--state S[,..]] --hover-sweep DIR   hover sweep: frame-NNN.svg + frames.json
  arborist render-stages --out FILE.svg        the four menu bar leaf stages as SVG

Without --root, roots come from ~/.config/arborist/config.json (default: ~ and ~/Documents).
arborist never deletes anything.
"""

var args = Array(CommandLine.arguments.dropFirst())
var command = "scan"
if let first = args.first, !first.hasPrefix("-") || first == "-h" || first == "--help" { command = first; args.removeFirst() }
let json = args.contains("--json")
var config = ArboristConfig.load()
var roots: [String] = []
var outPath: String?
var hoverArg: String?
var fromPath: String?
var sweepDir: String?
var filterNames: [String]?
var stateArg: String?
var i = 0
while i < args.count {
    switch args[i] {
    case "--root" where i + 1 < args.count: roots.append(args[i + 1]); i += 1
    case "--max-depth" where i + 1 < args.count: config.maxDepth = Int(args[i + 1]) ?? config.maxDepth; i += 1
    case "--out" where i + 1 < args.count: outPath = args[i + 1]; i += 1
    case "--from" where i + 1 < args.count: fromPath = args[i + 1]; i += 1
    case "--hover" where i + 1 < args.count: hoverArg = args[i + 1]; i += 1
    case "--state" where i + 1 < args.count: stateArg = args[i + 1]; i += 1
    case "--filter" where i + 1 < args.count: filterNames = args[i + 1].split(separator: ",").map(String.init); i += 1
    case "--hover-sweep" where i + 1 < args.count: sweepDir = args[i + 1]; i += 1
    case "--json", "--sample", "--busy": break
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write("unknown argument: \(args[i])\n\n\(usage)\n".data(using: .utf8)!); exit(2)
    }
    i += 1
}
if !roots.isEmpty { config.roots = roots }

switch command {
case "scan":
    let r = args.contains("--busy") ? LeafSample.busy : Scanner(config: config).scan()
    if json { FileHandle.standardOutput.write(try! r.jsonData()); print() } else { print(Format.humanReport(r)) }
case "free":
    guard let v = DiskUsage.volume(for: ArboristConfig.home) else { exit(1) }
    if json {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try! e.encode(v)); print()
    } else { print("\(Format.bytes(v.freeBytes)) free of \(Format.bytes(v.totalBytes))") }
case "config":
    print(ArboristConfig.fileURL.path)
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! e.encode(config), as: UTF8.self))
case "render":
    let svg: String
    // --sample: small example; --busy: a busy machine (D13); --from FILE: a saved `scan --json`.
    let sample = args.contains("--sample") || args.contains("--busy") || fromPath != nil
    let unfiltered = try! fromPath.map { try ScanResult.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
        ?? (args.contains("--busy") ? LeafSample.busy : sample ? LeafSample.scan : Scanner(config: config).scan())
    // --filter name[,name]: only those repos (by name or path), like the header filter (D18).
    // --state ready|uncommitted|clean|stale[,..]: the legend's state filter, ANDed with --filter (D21).
    let states = stateArg.map { a -> StateFilter in
        guard let s = StateFilter.parse(a) else {
            FileHandle.standardError.write("bad --state \(a); use ready|uncommitted|clean|stale[,..]\n".data(using: .utf8)!); exit(2)
        }
        return s
    } ?? .all
    let visible = VisibleSet(repos: filterNames.map { RepoFilter.only(names: $0, among: unfiltered.repos) } ?? .all, states: states)
    let r = visible.apply(unfiltered)
    if filterNames != nil && visible.repos.isEmpty(unfiltered.repos) {
        FileHandle.standardError.write("--filter matched no repos; available: \(unfiltered.repos.map(\.name).joined(separator: ", "))\n".data(using: .utf8)!); exit(2)
    }
    if r.repos.isEmpty { FileHandle.standardError.write("nothing matches --filter/--state\n".data(using: .utf8)!); exit(2) }
    let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
    // --hover N draws the Nth leaf hovered, with its card (for snapshots).
    // --hover N (leaf index) or --hover PATH (a worktree path).
    let hover = hoverArg.flatMap { a in Int(a).flatMap { $0 < map.leaves.count ? map.leaves[$0].item.id : nil } ?? map.leaves.first { $0.item.id == a }?.item.id }
    svg = LeafSVG.popover(r, map: map, note: sample ? "sample data · Linux render" : "Linux render", hover: hover,
                          now: sample ? LeafSample.now : Date())
    if let dir = sweepDir {
        // Same HoverTracker path as the app's mouse tracking (D15): frame-NNN.svg plus frames.json.
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = HoverSweep.path(in: map)
        let frames = HoverSweep.run(map, path: path, space: LeafSVG.cardSpace(map)) { i, t in
            let svg = LeafSVG.popover(r, map: map, note: "hover sweep · frame \(i)", hover: t.card,
                                      now: sample ? LeafSample.now : Date(), cardAt: t.cardOrigin, pointer: path[i], cardOpacity: t.cardOpacity)
            try! svg.write(toFile: dir + String(format: "/frame-%03d.svg", i), atomically: true, encoding: .utf8)
        }
        let report = HoverSweep.Report(frames)
        try! HoverSweep.json(report).write(to: URL(fileURLWithPath: dir + "/frames.json"))
        print(report.summary)
        print("frames in \(dir)")
        exit(0)
    }
    write(svg, to: outPath)
case "render-stages":
    write(LeafSVG.stageStrip(), to: outPath)
case "-h", "--help", "help": print(usage)
default: print(usage); exit(2)
}

/// Takes the path as a parameter so it doesn't read top-level state (fine in Swift 5 and 6 modes).
func write(_ svg: String, to outPath: String?) {
    if let outPath { try! svg.write(toFile: outPath, atomically: true, encoding: .utf8); print(outPath) } else { print(svg) }
}
