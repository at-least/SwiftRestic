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

/// One plan's row on the dashboard's Protection card. Data only — the hues it
/// wears live in the view.
struct ProtectionRow: Identifiable, Sendable, Equatable {
    let planID: UUID
    let planName: String
    let repositoryID: UUID?
    let stateText: String
    let isKnown: Bool
    let isProtected: Bool
    let didFail: Bool
    var id: UUID { planID }

    /// Scanning order is severity, not sidebar order: unreadable first,
    /// then exposed, then pending, protected last.
    var severityRank: Int {
        if didFail { return 0 }
        if isKnown, !isProtected { return 1 }
        if !isKnown { return 2 }
        return 3
    }

    /// Derives straight from the plan, so each listing outcome states
    /// only the part that differs.
    init(
        plan: BackupPlan,
        stateText: String,
        isKnown: Bool,
        isProtected: Bool,
        didFail: Bool
    ) {
        planID = plan.id
        planName = plan.name.isEmpty ? "Untitled Plan" : plan.name
        repositoryID = plan.repositoryID
        self.stateText = stateText
        self.isKnown = isKnown
        self.isProtected = isProtected
        self.didFail = didFail
    }
}

/// Derives the dashboard's series from the run history.
///
/// Pure and separate from the view so it can be tested, and so the reduction
/// happens once when the history changes rather than on every redraw.
enum OverviewMetrics {
    /// Categorical colour slots available. An eighth series is never a
    /// generated hue: everything past the cap folds into "Other".
    static let seriesCap = 7
    static let otherSeriesName = "Other"

    /// The window a "recent problem" counts over. The overview's Problems
    /// tile, the failures card, the sidebar row and the menu bar's problem
    /// line all read the same week, so a problem cannot age out of one
    /// surface before another — one owner, not four spellings of `-7 days`.
    static func problemWindowStart(from now: Date) -> Date {
        now.addingTimeInterval(-7 * 86_400)
    }

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
        // Swift's sort is not stable, so equal totals must be broken by name
        // themselves — otherwise two tied plans can swap between keeping a
        // colour and folding into Other between redraws.
        let byVolume = ordered.sorted { lhs, rhs in
            let lhsTotal = totals[lhs]?.values.reduce(0, +) ?? 0
            let rhsTotal = totals[rhs]?.values.reduce(0, +) ?? 0
            return lhsTotal == rhsTotal ? lhs < rhs : lhsTotal > rhsTotal
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

    /// The dashboard chart's input identity, as one comparable string.
    ///
    /// The run count alone went stale: `append` inserts and then trims, so
    /// once the history reaches its cap the count never changes again, and a
    /// `.task(id:)` keyed on it would never re-reduce the series. The newest
    /// record's identity moves with every append, capped or not; the plan
    /// id+name pairs move on a rename or reorder of the series set.
    static func chartSignature(plans: [BackupPlan], runs: [RunRecord]) -> String {
        let planPart = plans
            .map { "\($0.id.uuidString)|\($0.name)" }
            .joined(separator: ";")
        guard let newest = runs.first else { return "\(planPart)#none" }
        let runPart = "\(newest.id.uuidString)"
            + "#\(newest.finishedAt.timeIntervalSince1970)"
            + "#\(newest.outcome.rawValue)"
        return "\(planPart)#\(runPart)"
    }

    /// The Protection card's rows, one per plan. The lookups arrive as
    /// closures so the derivation stays pure — and testable — while the view
    /// keeps its observation on the model state behind them.
    static func protectionRows(
        plans: [BackupPlan],
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool
    ) -> [ProtectionRow] {
        // Stable severity sort: Swift's sort is not documented stable, so the
        // plan order breaks ties inside each rank.
        plans
            .map { plan -> ProtectionRow in
                guard let repositoryID = plan.repositoryID else {
                    return ProtectionRow(
                        plan: plan,
                        stateText: "No repository set",
                        isKnown: true, isProtected: false, didFail: false
                    )
                }
                let latest = latestSnapshot(repositoryID, plan.id)
                switch listingOutcome(repositoryID) {
                case .loaded:
                    let line: String
                    if let latest {
                        line = "Latest backup \(latest.time.formatted(.relative(presentation: .named)))"
                    } else if !repositoryHasSnapshots(repositoryID) {
                        line = "No snapshots yet"
                    } else {
                        // The repository has snapshots, but none tagged from
                        // this plan — the same distinction Plan Detail draws.
                        // A bare "No snapshots yet" reads as a false statement
                        // about a repository the user adopted with snapshots
                        // already in it.
                        line = "The repository has snapshots, but none from this plan yet."
                    }
                    return ProtectionRow(plan: plan, stateText: line, isKnown: true, isProtected: latest != nil, didFail: false)
                case let .failed(message):
                    return ProtectionRow(
                        plan: plan,
                        stateText: "Can't read snapshots — \(Format.firstSentence(message))",
                        isKnown: false, isProtected: false, didFail: true
                    )
                case .idle:
                    let checking = isChecking(repositoryID)
                    return ProtectionRow(
                        plan: plan,
                        stateText: checking ? "Checking…" : "Snapshot list not loaded yet",
                        isKnown: false, isProtected: false, didFail: false
                    )
                }
            }
            .enumerated()
            .sorted { lhs, rhs in
                (lhs.element.severityRank, lhs.offset) < (rhs.element.severityRank, rhs.offset)
            }
            .map(\.element)
    }
}

private func < (lhs: (Date, String), rhs: (Date, String)) -> Bool {
    lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
}
