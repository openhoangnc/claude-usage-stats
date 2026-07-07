import Foundation

enum PathResolver {
    static let cachedPath: String = {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "echo $PATH"]
        task.standardOutput = pipe
        task.standardError = Pipe() // discard stderr
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let pathStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pathStr.isEmpty {
                return pathStr
            }
        } catch {
            NSLog("PathResolver: Failed to run zsh to get PATH: \(error)")
        }
        
        // Fallback paths if zsh execution fails
        let home = NSHomeDirectory()
        let fallbackPaths = [
            "\(home)/.local/node/bin",
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        return fallbackPaths.joined(separator: ":")
    }()
}
