import ArboristCore
import Foundation

let usage = """
arborist — read-only disk usage for dev repos, git worktrees and caches

USAGE:
  arborist scan [--json] [--root PATH ...] [--max-depth N]
  arborist free [--json]
  arborist config            print the config file path and contents

Without --root, roots come from ~/.config/arborist/config.json (default: ~ and ~/Documents).
arborist never deletes anything.
"""

var args = Array(CommandLine.arguments.dropFirst())
var command = "scan"
if let first = args.first, !first.hasPrefix("-") || first == "-h" || first == "--help" { command = first; args.removeFirst() }
let json = args.contains("--json")
var config = ArboristConfig.load()
var roots: [String] = []
var i = 0
while i < args.count {
    switch args[i] {
    case "--root" where i + 1 < args.count: roots.append(args[i + 1]); i += 1
    case "--max-depth" where i + 1 < args.count: config.maxDepth = Int(args[i + 1]) ?? config.maxDepth; i += 1
    case "--json": break
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
case "-h", "--help", "help": print(usage)
default: print(usage); exit(2)
}
