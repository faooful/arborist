import ArboristCore
import Foundation

let usage = """
arborist — read-only disk usage for dev repos, git worktrees and caches

USAGE:
  arborist scan [--json] [--root PATH ...] [--max-depth N]
  arborist free [--json]
  arborist config            print the config file path and contents
  arborist render [--sample] --out FILE.svg    leaf map (H8) as SVG, from a scan or the sample data
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
var i = 0
while i < args.count {
    switch args[i] {
    case "--root" where i + 1 < args.count: roots.append(args[i + 1]); i += 1
    case "--max-depth" where i + 1 < args.count: config.maxDepth = Int(args[i + 1]) ?? config.maxDepth; i += 1
    case "--out" where i + 1 < args.count: outPath = args[i + 1]; i += 1
    case "--json", "--sample": break
    case "-h", "--help": print(usage); exit(0)
    default: FileHandle.standardError.write("unknown argument: \(args[i])\n\n\(usage)\n".data(using: .utf8)!); exit(2)
    }
    i += 1
}
if !roots.isEmpty { config.roots = roots }

switch command {
case "scan":
    let r = Scanner(config: config).scan()
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
    if args.contains("--sample") {
        svg = LeafSVG.popover(LeafLayout.layout(LeafSample.groups), freeBytes: LeafSample.freeBytes, totalBytes: LeafSample.totalBytes, note: "sample data · Linux render")
    } else {
        let r = Scanner(config: config).scan()
        let map = LeafLayout.layout(LeafLayout.groups(from: r), staleCount: r.totals.staleWorktrees)
        svg = LeafSVG.popover(map, freeBytes: r.volume?.freeBytes ?? 0, totalBytes: r.volume?.totalBytes ?? 0)
    }
    write(svg)
case "render-stages":
    write(LeafSVG.stageStrip())
case "-h", "--help", "help": print(usage)
default: print(usage); exit(2)
}

func write(_ svg: String) {
    if let outPath { try! svg.write(toFile: outPath, atomically: true, encoding: .utf8); print(outPath) } else { print(svg) }
}
