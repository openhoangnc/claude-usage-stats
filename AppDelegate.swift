import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let panelView = UsagePanelView()

    private let client = UsageClient()
    private var timer: Timer?
    private let baseRefreshInterval: TimeInterval = 120   // 2 minutes base interval
    private var currentRefreshInterval: TimeInterval = 120

    private var lastRefreshAt: Date?
    private let menuRefreshThrottle: TimeInterval = 30   // skip the on-open auto-refresh if we just fetched

    private var lastSnapshot: UsageSnapshot?
    private var lastError: UsageError?

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
        statusView.update(session: nil, weekly: nil)
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
            case .success(let snapshot):
                self.lastSnapshot = snapshot
                self.lastError = nil
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
            }
            self.applyState()
        }
    }

    private func applyState() {
        statusView.update(session: lastSnapshot?.session, weekly: lastSnapshot?.weeklyAll)
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
