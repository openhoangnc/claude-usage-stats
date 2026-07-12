import Foundation

/// Locates the `claude` CLI the same way the user's terminal does.
///
/// The binary often lives on a PATH entry that is only added in `.zshrc`
/// (nvm/fnm/volta, a custom npm prefix, `~/.local/node/bin`, …). A plain
/// `zsh -lc` is a *login but non-interactive* shell and does **not** source
/// `.zshrc`, so it misses those entries. We use an interactive login shell
/// (`zsh -ilc`) instead, which sources the full config.
///
/// The result is cached only once `claude` is actually located, so a failed
/// lookup does not stick — "Refresh" recovers after the CLI is installed or the
/// environment is fixed, without restarting the app.
enum PathResolver {

    /// Where `claude` is and the PATH to run it under (so its own child
    /// processes — node, git — also resolve).
    struct Resolution {
        let claude: String
        let path: String
    }

    private static let lock = NSLock()
    private static var cached: Resolution?

    /// Cached resolution if `claude` was found before and still exists;
    /// otherwise a fresh attempt. `nil` when `claude` can't be located.
    static func resolve() -> Resolution? {
        lock.lock(); defer { lock.unlock() }

        if let c = cached, FileManager.default.isExecutableFile(atPath: c.claude) {
            return c
        }
        cached = nil   // stale (binary moved/removed) — re-resolve below

        let path = interactiveLoginPath()
        if let claude = locate("claude", onPath: path) {
            let result = Resolution(claude: claude, path: path)
            cached = result
            return result
        }
        return nil
    }

    /// PATH as seen by an interactive login shell. A unique sentinel brackets
    /// the value so a noisy `.zshrc` (banners, instant prompt) can't corrupt it.
    private static func interactiveLoginPath() -> String {
        let mark = "__CLAUDE_STATS_PATH__"
        let out = runZsh(["-ilc", "printf '%s%s%s' '\(mark)' \"$PATH\" '\(mark)'"])
        if let start = out.range(of: mark),
           let end = out.range(of: mark, range: start.upperBound..<out.endIndex) {
            let value = String(out[start.upperBound..<end.lowerBound])
            if !value.isEmpty { return value }
        }
        return fallbackPath()
    }

    private static func runZsh(_ args: [String]) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = Pipe()            // discard
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            NSLog("PathResolver: failed to run zsh: \(error)")
            return ""
        }
    }

    /// First executable named `name` across the colon-separated `path`.
    private static func locate(_ name: String, onPath path: String) -> String? {
        let fm = FileManager.default
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Used only when the interactive shell fails to produce a PATH at all.
    private static func fallbackPath() -> String {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/node/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
    }
}
