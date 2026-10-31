import AppKit

/// Two-line menu-bar view: session % on top, weekly % below (all models, or a
/// model-scoped week when the plan has no all-models cap). An account with
/// only one of the two — a session limit only, or no session limit (Ultra) —
/// gets that single number, larger and centred vertically.
/// The percentages are auto-colored by usage range (see `UsageColors`).
final class StatusBarView: NSView {

    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    /// Called when the preferred width changes so the status item can resize.
    var onResize: ((CGFloat) -> Void)?

    private(set) var preferredWidth: CGFloat = 26

    private var sessionPct: Int?
    private var weekPct: Int?
    private var isStale = false

    /// Width reserved on the left for the "!" warning mark when usage is stale.
    private static let warnColWidth: CGFloat = 10

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
    private static let singleFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
    private static let warnFont = NSFont.systemFont(ofSize: 13, weight: .bold)

    private static let rightAlign: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    private var cachedAppearance: NSAppearance?
    private var cachedLines: [NSAttributedString]?

    // MARK: Data

    func update(session: UsageLimit?, weekly: UsageLimit?, stale: Bool) {
        sessionPct = session?.percent
        weekPct = weekly?.percent
        isStale = stale
        cachedLines = nil
        recomputeWidth()
        needsDisplay = true
    }

    private func createLine(_ pct: Int?, font: NSFont = valueFont) -> NSAttributedString {
        if let pct = pct {
            return NSAttributedString(string: "\(pct)%", attributes: [
                .font: font,
                .foregroundColor: UsageColors.color(percent: pct, isDark: isDarkAppearance),
                .paragraphStyle: Self.rightAlign,
            ])
        }
        return NSAttributedString(string: "··", attributes: [
            .font: Self.valueFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: Self.rightAlign,
        ])
    }

    /// The lines to draw, top to bottom. When only one window is known the
    /// account has only that one, and it gets the bar to itself. Before the
    /// first fetch both are nil, so the two-line "··" placeholders still show
    /// while loading.
    private func lines() -> [NSAttributedString] {
        if let cached = cachedLines, cachedAppearance == effectiveAppearance { return cached }
        cachedAppearance = effectiveAppearance
        let made: [NSAttributedString]
        switch (sessionPct, weekPct) {
        case (let only?, nil), (nil, let only?):
            made = [createLine(only, font: Self.singleFont)]
        default:
            made = [createLine(sessionPct), createLine(weekPct)]
        }
        cachedLines = made
        return made
    }

    private func recomputeWidth() {
        let textW = lines().map { $0.size().width }.max() ?? 0
        var newWidth = max(22, ceil(textW))
        if isStale { newWidth += Self.warnColWidth }
        if abs(newWidth - preferredWidth) > 0.5 {
            preferredWidth = newWidth
            onResize?(newWidth)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let textX: CGFloat = isStale ? Self.warnColWidth : 0
        let textW = bounds.width - textX
        let lines = self.lines()
        if lines.count == 1 {
            let h = ceil(lines[0].size().height)
            lines[0].draw(in: NSRect(x: textX, y: (bounds.height - h) / 2, width: textW, height: h))
        } else {
            lines[0].draw(in: NSRect(x: textX, y: 11, width: textW, height: 11))
            lines[1].draw(in: NSRect(x: textX, y: 1,  width: textW, height: 11))
        }

        if isStale { drawWarningMark() }
    }

    /// A bold "!" in the reserved left column, vertically centred, signalling
    /// that the displayed numbers are stale (no successful fetch recently).
    private func drawWarningMark() {
        let mark = NSAttributedString(string: "!", attributes: [
            .font: Self.warnFont,
            .foregroundColor: UsageColors.warning(isDark: isDarkAppearance),
        ])
        let size = mark.size()
        let x = (Self.warnColWidth - size.width) / 2
        let y = (bounds.height - size.height) / 2
        mark.draw(at: NSPoint(x: x, y: y))
    }
}
