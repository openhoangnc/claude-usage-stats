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
    case noCredentials
    case tokenExpired
    case rateLimited(retryAfterSeconds: Int?)
    case http(Int)
    case badResponse
    case network(String)

    var message: String {
        switch self {
        case .noCredentials: return "Not signed in — open Claude Code"
        case .tokenExpired:  return "Auth expired — open Claude Code"
        case .rateLimited(let retry):
            if let r = retry, r > 0 {
                let mins = max(1, (r + 59) / 60)
                return "Rate limited — retrying in \(mins)m"
            }
            return "Rate limited — will retry"
        case .http(let c):   return c == 429 ? "Rate limited — will retry" : "Server error (HTTP \(c))"
        case .badResponse:   return "Unexpected response"
        case .network(let m): return m
        }
    }
}

// MARK: - Client

/// Reads the Claude Code OAuth token from the login Keychain and calls the
/// same `/api/oauth/usage` endpoint that the `claude /usage` command uses.
final class UsageClient {

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let keychainService = "Claude Code-credentials"

    /// Fetch a fresh snapshot. `completion` is always called on the main thread.
    func fetch(completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let token = self.readAccessToken() else {
                return self.finish(.failure(.noCredentials), completion)
            }

            ClaudeVersionProvider.shared.refreshIfNeeded()
            let version = ClaudeVersionProvider.shared.currentVersion

            var req = URLRequest(url: self.endpoint)
            req.httpMethod = "GET"
            req.timeoutInterval = 15
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("claude-code/\(version)", forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: req) { data, resp, err in
                if let err = err {
                    return self.finish(.failure(.network(err.localizedDescription)), completion)
                }
                guard let http = resp as? HTTPURLResponse else {
                    return self.finish(.failure(.badResponse), completion)
                }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return self.finish(.failure(.tokenExpired), completion)
                }
                if http.statusCode == 429 {
                    let retrySeconds = self.parseRetryAfter(http)
                    return self.finish(.failure(.rateLimited(retryAfterSeconds: retrySeconds)), completion)
                }
                guard http.statusCode == 200, let data = data else {
                    return self.finish(.failure(.http(http.statusCode)), completion)
                }
                guard let snapshot = Self.parse(data) else {
                    return self.finish(.failure(.badResponse), completion)
                }
                self.finish(.success(snapshot), completion)
            }.resume()
        }
    }

    private func parseRetryAfter(_ http: HTTPURLResponse) -> Int? {
        guard let headerValue = http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "retry-after") else {
            return nil
        }
        let trimmed = headerValue.trimmingCharacters(in: .whitespaces)
        if let seconds = Int(trimmed) {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            let diff = Int(date.timeIntervalSinceNow)
            return diff > 0 ? diff : nil
        }
        return nil
    }

    private func finish(_ result: Result<UsageSnapshot, UsageError>,
                        _ completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        DispatchQueue.main.async { completion(result) }
    }

    // MARK: Keychain

    /// Reads `accessToken` from the "Claude Code-credentials" generic password.
    /// The first access triggers a one-time macOS Keychain permission prompt.
    private func readAccessToken() -> String? {
        // Optional override (used by --selftest and headless setups); ignored in
        // normal use where the token comes from the Keychain.
        if let t = ProcessInfo.processInfo.environment["CLAUDE_USAGE_TOKEN"], !t.isEmpty {
            return t
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        return oauth["accessToken"] as? String
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> UsageSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var limits: [UsageLimit] = []

        if let arr = root["limits"] as? [[String: Any]] {
            for item in arr {
                guard let kind = item["kind"] as? String else { continue }
                let percent = (item["percent"] as? NSNumber)?.intValue ?? 0
                let severity = item["severity"] as? String ?? "normal"
                let resetsAt = (item["resets_at"] as? String).flatMap(parseDate)
                let title = titleFor(kind: kind, scope: item["scope"] as? [String: Any])
                limits.append(UsageLimit(kind: kind, title: title, percent: percent,
                                         severity: severity, resetsAt: resetsAt))
            }
        }

        // Fallback: derive from the top-level windows if `limits` is absent.
        if limits.isEmpty {
            if let l = window(root, "five_hour", "session", "Current session") { limits.append(l) }
            if let l = window(root, "seven_day", "weekly_all", "Current week (all models)") { limits.append(l) }
        }

        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, fetchedAt: Date())
    }

    private static func window(_ root: [String: Any], _ key: String,
                               _ kind: String, _ title: String) -> UsageLimit? {
        guard let obj = root[key] as? [String: Any],
              let util = (obj["utilization"] as? NSNumber)?.doubleValue else { return nil }
        return UsageLimit(kind: kind, title: title, percent: Int(util.rounded()),
                          severity: "normal",
                          resetsAt: (obj["resets_at"] as? String).flatMap(parseDate))
    }

    private static func titleFor(kind: String, scope: [String: Any]?) -> String {
        switch kind {
        case "session":    return "Current session"
        case "weekly_all": return "Current week (all models)"
        case "weekly_scoped":
            if let model = scope?["model"] as? [String: Any],
               let name = model["display_name"] as? String {
                return "Current week (\(name))"
            }
            return "Current week"
        default:           return kind
        }
    }

    // MARK: Dates

    private static let isoParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"   // handles "+00:00"
        return f
    }()

    /// Parses e.g. "2026-07-06T05:49:59.624980+00:00" (sub-second precision dropped).
    static func parseDate(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoParser.date(from: cleaned)
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
