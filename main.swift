import AppKit

if CommandLine.arguments.contains("--cleanup-login-item") ||
   CommandLine.arguments.contains("--uninstall") {
    AppDelegate.cleanupLoginItem()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--screenshot") {
    let out = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "screenshot.png"
    ScreenshotMaker.write(to: out)
    exit(0)
}

// Headless verification: performs one real fetch/parse/format and prints the
// exact text the menu bar and detail panel would show, then exits.
if CommandLine.arguments.contains("--selftest") {
    var done = false
    var code: Int32 = 1
    UsageClient().fetch { result in
        switch result {
        case .success(let s):
            let sv = s.session.map { "\($0.percent)%" } ?? "··"
            let wv = s.weeklyAll.map { "\($0.percent)%" } ?? "··"
            print("MENUBAR   S \(sv)  /  W \(wv)\n")
            print("PANEL (detail):")
            for l in s.limits {
                print("  \(l.title)")
                print("    \(l.percent)% used   [severity: \(l.severity)]")
                print("    \(l.resetsAt.map(UsageFormat.reset) ?? "reset unknown")\n")
            }
            print("  Updated \(UsageFormat.ago(s.fetchedAt))")
            code = 0
        case .failure(let e):
            print("SELFTEST FAILED: \(e.message)")
        }
        done = true
    }
    let deadline = Date().addingTimeInterval(20)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
