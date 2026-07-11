import AppKit

/// Two-line menu-bar view: session % on top, weekly (all models) % below.
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
    private static let warnFont = NSFont.systemFont(ofSize: 13, weight: .bold)

    private static let rightAlign: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .right
        return p
    }()

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    private var cachedAppearance: NSAppearance?
    private var cachedSessionString: NSAttributedString?
    private var cachedWeekString: NSAttributedString?

    // MARK: Data

    func update(session: UsageLimit?, weekly: UsageLimit?, stale: Bool) {
        sessionPct = session?.percent
        weekPct = weekly?.percent
        isStale = stale
        cachedSessionString = nil
        cachedWeekString = nil
        recomputeWidth()
        needsDisplay = true
    }

    private func createLine(_ pct: Int?) -> NSAttributedString {
        if let pct = pct {
            return NSAttributedString(string: "\(pct)%", attributes: [
                .font: Self.valueFont,
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

    private func getSessionString() -> NSAttributedString {
        updateCachedStringsIfNeeded()
        return cachedSessionString!
    }

    private func getWeekString() -> NSAttributedString {
        updateCachedStringsIfNeeded()
        return cachedWeekString!
    }

    private func updateCachedStringsIfNeeded() {
        if cachedSessionString == nil || cachedWeekString == nil || cachedAppearance != effectiveAppearance {
            cachedAppearance = effectiveAppearance
            cachedSessionString = createLine(sessionPct)
            cachedWeekString = createLine(weekPct)
        }
    }

    private func recomputeWidth() {
        let textW = max(getSessionString().size().width, getWeekString().size().width)
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
        getSessionString().draw(in: NSRect(x: textX, y: 11, width: textW, height: 11))
        getWeekString().draw(in: NSRect(x: textX, y: 1,  width: textW, height: 11))

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
