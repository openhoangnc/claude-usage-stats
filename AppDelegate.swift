import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let panelView = UsagePanelView()

    private let client = UsageClient()
    private var timer: Timer?
    // Usage changes slowly and opening the menu always refreshes on demand, so
    // the background timer can be gentle. Every `claude -p /usage` spawn is a
    // chance to collide with the user's real Claude sessions at the OAuth
    // token-refresh boundary, so we poll no more often than necessary.
    private let baseRefreshInterval: TimeInterval = 300    // 5 minutes when healthy
    private let maxRefreshInterval: TimeInterval = 1800    // cap for repeated transient failures
    private let authFailRefreshInterval: TimeInterval = 900 // signed-out: only re-login recovers, so wait
    private let partialRefreshInterval: TimeInterval = 60   // caught /usage mid-render: settles on its own
    private var currentRefreshInterval: TimeInterval = 300

    private var lastRefreshAt: Date?
    private let menuRefreshThrottle: TimeInterval = 30   // skip the on-open auto-refresh if we just fetched

    private let launchedAt = Date()
    private var lastSuccessAt: Date?
    /// When we last captured *every* window. Distinct from `lastSuccessAt`: it's
    /// how we tell a momentary mid-render partial from a `/usage` format change.
    private var lastCompleteAt: Date?
    private let staleThreshold: TimeInterval = 420   // warn if no fresh usage for 7 minutes

    private var lastSnapshot: UsageSnapshot?
    private var lastError: UsageError?

    /// Command to run when "Fix in Terminal…" is chosen; set while a menu is open.
    private var pendingSuggestedCommand: String?

    private let bundleId = "com.openhoangnc.claudeusagestats"
    private lazy var launchAgentPath =
        NSString(string: "~/Library/LaunchAgents/\(bundleId).plist").expandingTildeInPath

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon / Cmd-Tab entry
        if anotherInstanceIsAlreadyRunning() {
            // A copy is already in the menu bar (e.g. Launch-at-Login plus a
            // manual open). Hand off to it and quit so there's only one icon.
            NSApp.terminate(nil)
            return
        }
        setupStatusItem()
        enableLaunchAtLoginOnFirstRun()
        startTimer(interval: baseRefreshInterval)
        refresh()
    }

    /// True if another copy of this app (same bundle id) is already running.
    /// When two instances race to launch, the tie is broken deterministically by
    /// launch date (then pid) so exactly one survivor is kept — this instance
    /// quits only when a genuine elder exists.
    private func anotherInstanceIsAlreadyRunning() -> Bool {
        let me = NSRunningApplication.current
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return false }

        let myDate = me.launchDate ?? Date.distantFuture
        return others.contains { other in
            let otherDate = other.launchDate ?? Date.distantPast
            if otherDate != myDate { return otherDate < myDate }
            return other.processIdentifier < me.processIdentifier
        }
    }

    /// Turn on "Launch at Login" by default the first time the app ever runs,
    /// so a fresh install survives a reboot without the user finding the menu toggle.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didEnableLaunchAtLoginOnFirstRun"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: key) { return }
        defaults.set(true, forKey: key)
        if !isLaunchAtLoginEnabled {
            setLaunchAtLogin(true)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
        statusView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        statusView.onClick = { [weak self] in self?.showMenu() }
        statusView.onRightClick = { [weak self] in self?.showMenu() }
        statusView.onResize = { [weak self] width in self?.statusItem.length = width }

        if let button = statusItem.button {
            button.toolTip = "Claude Usage Stats"
            button.addSubview(statusView)
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
        }
        statusView.update(session: nil, weekly: nil, stale: false)
    }

    // MARK: Refresh

    private func startTimer(interval: TimeInterval) {
        timer?.invalidate()
        currentRefreshInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = interval * 0.2
    }

    private var loggedFirstResult = false

    @objc private func refresh() {
        lastRefreshAt = Date()
        client.fetch { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let snapshot) where !snapshot.isComplete:
                // `/usage` renders progressively, so this parsed cleanly but came
                // back short a window. Don't let it replace numbers we already
                // trust — dropping the weekly row from a panel that had one is
                // the bug this guards — and retry soon, since a mid-render
                // partial clears on the very next poll.
                self.lastError = nil
                let sinceComplete = Date().timeIntervalSince(self.lastCompleteAt ?? self.launchedAt)
                let raceIsLikely = sinceComplete < self.staleThreshold
                if !raceIsLikely || self.lastSnapshot?.isComplete != true {
                    // Either there's nothing better on screen, or partials have
                    // outlasted the staleness window — past which this isn't a
                    // render race but a CLI whose format changed (it has before).
                    // Take what we can get rather than freezing on old numbers.
                    self.lastSnapshot = snapshot
                    self.lastSuccessAt = snapshot.fetchedAt
                }
                NSLog("ClaudeUsageStats:partial usage — \(snapshot.limits.count) window(s), no weekly row")
                let retry = raceIsLikely ? self.partialRefreshInterval : self.baseRefreshInterval
                if self.currentRefreshInterval != retry {
                    self.startTimer(interval: retry)
                }

            case .success(let snapshot):
                self.lastSnapshot = snapshot
                self.lastError = nil
                self.lastSuccessAt = snapshot.fetchedAt
                self.lastCompleteAt = snapshot.fetchedAt
                if self.currentRefreshInterval != self.baseRefreshInterval {
                    self.startTimer(interval: self.baseRefreshInterval)
                }
                if !self.loggedFirstResult {
                    self.loggedFirstResult = true
                    let s = snapshot.session?.percent ?? -1
                    let w = snapshot.weeklyAll?.percent ?? -1
                    NSLog("ClaudeUsageStats:fetched OK — session=\(s)%% week=\(w)%% (\(snapshot.limits.count) windows)")
                }
            case .failure(let error):
                self.lastError = error   // keep last good numbers in the bar
                NSLog("ClaudeUsageStats:fetch failed — \(error.message)")
                self.backOffAfterFailure(error)
            }
            self.applyState()
        }
    }

    /// Widen the polling interval after a failed fetch so a broken state isn't
    /// hammered. A signed-out session only recovers when the user re-logs in, so
    /// we wait a long time (opening the menu or "Refresh Now" still retries at
    /// once); transient failures use plain exponential backoff up to a cap.
    private func backOffAfterFailure(_ error: UsageError) {
        let next: TimeInterval
        switch error {
        case .noCredentials, .sessionExpired:
            next = authFailRefreshInterval
        case .claudeCliNotInstalled, .unreadableUsage, .network:
            next = min(currentRefreshInterval * 2, maxRefreshInterval)
        }
        if next != currentRefreshInterval {
            startTimer(interval: next)
        }
    }

    /// True when the latest fetch failed *and* we've had no successful usage for
    /// longer than `staleThreshold` — i.e. we "could not get usage in the last 2
    /// minutes". Measured from the last success, or from launch if never. Gating
    /// on an actual error avoids a false warning during the timer's tolerance
    /// window, when healthy data can briefly age past the threshold.
    private var usageIsStale: Bool {
        guard lastError != nil else { return false }
        return Date().timeIntervalSince(lastSuccessAt ?? launchedAt) > staleThreshold
    }

    private func applyState() {
        statusView.update(session: lastSnapshot?.session,
                          weekly: lastSnapshot?.weeklyAll,
                          stale: usageIsStale)
        panelView.render(snapshot: lastSnapshot, error: lastError?.message)

        if let snapshot = lastSnapshot {
            let s = snapshot.session.map { "\($0.percent)%" } ?? "–"
            let w = snapshot.weeklyAll.map { "\($0.percent)%" } ?? "–"
            statusItem.button?.toolTip = "Claude Usage Stats — Session \(s) · Week \(w)"
        } else {
            statusItem.button?.toolTip = lastError?.message ?? "Claude Usage Stats"
        }
    }

    // MARK: Menu

    private func showMenu() {
        applyState()               // show the freshest data we have

        // Fetch again in the background, unless we just refreshed
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < menuRefreshThrottle {
            // recent enough; keep the current numbers
        } else {
            refresh()
        }

        let menu = NSMenu()

        let detail = NSMenuItem()
        detail.view = panelView
        menu.addItem(detail)
        menu.addItem(.separator())

        // When the current error has a fix (login / install), offer to run it.
        pendingSuggestedCommand = lastError?.suggestedCommand
        if let cmd = pendingSuggestedCommand {
            let fix = NSMenuItem(title: "Run “\(cmd)” in Terminal…",
                                 action: #selector(runSuggestedCommand), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
            menu.addItem(.separator())
        }

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let launch = NSMenuItem(title: "Launch at Login",
                                action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launch)

        let github = NSMenuItem(title: "GitHub Repository", action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claude Usage Stats", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/openhoangnc/claude-usage-stats") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launch the current error's suggested fix (e.g. `claude /login`) in a new
    /// Terminal window. The command runs in an interactive login shell, so the
    /// user's PATH resolves `claude` just as `claude /usage` would.
    @objc private func runSuggestedCommand() {
        guard let command = pendingSuggestedCommand else { return }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var scriptError: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&scriptError)
        if let scriptError = scriptError {
            NSLog("ClaudeUsageStats:runSuggestedCommand failed — \(scriptError)")
        }
    }

    // MARK: Launch at Login

    private var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let enable = !isLaunchAtLoginEnabled
        setLaunchAtLogin(enable)
        sender.state = enable ? .on : .off
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                return
            } catch {
                NSLog("SMAppService failed, using LaunchAgent fallback: \(error)")
            }
        }
        // Fallback for older systems / SMAppService failures.
        if enabled {
            let exec = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
                <key>Label</key><string>\(bundleId)</string>
                <key>ProgramArguments</key><array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            let dir = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        }
    }

    /// Called with --cleanup-login-item during uninstall.
    static func cleanupLoginItem() {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        let path = NSString(string: "~/Library/LaunchAgents/com.openhoangnc.claudeusagestats.plist").expandingTildeInPath
        try? FileManager.default.removeItem(atPath: path)
    }
}
