import AppKit

/// Renders a marketing screenshot using the real menu-bar and panel views, so
/// the image always matches what the app actually draws. Invoked via
/// `ClaudeUsageStats --screenshot <out.png>`.
enum ScreenshotMaker {

    static func write(to path: String) {
        _ = NSApplication.shared

        let W: CGFloat = 540, H: CGFloat = 316, menubarH: CGFloat = 30

        let now = Date()
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: "session", title: "Current session",
                       percent: 49, severity: "normal",
                       resetsAt: now.addingTimeInterval(1 * 3600 + 21 * 60)),
            UsageLimit(kind: "weekly_all", title: "Current week (all models)",
                       percent: 57, severity: "normal",
                       resetsAt: now.addingTimeInterval(42 * 3600)),
            UsageLimit(kind: "weekly_scoped", title: "Current week (Fable)",
                       percent: 79, severity: "warning",
                       resetsAt: now.addingTimeInterval(42 * 3600)),
        ], fetchedAt: now)

        let dark = NSAppearance(named: .darkAqua)

        let status = StatusBarView(frame: NSRect(x: 0, y: 0, width: 40, height: 22))
        status.appearance = dark
        status.update(session: snapshot.session, weekly: snapshot.weeklyAll)
        let sw = status.preferredWidth

        let panel = UsagePanelView()
        panel.appearance = dark
        panel.render(snapshot: snapshot, error: nil)
        let pSize = panel.frame.size

        let statusFrame = NSRect(x: W - 14 - sw, y: (menubarH - 22) / 2, width: sw, height: 22)
        let panelFrame = NSRect(x: W - 16 - pSize.width, y: menubarH + 14,
                                width: pSize.width, height: pSize.height)

        let container = ScreenshotBackground(frame: NSRect(x: 0, y: 0, width: W, height: H))
        container.appearance = dark
        container.menubarH = menubarH
        container.statusFrame = statusFrame
        container.panelFrame = panelFrame

        status.frame = statusFrame
        panel.frame = panelFrame
        container.addSubview(status)
        container.addSubview(panel)

        let window = NSWindow(contentRect: container.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = dark
        window.contentView = container
        container.displayIfNeeded()

        // Render at 2x for a crisp image.
        let scale = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(W) * scale, pixelsHigh: Int(H) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        container.cacheDisplay(in: container.bounds, to: rep)

        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

/// Draws the desktop + menu-bar chrome and the panel's dark background behind
/// the real subviews.
final class ScreenshotBackground: NSView {
    var menubarH: CGFloat = 30
    var statusFrame: NSRect = .zero
    var panelFrame: NSRect = .zero

    override var isFlipped: Bool { true }

    private func rrect(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.059, green: 0.094, blue: 0.149, alpha: 1).setFill()   // desktop
        bounds.fill()

        NSColor(srgbRed: 0.117, green: 0.117, blue: 0.122, alpha: 1).setFill()   // menu bar
        NSRect(x: 0, y: 0, width: bounds.width, height: menubarH).fill()

        // Clock + battery to the left of the indicator.
        let clock = NSAttributedString(string: "9:41", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(white: 0.90, alpha: 1),
        ])
        let batteryX = statusFrame.minX - 36
        clock.draw(at: NSPoint(x: batteryX - 12 - clock.size().width, y: (menubarH - 16) / 2))

        let gray = NSColor(white: 0.78, alpha: 1)
        gray.setStroke()
        let body = rrect(NSRect(x: batteryX, y: menubarH / 2 - 5.5, width: 22, height: 11), 2.5)
        body.lineWidth = 1
        body.stroke()
        gray.setFill()
        rrect(NSRect(x: batteryX + 2, y: menubarH / 2 - 3.5, width: 12, height: 7), 1).fill()
        rrect(NSRect(x: batteryX + 22.5, y: menubarH / 2 - 2.5, width: 2, height: 5), 1).fill()

        // Highlight behind the menu-bar indicator (as if hovered/open).
        NSColor(white: 1, alpha: 0.10).setFill()
        rrect(statusFrame.insetBy(dx: -6, dy: -3), 6).fill()

        // Panel background + hairline border.
        let panelBg = NSColor(srgbRed: 0.149, green: 0.149, blue: 0.165, alpha: 1)
        panelBg.setFill()
        let p = rrect(panelFrame, 12)
        p.fill()
        NSColor(white: 1, alpha: 0.09).setStroke()
        p.lineWidth = 1
        p.stroke()

        // Caret from the indicator down to the panel.
        panelBg.setFill()
        let caret = NSBezierPath()
        caret.move(to: NSPoint(x: statusFrame.midX - 6, y: panelFrame.minY))
        caret.line(to: NSPoint(x: statusFrame.midX + 6, y: panelFrame.minY))
        caret.line(to: NSPoint(x: statusFrame.midX, y: panelFrame.minY - 7))
        caret.close()
        caret.fill()
    }
}
