import AppKit
import SwiftUI

/// Colours for the dashboard's charts.
///
/// The categorical slots are used in this fixed order and never cycled, which is
/// what keeps adjacent stacked segments distinguishable under colour-vision
/// deficiency; hue order is preserved from the original palette for the same
/// reason. Each mode's steps were selected for its own surface rather than
/// derived by flipping the other. On the light surface some slots sit below
/// 3:1 contrast, so every chart using them ships a legend and a table view.
enum ChartPalette {
    static let categorical: [Color] = [
        Theme.tint, // indigo (brand)
        Theme.dynamic(light: 0xD9662E, dark: 0xE8813F), // orange
        Theme.dynamic(light: 0x14A085, dark: 0x2FBF9C), // teal
        Theme.dynamic(light: 0xC08309, dark: 0xE3A93C), // gold
        Theme.dynamic(light: 0xC9508B, dark: 0xDE7BAD), // rose
        Theme.dynamic(light: 0x2E8B3D, dark: 0x4CB85C), // green
        Theme.dynamic(light: 0x6D4FC4, dark: 0x9F8BEA), // violet
    ]

    /// Anything folded past the categorical cap. Deliberately neutral so it never
    /// reads as one more entity.
    static let other = Theme.dynamic(light: 0x898781, dark: 0x898781)

    /// Single hue for one-series magnitude charts.
    static let sequential = Theme.tint

    /// Reserved for run state, never for a series.
    static func status(_ outcome: RunRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: Theme.success
        case .completedWithErrors: Theme.warning
        case .failed: Theme.danger
        case .cancelled: other
        }
    }

    /// Colours for a chart's series, matching `domain` position for position.
    static func range(for domain: [String]) -> [Color] {
        domain.enumerated().map { index, name in
            if name == OverviewMetrics.otherSeriesName { return other }
            return categorical[index % categorical.count]
        }
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
