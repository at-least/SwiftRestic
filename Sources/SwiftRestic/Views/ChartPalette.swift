import AppKit
import SwiftUI

/// Colours for the dashboard's charts.
///
/// The categorical slots are used in this fixed order and never cycled, which is
/// what keeps adjacent stacked segments distinguishable under colour-vision
/// deficiency. Each mode's steps were selected for its own surface rather than
/// derived by flipping the other. On the light surface three of the slots sit
/// below 3:1 contrast, so every chart using them ships a legend and a table view.
enum ChartPalette {
    static let categorical: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5), // blue
        dynamic(light: 0xEB6834, dark: 0xD95926), // orange
        dynamic(light: 0x1BAF7A, dark: 0x199E70), // aqua
        dynamic(light: 0xEDA100, dark: 0xC98500), // yellow
        dynamic(light: 0xE87BA4, dark: 0xD55181), // magenta
        dynamic(light: 0x008300, dark: 0x008300), // green
        dynamic(light: 0x4A3AA7, dark: 0x9085E9), // violet
    ]

    /// Anything folded past the categorical cap. Deliberately neutral so it never
    /// reads as one more entity.
    static let other = dynamic(light: 0x898781, dark: 0x898781)

    /// Single hue for one-series magnitude charts.
    static let sequential = dynamic(light: 0x2A78D6, dark: 0x3987E5)

    /// Reserved for run state, never for a series.
    static func status(_ outcome: RunRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: dynamic(light: 0x0CA30C, dark: 0x0CA30C)
        case .completedWithErrors: dynamic(light: 0xEC835A, dark: 0xEC835A)
        case .failed: dynamic(light: 0xD03B3B, dark: 0xD03B3B)
        case .cancelled: dynamic(light: 0x898781, dark: 0x898781)
        }
    }

    /// Colours for a chart's series, matching `domain` position for position.
    static func range(for domain: [String]) -> [Color] {
        domain.enumerated().map { index, name in
            if name == OverviewMetrics.otherSeriesName { return other }
            return categorical[index % categorical.count]
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
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
