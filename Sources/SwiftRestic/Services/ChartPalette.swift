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

    /// A plan's colour: the slot assigned at creation, or a deterministic
    /// fallback derived from its ID for plans created before slots existed.
    static func color(for plan: BackupPlan) -> Color {
        categorical[slot(for: plan)]
    }

    /// A historical chart series' colour. Series are keyed by the plan name
    /// recorded when the run happened, so a renamed plan's older runs keep a
    /// stable colour of their own rather than collapsing into "Other" grey.
    static func color(forSeriesNamed name: String) -> Color {
        categorical[slot(forName: name)]
    }

    /// The first palette slot no existing plan effectively occupies — legacy
    /// plans count via their fallback slot, or two series would render
    /// identical colours. Once the palette is exhausted the chart folds
    /// series past the cap anyway, so wrapping keeps every plan coloured.
    static func nextSlot(taken: Set<Int>) -> Int {
        (0..<categorical.count).first { !taken.contains($0) }
            ?? ((taken.max() ?? -1) + 1) % categorical.count
    }

    static func slot(for plan: BackupPlan) -> Int {
        if let chartIndex = plan.chartIndex {
            // Config files are hand-editable; a negative index must not
            // become a negative array subscript.
            return ((chartIndex % categorical.count) + categorical.count) % categorical.count
        }
        return slot(forName: plan.id.uuidString)
    }

    /// Swift's `Hasher` is seeded per process, so a "stable hash" built from
    /// it changes on every launch — the one thing a colour identity must not
    /// do. FNV-1a over the raw bytes is boring and deterministic.
    private static func slot(forName name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(categorical.count))
    }
}
