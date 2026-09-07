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

    /// A plan's colour: the slot assigned at creation, or a stable fallback
    /// derived from its ID for plans created before slots existed.
    static func color(for plan: BackupPlan) -> Color {
        categorical[slot(for: plan)]
    }

    /// The first palette slot no existing plan occupies. Once the palette is
    /// exhausted the chart folds series past the cap anyway, so wrapping by
    /// position keeps every plan coloured.
    static func nextSlot(taken: Set<Int>) -> Int {
        (0..<categorical.count).first { !taken.contains($0) }
            ?? ((taken.max() ?? -1) + 1) % categorical.count
    }

    private static func slot(for plan: BackupPlan) -> Int {
        if let chartIndex = plan.chartIndex { return chartIndex % categorical.count }
        var hasher = Hasher()
        hasher.combine(plan.id)
        return Int(UInt(bitPattern: hasher.finalize()) % UInt(categorical.count))
    }
}
