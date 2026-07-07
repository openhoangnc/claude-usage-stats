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

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)

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

    func update(session: UsageLimit?, weekly: UsageLimit?) {
        sessionPct = session?.percent
        weekPct = weekly?.percent
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
        let w = max(getSessionString().size().width, getWeekString().size().width)
        let newWidth = max(22, ceil(w))
        if abs(newWidth - preferredWidth) > 0.5 {
            preferredWidth = newWidth
            onResize?(newWidth)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        getSessionString().draw(in: NSRect(x: 0, y: 11, width: w, height: 11))
        getWeekString().draw(in: NSRect(x: 0, y: 1,  width: w, height: 11))
    }
}
