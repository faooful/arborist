import Foundation

/// Runs a command (read-only git/docker queries only) and returns trimmed stdout, or nil on failure.
public enum Shell {
    public static func run(_ args: [String], cwd: String? = nil, timeout: TimeInterval = 20) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0" // `git status` must not take index locks
        // GUI apps get a minimal PATH; make Homebrew git/docker findable.
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
        try? out.fileHandleForReading.close()
        p.waitUntilExit()
        timer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func git(_ dir: String, _ args: String...) -> String? {
        run(["git", "-C", dir] + args)
    }

    /// Single-quote a path for copy-paste into a shell.
    public static func quote(_ s: String) -> String {
        if s.range(of: "^[A-Za-z0-9_./~+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
