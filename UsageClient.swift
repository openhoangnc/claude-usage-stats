import Foundation
import Security

// MARK: - Models

/// One rate-limit window as returned by the Claude usage endpoint.
struct UsageLimit {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped"
    let title: String       // display title, e.g. "Current week (Fable)"
    let percent: Int        // 0...100 (may exceed 100 on overage)
    let severity: String    // "normal" | "warning" | "critical" | ...
    let resetsAt: Date?
}

/// A full snapshot of usage at a point in time.
struct UsageSnapshot {
    let limits: [UsageLimit]        // in display order (session, weekly_all, weekly_scoped)
    let fetchedAt: Date

    var session: UsageLimit?   { limits.first { $0.kind == "session" } }
    var weeklyAll: UsageLimit? { limits.first { $0.kind == "weekly_all" } }
}

enum UsageError: Error {
    case claudeCliNotInstalled
    case noCredentials
    case tokenExpired
    case rateLimited(retryAfterSeconds: Int?)
    case http(Int)
    case badResponse
    case network(String)

    var message: String {
        switch self {
        case .claudeCliNotInstalled: return "Claude CLI not found — run: npm i -g @anthropic-ai/claude-code"
        case .noCredentials:         return "Not signed in — run 'claude' in Terminal to login"
        case .tokenExpired:          return "Auth expired — run 'claude' in Terminal to login"
        case .rateLimited(let retry):
            if let r = retry, r > 0 {
                let mins = max(1, (r + 59) / 60)
                return "Rate limited — retrying in \(mins)m"
            }
            return "Rate limited — will retry"
        case .http(let c):           return c == 429 ? "Rate limited — will retry" : "Server error (HTTP \(c))"
        case .badResponse:           return "Unexpected response"
        case .network(let m):        return m
        }
    }
}

// MARK: - Client

/// Invokes the local `claude` CLI via `/bin/zsh -lc` to fetch usage limits and
/// parses the output.
final class UsageClient {

    /// Fetch a fresh snapshot. `completion` is always called on the main thread.
    func fetch(completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-lc", "claude -p '/usage' < /dev/null"]
            task.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            do {
                try task.run()
                task.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                let status = task.terminationStatus

                if status == 127 || stdoutStr.contains("command not found") || stderrStr.contains("command not found") {
                    return self.finish(.failure(.claudeCliNotInstalled), completion)
                }

                if status != 0 {
                    let errorMsg = (stdoutStr + stderrStr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isAuthError(errorMsg) {
                        return self.finish(.failure(.noCredentials), completion)
                    }
                    return self.finish(.failure(.network(errorMsg.isEmpty ? "Claude CLI exited with code \(status)" : errorMsg)), completion)
                }

                guard let snapshot = Self.parseCLIOutput(stdoutStr) else {
                    let combined = stdoutStr + stderrStr
                    if Self.isAuthError(combined) {
                        return self.finish(.failure(.noCredentials), completion)
                    }
                    return self.finish(.failure(.badResponse), completion)
                }

                self.finish(.success(snapshot), completion)
            } catch {
                self.finish(.failure(.network(error.localizedDescription)), completion)
            }
        }
    }

    private static func isAuthError(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("not signed in") ||
               normalized.contains("sign in") ||
               normalized.contains("sign-in") ||
               normalized.contains("auth login") ||
               normalized.contains("credentials") ||
               normalized.contains("logged in") ||
               normalized.contains("authenticate") ||
               normalized.contains("login")
    }

    private func finish(_ result: Result<UsageSnapshot, UsageError>,
                        _ completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: Parsing

    static func parseCLIOutput(_ text: String) -> UsageSnapshot? {
        let lines = text.components(separatedBy: .newlines)
        var limits: [UsageLimit] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Match lines like:
            // "Current session: 2% used · resets Jul 7 at 1:59pm (Asia/Saigon)"
            guard trimmed.contains("%") && trimmed.contains("used") else { continue }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rightSide = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            let rightParts = rightSide.components(separatedBy: "·")
            guard !rightParts.isEmpty else { continue }

            let percentStr = rightParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var percent = 0
            if let pctIndex = percentStr.firstIndex(of: "%") {
                let numPart = percentStr[..<pctIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = numPart.filter { $0.isNumber }
                percent = Int(digits) ?? 0
            }

            var resetsAt: Date? = nil
            if rightParts.count >= 2 {
                resetsAt = parseCLIDate(rightParts[1])
            }

            let kind: String
            if title.lowercased().contains("session") {
                kind = "session"
            } else if title.lowercased().contains("all models") {
                kind = "weekly_all"
            } else {
                kind = "weekly_scoped"
            }

            let severity: String
            if percent >= 90 {
                severity = "critical"
            } else if percent >= 75 {
                severity = "warning"
            } else {
                severity = "normal"
            }

            limits.append(UsageLimit(kind: kind, title: title, percent: percent, severity: severity, resetsAt: resetsAt))
        }

        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, fetchedAt: Date())
    }

    // MARK: Dates

    static func parseCLIDate(_ s: String) -> Date? {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("resets ") {
            cleaned = String(cleaned.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract timezone if present in parentheses
        var tz: TimeZone? = nil
        if let openParen = cleaned.firstIndex(of: "("),
           let closeParen = cleaned.firstIndex(of: ")"),
           openParen < closeParen {
            let tzStr = String(cleaned[cleaned.index(after: openParen)..<closeParen])
            tz = TimeZone(identifier: tzStr)
            cleaned = String(cleaned[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz ?? TimeZone.current

        let formats = ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d 'at' h:mm a", "MMM d 'at' h a"]
        var parsedDate: Date? = nil
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                parsedDate = date
                break
            }
        }

        guard let date = parsedDate else { return nil }

        // Adjust to current year since DateFormatter defaults to 2000 when year is missing
        let currentYear = Calendar.current.component(.year, from: Date())
        let parsedComp = Calendar.current.dateComponents(in: tz ?? TimeZone.current, from: date)
        
        var comp = DateComponents()
        comp.timeZone = tz ?? TimeZone.current
        comp.year = currentYear
        comp.month = parsedComp.month
        comp.day = parsedComp.day
        comp.hour = parsedComp.hour
        comp.minute = parsedComp.minute
        comp.second = parsedComp.second

        if let resultDate = Calendar.current.date(from: comp) {
            // Adjust if date wraps around new year boundaries
            if resultDate.timeIntervalSinceNow < -86400 * 180 {
                comp.year = currentYear + 1
                return Calendar.current.date(from: comp)
            } else if resultDate.timeIntervalSinceNow > 86400 * 180 {
                comp.year = currentYear - 1
                return Calendar.current.date(from: comp)
            }
            return resultDate
        }

        return date
    }
}

// MARK: - Presentation helpers

enum UsageFormat {

    /// Reset label with local clock time (no timezone) and remaining duration,
    /// e.g. "Resets 12:50pm · in 1h 23m" or "Resets Jul 8, 6am · in 1d 18h".
    static func reset(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "Resets now" }
        return "Resets \(clock(date)) · \(duration(seconds))"
    }

    /// Local wall-clock time, no timezone label. Same-day → "12:50pm";
    /// a future day → "Jul 8, 6am".
    private static func clock(_ date: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = .current
        // The endpoint returns times like HH:MM:59.9…; round to the nearest minute.
        let rounded = Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)

        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = .current
        time.dateFormat = cal.component(.minute, from: rounded) == 0 ? "ha" : "h:mma"
        let timeStr = time.string(from: rounded).lowercased()

        if cal.isDate(rounded, inSameDayAs: Date()) { return timeStr }

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = .current
        day.dateFormat = "MMM d"
        return "\(day.string(from: rounded)), \(timeStr)"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((seconds / 60).rounded())
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d" }
        if hours > 0 { return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h" }
        return "in \(max(1, minutes))m"
    }

    /// Short "updated N ago" string for the panel footer.
    static func ago(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 5   { return "just now" }
        if s < 60  { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

// MARK: - Version Provider

/// Automatically keeps the `claude-code/<version>` User-Agent header string up to date.
/// Checks the npm registry (`@anthropic-ai/claude-code/latest`) once every 24 hours
/// and caches the latest version in `UserDefaults`. Fallbacks to local `claude --version`
/// or default version.
final class ClaudeVersionProvider {
    static let shared = ClaudeVersionProvider()

    private let userDefaultsKey = "cachedClaudeCodeVersion"
    private let lastCheckKey = "lastClaudeCodeVersionCheckDate"
    private let defaultVersion = "2.1.201"

    var currentVersion: String {
        get {
            UserDefaults.standard.string(forKey: userDefaultsKey) ?? detectLocalVersion() ?? defaultVersion
        }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
        }
    }

    func refreshIfNeeded() {
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        let twentyFourHours: TimeInterval = 86400

        guard Date().timeIntervalSince(lastCheck) >= twentyFourHours else { return }

        fetchLatestFromNpm { [weak self] latestVersion in
            guard let self = self, let version = latestVersion else { return }
            self.currentVersion = version
            UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
            NSLog("ClaudeUsageStats: Updated latest Claude Code version to \(version)")
        }
    }

    private func fetchLatestFromNpm(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard err == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else {
                completion(nil)
                return
            }
            completion(version)
        }.resume()
    }

    private func detectLocalVersion() -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["claude", "--version"]
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let components = str.components(separatedBy: " ")
                if let ver = components.first, !ver.isEmpty, ver.contains(".") {
                    return ver
                }
            }
        } catch {}
        return nil
    }
}
