import Foundation

/// One plan's contribution to one day's backup volume.
struct DailyBackupVolume: Identifiable, Sendable, Equatable {
    var day: Date
    var series: String
    var dataAdded: Int64

    var id: String { "\(series)@\(day.timeIntervalSince1970)" }
}

/// How much of a repository's data one repository holds, for the size chart.
struct RepositoryVolume: Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var bytes: Int64
}

/// Derives the dashboard's series from the run history.
///
/// Pure and separate from the view so it can be tested, and so the reduction
/// happens once when the history changes rather than on every redraw.
enum OverviewMetrics {
    /// Categorical colour slots available. A ninth series is never a generated
    /// hue: everything past the cap folds into "Other".
    static let seriesCap = 7
    static let otherSeriesName = "Other"

    /// Daily totals of data written to repositories, one entry per plan per day.
    ///
    /// - Parameter planOrder: plan names in configuration order. Series colours
    ///   follow this, so a plan keeps its colour as the data changes.
    static func dailyVolume(
        runs: [RunRecord],
        planOrder: [String],
        days: Int = 30,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [DailyBackupVolume] {
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(days - 1) * 86_400))
        var totals: [String: [Date: Int64]] = [:]

        for run in runs where run.kind == .backup && run.outcome != .cancelled {
            let day = calendar.startOfDay(for: run.startedAt)
            guard day >= start else { continue }
            guard run.dataAdded > 0 else { continue }
            let name = run.planName.isEmpty ? otherSeriesName : run.planName
            totals[name, default: [:]][day, default: 0] += run.dataAdded
        }

        let kept = Set(seriesNames(for: totals, planOrder: planOrder))
        var folded: [String: [Date: Int64]] = [:]
        for (name, byDay) in totals {
            let target = kept.contains(name) ? name : otherSeriesName
            for (day, bytes) in byDay { folded[target, default: [:]][day, default: 0] += bytes }
        }

        return folded
            .flatMap { name, byDay in
                byDay.map { DailyBackupVolume(day: $0.key, series: name, dataAdded: $0.value) }
            }
            .sorted { ($0.day, $0.series) < ($1.day, $1.series) }
    }

    /// The series to draw, in a stable order, with anything past the cap folded.
    ///
    /// Ordering follows the configuration rather than size, so a plan does not
    /// change colour just because it happened to write more this week.
    static func seriesNames(
        for totals: [String: [Date: Int64]],
        planOrder: [String]
    ) -> [String] {
        let present = Set(totals.keys)
        let ordered = planOrder.filter(present.contains)
            + present.subtracting(planOrder).sorted()

        guard ordered.count > seriesCap else { return ordered }
        // Over the cap the smallest contributors fold together, so the series
        // that matter keep their own colour.
        let byVolume = ordered.sorted { lhs, rhs in
            (totals[lhs]?.values.reduce(0, +) ?? 0) > (totals[rhs]?.values.reduce(0, +) ?? 0)
        }
        let keep = Set(byVolume.prefix(seriesCap))
        return ordered.filter(keep.contains)
    }

    /// The domain for the colour scale: the drawn series plus "Other" when used.
    static func domain(for points: [DailyBackupVolume], planOrder: [String]) -> [String] {
        let present = Set(points.map(\.series))
        var domain = planOrder.filter { present.contains($0) && $0 != otherSeriesName }
        domain += present.subtracting(domain).sorted().filter { $0 != otherSeriesName }
        if present.contains(otherSeriesName) { domain.append(otherSeriesName) }
        return domain
    }

    /// Failures and completed-with-errors runs in the window — the same set
    /// the Recent problems card lists, so the dashboard's tile and card can
    /// never disagree.
    static func problemCount(runs: [RunRecord], since: Date) -> Int {
        problems(in: runs, since: since).count
    }

    /// Failures and completed-with-errors runs that finished inside the
    /// window — the one definition of "recent problem". The dashboard's tile
    /// counts this set, the Recent problems card lists it, and the menu bar's
    /// problem line leads with its newest entry. Recency counts from when a
    /// run finished: a backup that ran all night and failed at dawn is this
    /// morning's news, not eight days old.
    static func problems(in runs: [RunRecord], since: Date) -> [RunRecord] {
        runs.filter {
            $0.finishedAt >= since
                && ($0.outcome == .failed || $0.outcome == .completedWithErrors)
        }
    }
}

private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
