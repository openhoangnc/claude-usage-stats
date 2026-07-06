import AppKit

/// Percentage-range colors for the usage indicator.
///
/// Each color is verified to meet WCAG AAA (≥7:1 contrast) against the nominal
/// menu-bar background for its appearance — dark `#1e1e1e`, light `#f5f5f5`
/// (all land at ~8:1). Pure red cannot reach 7:1 on a dark background, so the
/// top tier is an accessible salmon in dark mode / deep red in light mode.
enum UsageColors {

    // green → lime → gold → orange → red
    private static let darkTiers: [NSColor] = [
        NSColor(srgbRed: 0.000, green: 0.820, blue: 0.298, alpha: 1), // #00D14C
        NSColor(srgbRed: 0.325, green: 0.812, blue: 0.000, alpha: 1), // #53CF00
        NSColor(srgbRed: 0.816, green: 0.706, blue: 0.000, alpha: 1), // #D0B400
        NSColor(srgbRed: 1.000, green: 0.620, blue: 0.239, alpha: 1), // #FF9E3D
        NSColor(srgbRed: 0.992, green: 0.608, blue: 0.545, alpha: 1), // #FD9B8B
    ]

    private static let lightTiers: [NSColor] = [
        NSColor(srgbRed: 0.000, green: 0.329, blue: 0.122, alpha: 1), // #00541F
        NSColor(srgbRed: 0.129, green: 0.322, blue: 0.000, alpha: 1), // #215200
        NSColor(srgbRed: 0.325, green: 0.282, blue: 0.000, alpha: 1), // #534800
        NSColor(srgbRed: 0.443, green: 0.224, blue: 0.000, alpha: 1), // #713900
        NSColor(srgbRed: 0.573, green: 0.075, blue: 0.000, alpha: 1), // #921300
    ]

    /// Tier boundaries: <50 · 50–69 · 70–84 · 85–94 · ≥95 (overage clamps to red).
    static func tierIndex(_ percent: Int) -> Int {
        switch percent {
        case ..<50:   return 0
        case 50..<70: return 1
        case 70..<85: return 2
        case 85..<95: return 3
        default:      return 4
        }
    }

    static func color(percent: Int, isDark: Bool) -> NSColor {
        (isDark ? darkTiers : lightTiers)[tierIndex(percent)]
    }
}

extension NSView {
    var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
