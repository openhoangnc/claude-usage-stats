import Foundation
import Darwin   // openpty, poll, read/write, kill — for driving the interactive CLI

// MARK: - Models

/// One rate-limit window as returned by the Claude usage endpoint.
struct UsageLimit {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped"
    let title: String       // display title, e.g. "Current week (Fable)"
    let percent: Int        // 0...100 (may exceed 100 on overage)
    let severity: String    // "normal" | "warning" | "critical" | ...
    let resetsAt: Date?
}

extension UsageLimit {
    /// How long this limit's window runs for.
    ///
    /// `/usage` reports only when a window resets, never when it opened, so the
    /// start has to be inferred as `resetsAt - windowLength`. These lengths are
    /// therefore an assumption about the plan, not a reading from the CLI: if a
    /// window's duration ever changes, the elapsed marker drifts silently.
    var windowLength: TimeInterval? {
        switch kind {
        case "session":                    return 5 * 3600
        case "weekly_all", "weekly_scoped": return 7 * 24 * 3600
        default:                           return nil
        }
    }

    /// Fraction of the window already elapsed (0...1), or nil when it can't be
    /// derived. Clamped, since a stale `resetsAt` can sit outside the window.
    func elapsedFraction(now: Date = Date()) -> Double? {
        guard let resetsAt, let length = windowLength, length > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        return min(max(1 - remaining / length, 0), 1)
    }
}

/// A full snapshot of usage at a point in time.
struct UsageSnapshot {
    let limits: [UsageLimit]        // in display order (session, weekly_all, weekly_scoped)
    let fetchedAt: Date

    var session: UsageLimit?   { limits.first { $0.kind == "session" } }
    var weeklyAll: UsageLimit? { limits.first { $0.kind == "weekly_all" } }

    /// True once every window the menu bar and panel show has been captured.
    ///
    /// `/usage` renders progressively — the session bar is drawn from local
    /// state, while the weekly rows wait on the usage endpoint — so a capture
    /// taken too early parses perfectly but is simply missing windows. Callers
    /// must not treat such a snapshot as a result: it is indistinguishable from
    /// a real one downstream, which is how the weekly row went missing.
    var isComplete: Bool { session != nil && weeklyAll != nil }
}

enum UsageError: Error {
    case claudeCliNotInstalled
    /// Also covers a `/usage` we simply couldn't read: when neither the
    /// headless nor the interactive capture yields a single limit row, the
    /// overwhelmingly common cause is a CLI sitting on a login/onboarding
    /// screen whose wording `isAuthError` doesn't happen to match, so the app
    /// asks for a sign-in rather than reporting an unactionable parse failure.
    case noCredentials
    case sessionExpired
    case network(String)

    var message: String {
        switch self {
        case .claudeCliNotInstalled: return "Claude CLI not found — run: npm i -g @anthropic-ai/claude-code"
        case .noCredentials:         return "Not signed in — run: claude /login"
        case .sessionExpired:        return "Session may have expired — run: claude /login"
        case .network(let m):        return m
        }
    }

    /// A one-shot shell command that resolves this error, if any. Surfaced as a
    /// menu item the user can launch in Terminal.
    var suggestedCommand: String? {
        switch self {
        case .claudeCliNotInstalled:            return "npm i -g @anthropic-ai/claude-code"
        case .noCredentials, .sessionExpired:   return "claude /login"
        case .network:                          return nil
        }
    }
}

// MARK: - Client

/// Fetches usage limits from the local `claude` CLI, cheapest source first:
///
///  1. **`claude -p /usage`** — a fast, headless, side-effect-free call. On CLI
///     versions that print the limit bars this is all we need.
///  2. **Interactive fallback** — if `-p` doesn't contain the bars (a 2.x CLI
///     change dropped them from headless output), drive the TUI under a
///     pseudo-terminal: launch `claude`, send `/usage`, scrape the rendered
///     bars, then quit before any conversation turn (so nothing is persisted —
///     no transcript, and the poll doesn't pollute the usage stats it reads).
///
/// The interactive view's bars come from a rate-limited usage endpoint, so we
/// prefer `-p` and treat a rate-limit as a transient back-off, not an error.
/// Fetches are single-flighted so background polling never runs two `claude`
/// processes at once (overlapping runs could race to rotate the shared OAuth
/// token, which is what forced the daily re-login).
final class UsageClient {

    /// Hard ceiling for a single interactive fetch. Startup + `/usage` render is
    /// typically ~3s; if the CLI hangs we kill it well before this so slow runs
    /// can't pile up. A lingering `claude` is one more process that could race
    /// to refresh (and rotate) the shared OAuth token.
    private let processTimeout: TimeInterval = 40

    /// How long the TUI must stop painting before a capture is judged finished.
    /// The panel repaints as the usage endpoint refines its numbers, so reading
    /// it too eagerly catches a half-drawn frame.
    private let settleTime: TimeInterval = 1.5

    /// The interactive TUI is launched trimmed down: no user MCP servers, no
    /// Chrome bridge, no auto-update or non-essential model calls, and kept out
    /// of usage attribution — so a poll is fast and side-effect-free.
    private let claudeArgs = ["--strict-mcp-config", "--no-chrome"]
    private let extraEnv = [
        "TERM": "xterm-256color",
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1",
        "CLAUDE_CODE_SUPPRESS_SESSION_ATTRIBUTION": "1",
    ]

    // Single-flight state. All access is guarded by `stateLock`.
    private let stateLock = NSLock()
    private var isFetching = false
    private var waiters: [(Result<UsageSnapshot, UsageError>) -> Void] = []

    /// Fetch a fresh snapshot. `completion` is always called on the main thread.
    ///
    /// Calls are **coalesced**: if a fetch is already running, this completion
    /// is attached to it rather than launching a second `claude`. The timer,
    /// menu-open, and "Refresh Now" can therefore all fire freely without ever
    /// producing two concurrent `claude` processes that would race to rotate the
    /// OAuth refresh token.
    func fetch(completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        stateLock.lock()
        waiters.append(completion)
        if isFetching {
            stateLock.unlock()   // an in-flight run will serve this caller too
            return
        }
        isFetching = true
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            autoreleasepool {
                let result = self.runFetch()
                self.deliver(result)
            }
        }
    }

    /// Try the cheap headless path first, then fall back to the interactive TUI.
    private func runFetch() -> Result<UsageSnapshot, UsageError> {
        // Locate `claude` the way the user's terminal does. If it can't be
        // found the CLI isn't installed (or isn't on any login PATH).
        guard let resolution = PathResolver.resolve() else {
            return .failure(.claudeCliNotInstalled)
        }
        let claude = resolution.claude, path = resolution.path

        // 1. Headless `claude -p /usage`. Cheap and doesn't touch the
        //    rate-limited usage endpoint. Works whenever `-p` includes the bars.
        let printOut = capturePrintUsage(claude: claude, path: path)
        let printSnapshot = Self.parseCLIOutput(printOut)
        if let snapshot = printSnapshot, snapshot.isComplete {
            return .success(snapshot)
        }
        if printOut.contains("command not found") {
            return .failure(.claudeCliNotInstalled)
        }
        if Self.isAuthError(printOut) {
            return .failure(.noCredentials)
        }

        // 2. Interactive fallback: scrape the bars from the TUI. Also reached
        //    when `-p` parsed but came back short a window, since the TUI may
        //    still render the rest.
        switch driveInteractiveUsage(claude: claude, path: path) {
        case .launchFailed:
            return printSnapshot.map { .success($0) }
                ?? .failure(.network("Couldn’t launch the Claude CLI"))
        case .rateLimited:
            // Transient: keep the last good numbers and back off, don't alarm.
            return .failure(.network("Usage endpoint is rate limited — retrying"))
        case .captured(let output):
            let tuiSnapshot = Self.parseCLIOutput(output)
            if let snapshot = tuiSnapshot, snapshot.isComplete {
                return .success(snapshot)
            }
            // Neither source rendered every window. Ship whichever saw more —
            // it may genuinely be all this account has — but it carries
            // `isComplete == false`, so the caller keeps numbers it already
            // trusts instead of dropping a window from the panel.
            let partials = [printSnapshot, tuiSnapshot].compactMap { $0 }
            if let best = partials.max(by: { $0.limits.count < $1.limits.count }) {
                return .success(best)
            }
            // No bars at all, from either source. Treat every such capture as
            // "sign in required": a CLI parked on a login/onboarding screen is
            // by far the likeliest reason both captures came back bare, and its
            // wording changes often enough that `isAuthError` can't be trusted
            // to recognise it. `claude /login` is then the one actionable fix
            // we can offer — a bare "couldn't read usage" leaves the user with
            // nothing to do.
            return .failure(.noCredentials)
        }
    }

    /// Run `claude -p /usage` and return its combined stdout+stderr. Empty on a
    /// launch failure. Bounded by a timeout so a hung CLI can't block the poll.
    private func capturePrintUsage(claude: String, path: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: claude)
        task.arguments = ["-p", "/usage"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for (k, v) in extraEnv where k != "TERM" { env[k] = v }
        task.environment = env
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.standardInput = FileHandle.nullDevice

        do { try task.run() } catch { return "" }

        let killer = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: killer)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        killer.cancel()

        return String(decoding: outData, as: UTF8.self) + "\n" + String(decoding: errData, as: UTF8.self)
    }

    /// Outcome of one interactive `/usage` scrape.
    private enum InteractiveResult {
        case launchFailed
        case rateLimited
        case captured(String)   // ANSI-stripped screen text
    }

    /// Launch `claude` under a PTY, send `/usage`, capture the rendered screen,
    /// then quit.
    private func driveInteractiveUsage(claude: String, path: String) -> InteractiveResult {
        var master: Int32 = 0
        var slave: Int32 = 0
        var win = winsize(ws_row: 45, ws_col: 130, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &win) == 0 else { return .launchFailed }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: claude)
        task.arguments = claudeArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for (k, v) in extraEnv { env[k] = v }
        task.environment = env
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        task.standardInput = slaveHandle
        task.standardOutput = slaveHandle
        task.standardError = slaveHandle

        do {
            try task.run()
        } catch {
            close(master); close(slave)
            return .launchFailed
        }
        close(slave)   // the child holds its own dup'd copies

        func send(_ s: String) {
            let bytes = Array(s.utf8)
            _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, bytes.count) }
        }

        var buf = Data()
        let start = Date()
        var lastData = start
        var sentUsage = false
        var usageAt: Date?
        var handledTrust = false
        var rateLimited = false
        var lastParsedCount = -1   // re-parse for completeness only when new bytes arrive
        let cap = 65536
        let readBuf = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 1)
        defer { readBuf.deallocate() }

        while Date().timeIntervalSince(start) < processTimeout {
            var fds = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fds, 1, 200)
            let now = Date()
            if ready > 0 && (fds.revents & Int16(POLLIN)) != 0 {
                let n = read(master, readBuf, cap)
                if n <= 0 { break }   // EOF: the CLI exited
                buf.append(readBuf.assumingMemoryBound(to: UInt8.self), count: n)
                lastData = now
                if buf.count > 1_048_576 { break }   // safety cap
            }
            let text = Self.stripANSI(buf)
            // Judge the *current* screen from the tail — the buffer is cumulative,
            // so searching all of it would keep matching stale frames.
            let recent = String(text.suffix(3000)).lowercased()
            let quiet = now.timeIntervalSince(lastData)

            if !sentUsage {
                // A fresh working dir can trigger a "trust this folder?" prompt;
                // accept it (our empty temp dir is harmless) so we reach the TUI.
                if !handledTrust && (recent.contains("do you trust") ||
                                     recent.contains("trust the files") ||
                                     recent.contains("trust this folder")) {
                    send("\r")
                    handledTrust = true
                    lastData = now
                    continue
                }
                // Send `/usage` only once the input prompt is actually up — a
                // premature send is dropped and yields an empty capture. Fall
                // back to a time bound if the ready marker never appears.
                let promptReady = recent.contains("❯") || recent.contains("for shortcuts") || recent.contains("auto mode")
                let elapsed = now.timeIntervalSince(start)
                if buf.count > 150 && quiet > 0.8 && (promptReady || elapsed > 6) {
                    send("/usage\r")
                    sentUsage = true
                    usageAt = now
                }
            } else {
                // The bars come from the usage endpoint; if it's throttled the
                // panel says so. Bail immediately — it's transient, not our bug.
                if recent.contains("rate limited") || recent.contains("try again in a moment") {
                    rateLimited = true
                    break
                }
                // Done once every window has rendered *and* the screen has gone
                // quiet. Counting "Resets" over the cumulative buffer counted
                // the same block twice across repaints, so a session bar that
                // repainted before the weekly rows arrived ended the capture
                // early — leaving the session-only, reset-less panel this
                // replaces. Parsing is the same completeness test the result is
                // judged by, and it merges frames, so repaints can't fool it.
                //
                // Settling matters beyond that: the scoped row ("Current week
                // (Fable)") paints last and carries no reset line of its own, so
                // breaking the instant the weekly row lands can still clip it.
                if quiet > settleTime && buf.count != lastParsedCount {
                    lastParsedCount = buf.count
                    if Self.parseCLIOutput(text)?.isComplete == true { break }
                }
                if let u = usageAt, now.timeIntervalSince(u) > 14 { break }   // gave up waiting
            }
        }

        // Ask the TUI to exit, then make sure the process is gone.
        send("\u{03}")            // Ctrl-C
        usleep(150_000)
        send("\u{03}")
        let killDeadline = Date().addingTimeInterval(2)
        while task.isRunning && Date() < killDeadline { usleep(50_000) }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        task.waitUntilExit()
        close(master)

        return rateLimited ? .rateLimited : .captured(Self.stripANSI(buf))
    }

    /// Remove ANSI/VT escape sequences and normalise carriage returns so the TUI
    /// capture can be parsed as plain lines.
    static func stripANSI(_ data: Data) -> String {
        var t = String(decoding: data, as: UTF8.self)
        t = t.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\u{1b}[=>PMc]", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "\r", with: "\n")
    }

    /// Deliver `result` to every waiter and clear the in-flight flag so the next
    /// `fetch` can start a fresh run.
    private func deliver(_ result: Result<UsageSnapshot, UsageError>) {
        stateLock.lock()
        let callbacks = waiters
        waiters.removeAll()
        isFetching = false
        stateLock.unlock()

        DispatchQueue.main.async {
            for callback in callbacks { callback(result) }
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

    // MARK: Parsing

    /// Parse a `/usage` capture into a snapshot, accepting either layout:
    /// the interactive multi-line blocks (current CLI) or the legacy one-line
    /// `"Current session: N% used · resets …"` rows that older `-p /usage`
    /// printed. Returns `nil` if neither yields any limit rows.
    static func parseCLIOutput(_ text: String) -> UsageSnapshot? {
        return parseBlocks(text) ?? parseLegacyLines(text)
    }

    /// Interactive layout — each limit window renders as a three-line block:
    ///
    ///     Current session
    ///     ██████████████         71% used
    ///     Resets 7pm (Asia/Saigon)
    ///
    /// The panel repaints several times while it loads (numbers refine as it
    /// scans), so we keep the **last** value seen for each title.
    private static func parseBlocks(_ text: String) -> UsageSnapshot? {
        let lines = text.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var order: [String] = []                 // titles in first-seen order
        var byTitle: [String: UsageLimit] = [:]   // freshest value per title

        var i = 0
        while i < lines.count {
            guard let title = titleForLine(lines[i]) else { i += 1; continue }

            // Look at the next few lines for this block's percent and reset.
            var percent: Int? = nil
            var resetsAt: Date? = nil
            var j = i + 1
            var scanned = 0
            while j < lines.count && scanned < 5 {
                if titleForLine(lines[j]) != nil { break }   // next block started
                if percent == nil { percent = percentUsed(in: lines[j]) }
                if lines[j].lowercased().hasPrefix("resets") {
                    resetsAt = parseCLIDate(lines[j])
                    j += 1
                    break
                }
                j += 1; scanned += 1
            }

            if let percent = percent {
                let severity = percent >= 90 ? "critical" : (percent >= 75 ? "warning" : "normal")
                // Keep the freshest percent, but a repaint that hasn't drawn its
                // reset line yet must not erase a reset we already scraped —
                // that's what left the panel saying "Reset time unknown".
                let limit = UsageLimit(kind: kindForTitle(title), title: title,
                                       percent: percent, severity: severity,
                                       resetsAt: resetsAt ?? byTitle[title]?.resetsAt)
                if byTitle[title] == nil { order.append(title) }
                byTitle[title] = limit
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }

        let limits = order.compactMap { byTitle[$0] }
        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, fetchedAt: Date())
    }

    /// Legacy one-line layout that older `claude -p /usage` printed:
    /// `"Current session: 2% used · resets Jul 7 at 1:59pm (Asia/Saigon)"`.
    private static func parseLegacyLines(_ text: String) -> UsageSnapshot? {
        var limits: [UsageLimit] = []
        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("%") && trimmed.lowercased().contains("used") else { continue }

            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let title = parts[0].trimmingCharacters(in: .whitespaces)
            guard let _ = titleForLine(title) else { continue }   // only real windows

            let rightParts = parts[1].components(separatedBy: "·")
            guard let percent = percentUsed(in: rightParts[0]) else { continue }
            let resetsAt = rightParts.count >= 2 ? parseCLIDate(rightParts[1]) : nil

            let severity = percent >= 90 ? "critical" : (percent >= 75 ? "warning" : "normal")
            limits.append(UsageLimit(kind: kindForTitle(title), title: title,
                                     percent: percent, severity: severity, resetsAt: resetsAt))
        }
        guard !limits.isEmpty else { return nil }
        return UsageSnapshot(limits: limits, fetchedAt: Date())
    }

    /// The canonical title if `line` is a usage-window header, else `nil`.
    /// Guards on length so prose merely containing the words isn't matched, and
    /// on `%` because a block header carries the title alone — a line like
    /// `"Current week (Fable): 0% used"` is a *legacy row*, and matching it here
    /// made `parseBlocks` claim the output and swallow the session row with it.
    private static func titleForLine(_ line: String) -> String? {
        guard line.count <= 40, !line.contains("%") else { return nil }
        let low = line.lowercased()
        if low.hasPrefix("current session") { return "Current session" }
        if low.hasPrefix("current week")    { return line }   // keep "(all models)"/"(Fable)"
        return nil
    }

    private static func kindForTitle(_ title: String) -> String {
        let low = title.lowercased()
        if low.contains("session")    { return "session" }
        if low.contains("all models") { return "weekly_all" }
        return "weekly_scoped"
    }

    /// The integer N from an `"N% used"` (or `"N%used"`) fragment, else `nil`.
    /// Requires the `used` suffix so "66% of your usage…" prose doesn't match.
    private static func percentUsed(in line: String) -> Int? {
        guard let r = line.range(of: "[0-9]{1,3}%[ ]*used", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let digits = line[r].prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: Dates

    /// Parse a reset string into a `Date`. Handles both the dated form
    /// ("Resets Jul 15 at 6am (Asia/Saigon)") and the same-day, time-only form
    /// ("Resets 7pm (Asia/Saigon)") the interactive view uses. `nil` if neither
    /// matches — the panel then just shows "Reset time unknown".
    static func parseCLIDate(_ s: String) -> Date? {
        var cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip a leading "resets" (any case).
        if cleaned.lowercased().hasPrefix("resets") {
            cleaned = String(cleaned.dropFirst("resets".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract timezone if present in parentheses.
        var tz: TimeZone? = nil
        if let openParen = cleaned.firstIndex(of: "("),
           let closeParen = cleaned.firstIndex(of: ")"),
           openParen < closeParen {
            let tzStr = String(cleaned[cleaned.index(after: openParen)..<closeParen])
            tz = TimeZone(identifier: tzStr)
            cleaned = String(cleaned[..<openParen]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let zone = tz ?? .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone

        // Dated form: month/day + time, no year (DateFormatter defaults to 2000).
        let dated = ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d 'at' h:mm a", "MMM d 'at' h a"]
        for format in dated {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                return applyCurrentYear(to: date, zone: zone)
            }
        }

        // Same-day time-only form: attach today's date (next day if already past).
        let timeOnly = ["h:mma", "ha", "h:mm a", "h a"]
        for format in timeOnly {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone
                let hm = cal.dateComponents([.hour, .minute], from: date)
                var comp = cal.dateComponents([.year, .month, .day], from: Date())
                comp.hour = hm.hour; comp.minute = hm.minute; comp.second = 0
                comp.timeZone = zone
                guard var result = cal.date(from: comp) else { return nil }
                if result.timeIntervalSinceNow < -60 {
                    result = cal.date(byAdding: .day, value: 1, to: result) ?? result
                }
                return result
            }
        }

        return nil
    }

    /// Stamp a month/day-only parse with the current year, nudging across a
    /// new-year boundary if that lands the date implausibly far from now.
    private static func applyCurrentYear(to date: Date, zone: TimeZone) -> Date? {
        let currentYear = Calendar.current.component(.year, from: Date())
        let parsedComp = Calendar.current.dateComponents(in: zone, from: date)

        var comp = DateComponents()
        comp.timeZone = zone
        comp.year = currentYear
        comp.month = parsedComp.month
        comp.day = parsedComp.day
        comp.hour = parsedComp.hour
        comp.minute = parsedComp.minute
        comp.second = parsedComp.second

        guard let resultDate = Calendar.current.date(from: comp) else { return date }
        if resultDate.timeIntervalSinceNow < -86400 * 180 {
            comp.year = currentYear + 1
            return Calendar.current.date(from: comp)
        } else if resultDate.timeIntervalSinceNow > 86400 * 180 {
            comp.year = currentYear - 1
            return Calendar.current.date(from: comp)
        }
        return resultDate
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
