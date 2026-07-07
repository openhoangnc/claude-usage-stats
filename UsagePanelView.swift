import AppKit

/// The detail panel shown as the top item of the menu — replicates the
/// `claude /usage` layout: for each window a title, a progress bar with
/// "NN% used" beside it, and a reset line.
final class UsagePanelView: NSView {

    private var snapshot: UsageSnapshot?
    private var errorText: String?

    // Layout
    private static let width: CGFloat = 300
    private let padX: CGFloat = 16
    private let padTop: CGFloat = 12
    private let padBottom: CGFloat = 12
    private let barHeight: CGFloat = 8
    private let pctColWidth: CGFloat = 64      // "100% used"
    private let barGap: CGFloat = 8            // bar -> pct label

    // Row metrics
    private let titleH: CGFloat = 18
    private let titleToBar: CGFloat = 8
    private let barToReset: CGFloat = 7
    private let resetH: CGFloat = 15
    private let rowGap: CGFloat = 16
    private let footerGap: CGFloat = 12
    private let footerH: CGFloat = 15

    // Fonts
    private let titleFont = NSFont.boldSystemFont(ofSize: 13)
    private let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let resetFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private let footerFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(snapshot: UsageSnapshot?, error: String?) {
        self.snapshot = snapshot
        self.errorText = error
        var f = frame
        f.size.width = Self.width
        f.size.height = computedHeight()
        frame = f
        needsDisplay = true
    }

    private var limits: [UsageLimit] { snapshot?.limits ?? [] }

    private func computedHeight() -> CGFloat {
        guard !limits.isEmpty else {
            if let err = errorText, err.count > 30 {
                return padTop + 60 + padBottom
            }
            return padTop + 20 + padBottom
        }
        var h = padTop
        for i in 0..<limits.count {
            h += titleH + titleToBar + barHeight + barToReset + resetH
            if i != limits.count - 1 { h += rowGap }
        }
        h += footerGap + footerH + padBottom
        return h
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !limits.isEmpty else {
            let errorRect = NSRect(x: padX, y: padTop, width: Self.width - padX * 2, height: frame.height - padTop - padBottom)
            drawTextWrapped(errorText ?? "Loading usage…", in: errorRect, font: titleFont, color: .secondaryLabelColor)
            return
        }

        let barMaxW = Self.width - padX * 2 - barGap - pctColWidth
        var y = padTop

        for (i, limit) in limits.enumerated() {
            // Title
            drawText(limit.title, at: NSPoint(x: padX, y: y), font: titleFont, color: .labelColor)
            y += titleH + titleToBar

            // Progress bar (track + fill)
            let track = NSRect(x: padX, y: y, width: barMaxW, height: barHeight)
            fillRounded(track, radius: barHeight / 2, color: .quaternaryLabelColor)
            let frac = min(max(CGFloat(limit.percent) / 100.0, 0), 1)
            if frac > 0 {
                let fill = NSRect(x: padX, y: y, width: max(barHeight, barMaxW * frac), height: barHeight)
                fillRounded(fill, radius: barHeight / 2, color: fillColor(for: limit))
            }

            // "NN% used" beside the bar, vertically centred with it
            drawText("\(limit.percent)% used",
                     at: NSPoint(x: padX + barMaxW + barGap, y: y - 3),
                     font: pctFont, color: .labelColor)
            y += barHeight + barToReset

            // Reset line
            let resetStr = limit.resetsAt.map(UsageFormat.reset) ?? "Reset time unknown"
            drawText(resetStr, at: NSPoint(x: padX, y: y), font: resetFont, color: .secondaryLabelColor)
            y += resetH

            if i != limits.count - 1 { y += rowGap }
        }

        // Footer
        y += footerGap
        drawText(footerString(), at: NSPoint(x: padX, y: y), font: footerFont, color: .tertiaryLabelColor)
    }

    private func footerString() -> String {
        // We keep the last good numbers on screen through an error (e.g. a 429),
        // so still show when they were fetched to make their staleness clear.
        let updated = snapshot.map { "Updated \(UsageFormat.ago($0.fetchedAt))" }
        if let err = errorText {
            if let updated = updated { return "⚠ \(err) · \(updated)" }
            return "⚠ \(err)"
        }
        return updated ?? ""
    }

    private func fillColor(for limit: UsageLimit) -> NSColor {
        UsageColors.color(percent: limit.percent, isDark: isDarkAppearance)
    }

    // MARK: Primitives

    private func drawText(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }

    private func drawTextWrapped(_ string: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]).draw(in: rect)
    }

    private func fillRounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}
