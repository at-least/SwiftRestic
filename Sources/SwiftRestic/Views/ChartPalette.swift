import SwiftUI

/// Colours for the dashboard's charts.
///
/// Native system colours only. The categorical slots are used in this fixed
/// order and never cycled, which is what keeps adjacent stacked segments
/// distinguishable under colour-vision deficiency; hue order is preserved from
/// the original palette for the same reason. On the light surface some slots
/// sit below 3:1 contrast, so every chart using them ships a legend and a
/// table view.
enum ChartPalette {
    static let categorical: [Color] = [
        .blue, .orange, .teal, .yellow, .pink, .green, .purple,
    ]

    /// Anything folded past the categorical cap. Deliberately neutral so it never
    /// reads as one more entity.
    static let other = Color.gray

    /// Single hue for one-series magnitude charts.
    static let sequential = Color.accentColor

    /// Reserved for run state, never for a series.
    static func status(_ outcome: RunRecord.Outcome) -> Color {
        switch outcome {
        case .succeeded: .green
        case .completedWithErrors: .orange
        case .failed: .red
        case .cancelled: .gray
        }
    }

    /// Colours for a chart's series, matching `domain` position for position.
    static func range(for domain: [String]) -> [Color] {
        domain.enumerated().map { index, name in
            if name == OverviewMetrics.otherSeriesName { return other }
            return categorical[index % categorical.count]
        }
    }
}
