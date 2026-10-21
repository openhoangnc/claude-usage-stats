import AppKit
import CryptoKit

/// Self-update from this repo's GitHub Releases.
///
/// The release workflow publishes `ClaudeUsageStats.zip` (an ad-hoc signed
/// universal `.app`) on every release, and GitHub's API reports a SHA-256 digest
/// for each asset. An update is: fetch `releases/latest`, compare its tag with
/// our `CFBundleShortVersionString`, download the zip, check its digest, unpack
/// it next to the running bundle, sanity-check what came out, swap it into place
/// and hand over to the new bundle (see `relaunch`).
///
/// Only **release builds** check on their own. A local `./build.sh` stamps
/// version 1.0.0 into the bundle, so an automatic check would quietly replace a
/// developer's own build with the published one. The release workflow marks its
/// builds with `CUSReleaseBuild` in Info.plist; without it, only an explicit
/// "Check for Updates…" runs, and it asks before replacing anything.
final class Updater {

    struct Release {
        let version: String
        let zipURL: URL
        let sha256: String?
        let pageURL: URL
    }

    private let repo = "openhoangnc/claude-usage-stats"
    private let assetName = "ClaudeUsageStats.zip"
    private let checkInterval: TimeInterval = 24 * 60 * 60
    private let firstCheckDelay: TimeInterval = 60   // let the first usage fetch go first
    private let autoInstallKey = "autoInstallUpdates"

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let isReleaseBuild = Bundle.main.object(forInfoDictionaryKey: "CUSReleaseBuild") as? Bool == true

    /// A newer release we found but haven't installed (auto-install off, or it failed).
    private(set) var pendingRelease: Release?
    /// True while checking, downloading or installing; the menu greys out its items.
    private(set) var isBusy = false

    /// Called on the main thread whenever `pendingRelease` / `isBusy` change.
    var onChange: (() -> Void)?
    /// Asked before quitting for the new version; call the handler once it's
    /// safe to quit (no `claude` mid-fetch). Without it the app quits at once.
    var whenSafeToQuit: ((@escaping () -> Void) -> Void)?

    /// Passed, with our pid, to the copy an update starts; see `replacedPID`.
    static let replacingFlag = "--replacing"

    /// The pid of the old copy, when this one was started by an update. That
    /// copy quits once this one has finished launching, so it must be waited
    /// out rather than treated as another instance.
    static let replacedPID: pid_t? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: replacingFlag), i + 1 < args.count else { return nil }
        return pid_t(args[i + 1])
    }()

    private var timer: Timer?

    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: autoInstallKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoInstallKey) }
    }

    func start() {
        guard isReleaseBuild else {
            NSLog("ClaudeUsageStats:updater — local build, automatic update checks off")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + firstCheckDelay) { [weak self] in
            self?.checkInBackground()
        }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkInBackground()
        }
        timer?.tolerance = 60 * 60
    }

    // MARK: Checking

    /// Silent check: logs failures, installs straight away if auto-install is on.
    private func checkInBackground() {
        guard !isBusy else { return }
        setBusy(true)
        fetchLatest { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error):
                NSLog("ClaudeUsageStats:update check failed — \(error.localizedDescription)")
            case .success(let release):
                guard let release = release else { return }
                self.pendingRelease = release
                self.onChange?()
                NSLog("ClaudeUsageStats:update \(release.version) available (have \(self.currentVersion))")
                if self.autoInstall { self.install(release, userInitiated: false) }
            }
        }
    }

    /// "Check for Updates…": always answers with an alert.
    func checkNow() {
        guard !isBusy else { return }
        setBusy(true)
        fetchLatest { [weak self] result in
            guard let self = self else { return }
            self.setBusy(false)
            switch result {
            case .failure(let error):
                self.alert("Couldn't check for updates", error.localizedDescription)
            case .success(nil):
                self.pendingRelease = nil
                self.onChange?()
                self.alert("You're up to date",
                           "Claude Usage Stats \(self.currentVersion) is the latest version.")
            case .success(let release?):
                self.pendingRelease = release
                self.onChange?()
                self.offerInstall(release)
            }
        }
    }

    /// "Install Update…" from the menu, for a release a background check already found.
    func installPending() {
        guard let release = pendingRelease, !isBusy else { return }
        offerInstall(release)
    }

    private func offerInstall(_ release: Release) {
        let local = isReleaseBuild ? "" :
            "\n\nThis copy was built locally; installing replaces it with the published build."
        let choice = ask("Claude Usage Stats \(release.version) is available",
                         "You have \(currentVersion). Install it now? The app relaunches when done.\(local)",
                         buttons: ["Install and Relaunch", "Release Notes", "Later"])
        switch choice {
        case .alertFirstButtonReturn:  install(release, userInitiated: true)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    /// `nil` when the latest release is not newer than this build.
    private func fetchLatest(completion: @escaping (Result<Release?, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageStats/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error> = Result {
                if let error = error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data = data else {
                    throw UpdateError("GitHub returned HTTP \(status).")
                }
                return try self.parseRelease(data)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func parseRelease(_ data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError("Unexpected response from GitHub.")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Updater.isVersion(version, newerThan: currentVersion) else { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { $0["name"] as? String == assetName }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else {
            throw UpdateError("Release \(tag) has no \(assetName).")
        }
        // GitHub reports "sha256:<hex>" for assets uploaded since mid-2025.
        let digest = (asset["digest"] as? String).flatMap { d -> String? in
            d.hasPrefix("sha256:") ? String(d.dropFirst("sha256:".count)).lowercased() : nil
        }
        return Release(version: version, zipURL: zip, sha256: digest, pageURL: page)
    }

    /// Numeric dotted-version comparison ("1.0.10" > "1.0.9").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    private func install(_ release: Release, userInitiated: Bool) {
        guard !isBusy else { return }
        setBusy(true)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.downloadAndSwap(release) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    NSLog("ClaudeUsageStats:updated to \(release.version), relaunching")
                    self.pendingRelease = nil
                    self.onChange?()
                    self.relaunch(release, userInitiated: userInitiated)   // stays busy until we quit
                case .failure(let error):
                    self.setBusy(false)
                    NSLog("ClaudeUsageStats:update to \(release.version) failed — \(error.localizedDescription)")
                    if userInitiated {
                        let choice = self.ask("Couldn't install the update", error.localizedDescription,
                                              buttons: ["Download Manually", "Cancel"])
                        if choice == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
                    }
                }
            }
        }
    }

    /// Runs off the main thread. Leaves the running bundle untouched on any failure.
    private func downloadAndSwap(_ release: Release) throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            throw UpdateError("Not running from an app bundle.")
        }
        guard !appURL.path.contains("/AppTranslocation/") else {
            throw UpdateError("macOS is running the app from a temporary location. Move it to /Applications and reopen it.")
        }
        let parent = appURL.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError("No permission to replace the app in \(parent.path).")
        }

        // A scratch directory on the same volume as the bundle, so the final swap
        // is a rename rather than a copy.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: appURL, create: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent(assetName)
        try download(release.zipURL, to: zip)

        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                throw UpdateError("The download is corrupted (checksum mismatch).")
            }
        }

        let unpacked = work.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], "Couldn't unpack the update.")
        let newApp = unpacked.appendingPathComponent(appURL.lastPathComponent)

        // What came out must be this app, at the version we were promised, with
        // an intact signature — otherwise don't touch the installed copy.
        guard let info = Bundle(url: newApp)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The downloaded app isn't the expected version of Claude Usage Stats.")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path],
                "The downloaded app's signature is invalid.")
        // URLSession doesn't quarantine, but strip it anyway: an ad-hoc signed
        // app carrying the flag is refused by Gatekeeper on relaunch.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path], "")

        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
    }

    private func download(_ url: URL, to destination: URL) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { done.signal() }
            do {
                if let error = error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let location = location else {
                    throw UpdateError("Download failed (HTTP \(status)).")
                }
                // The temp file is deleted when this handler returns; move it now.
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }.resume()
        done.wait()
        if let failure = failure { throw failure }
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String], _ message: String) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw UpdateError(message) }
        return task.terminationStatus
    }

    /// How long the new copy may take to finish launching before we give up on
    /// handing over and keep running the old code.
    private let handOverTimeout: TimeInterval = 180

    /// Start the (now replaced) bundle as a second instance, and quit only once
    /// it has finished launching; it waits for us to exit before it shows its
    /// icon (`replacedPID`).
    ///
    /// Quitting first and reopening after left the menu bar empty for as long
    /// as macOS took over the first launch of the new binary: the swapped
    /// bundle goes through CoreServicesUIAgent and a Gatekeeper scan, which
    /// took 30s on a busy Mac. It looked as if the app had quit for good.
    private func relaunch(_ release: Release, userInitiated: Bool) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true   // never just activate us
        config.activates = false
        config.addsToRecentItems = false
        config.arguments = [Updater.replacingFlag, String(ProcessInfo.processInfo.processIdentifier)]

        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { app, error in
            DispatchQueue.main.async {
                guard let app = app else {
                    self.handOverFailed(release, userInitiated: userInitiated,
                                        reason: error?.localizedDescription ?? "it didn't start")
                    return
                }
                let deadline = Date().addingTimeInterval(self.handOverTimeout)
                func poll() {
                    if app.isTerminated {
                        return self.handOverFailed(release, userInitiated: userInitiated, reason: "it quit while starting")
                    }
                    if !app.isFinishedLaunching {
                        if Date() > deadline {
                            return self.handOverFailed(release, userInitiated: userInitiated, reason: "it took too long to start")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: poll)
                        return
                    }
                    NSLog("ClaudeUsageStats:\(release.version) is up (pid \(app.processIdentifier)), quitting")
                    let quit = { NSApp.terminate(nil) }
                    if let wait = self.whenSafeToQuit { wait(quit) } else { quit() }
                }
                poll()
            }
        }
    }

    /// The new bundle is on disk but didn't take over: keep running the old
    /// code, which still works, and let the next launch pick the update up.
    private func handOverFailed(_ release: Release, userInitiated: Bool, reason: String) {
        NSLog("ClaudeUsageStats:relaunch into \(release.version) failed — \(reason); the update applies on next launch")
        setBusy(false)
        if userInitiated {
            alert("Claude Usage Stats \(release.version) is installed",
                  "It couldn't restart on its own (\(reason)). Quit Claude Usage Stats and open it again to finish.")
        }
    }

    // MARK: Helpers

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        onChange?()
    }

    private func alert(_ title: String, _ text: String) {
        _ = ask(title, text, buttons: ["OK"])
    }

    private func ask(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        // An accessory (menu-bar-only) app must activate, or the alert opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
