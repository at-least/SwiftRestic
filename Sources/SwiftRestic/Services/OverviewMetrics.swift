import Foundation

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
    /// A run of the plan is in flight, and the line says its phase.
    let isRunning: Bool
    /// The standing problem the line names, for its glyph — nil when the
    /// line is not about one.
    let problemOutcome: RunRecord.Outcome?
    var id: UUID { planID }

    /// Scanning order is severity, not sidebar order: unreadable first,
    /// then exposed, then pending, then a run in flight, protected last.
    var severityRank: Int {
        if didFail { return 0 }
        // Ahead of the listing's verdict: a first backup in flight has no
        // snapshot yet, and is news being made, not an alarm.
        if isRunning { return 3 }
        if isKnown, !isProtected { return 1 }
        if !isKnown { return 2 }
        return 4
    }

    /// Derives straight from the plan, so each listing outcome states
    /// only the part that differs.
    init(
        plan: BackupPlan,
        stateText: String,
        isKnown: Bool,
        isProtected: Bool,
        didFail: Bool,
        isRunning: Bool = false,
        problemOutcome: RunRecord.Outcome? = nil
    ) {
        planID = plan.id
        planName = plan.name.isEmpty ? "Untitled Plan" : plan.name
        repositoryID = plan.repositoryID
        self.stateText = stateText
        self.isKnown = isKnown
        self.isProtected = isProtected
        self.didFail = didFail
        self.isRunning = isRunning
        self.problemOutcome = problemOutcome
    }
}

/// Derives the dashboard's protection rows and the recent problems from the
/// configuration and run history.
///
/// Pure and separate from the view so it can be tested.
enum OverviewMetrics {
    /// The window a "recent problem" counts over. The overview's Recent
    /// problems card, the sidebar's Activity badge and the menu bar's problem
    /// line all read the same week, so a problem cannot age out of one
    /// surface before another — one owner, not three spellings of `-7 days`.
    static func problemWindowStart(from now: Date) -> Date {
        now.addingTimeInterval(-7 * 86_400)
    }

    /// Failures and completed-with-errors runs in the window — the same set
    /// the Recent problems card lists, so the sidebar's badge and the card
    /// can never disagree.
    static func problemCount(runs: [RunRecord], since: Date) -> Int {
        problems(in: runs, since: since).count
    }

    /// Failures and completed-with-errors runs that finished inside the
    /// window — the one definition of "recent problem". The sidebar's badge
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

    /// The Protection card's rows, one per plan. The lookups arrive as
    /// closures so the derivation stays pure — and testable — while the view
    /// keeps its observation on the model state behind them. `relative`
    /// spells a past moment; the view passes the window's minute clock, as
    /// the sidebar's captions do.
    static func protectionRows(
        plans: [BackupPlan],
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool,
        activity: (_ planID: UUID) -> PlanActivity?,
        standingProblem: (_ planID: UUID) -> RunRecord?,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> [ProtectionRow] {
        // Stable severity sort: Swift's sort is not documented stable, so the
        // plan order breaks ties inside each rank.
        plans
            .map { plan -> ProtectionRow in
                let listed = listingRow(
                    plan: plan,
                    latestSnapshot: latestSnapshot,
                    repositoryHasSnapshots: repositoryHasSnapshots,
                    listingOutcome: listingOutcome,
                    isChecking: isChecking,
                    relative: relative
                )
                // The sidebar caption's top ranks, in its words
                // (PlanStatus.sidebarCaption): a run in flight says its
                // phase, then a standing problem says what went wrong and
                // when — the card read "Last backup 4 hours ago" beside the
                // sidebar's "Failed — Just now". An unreadable listing still
                // outranks the problem: its row owns the Retry. The pause
                // rank stays off the card; Next runs and the sidebar say it.
                // Whether the plan counts as protected stays the listing's.
                if let activity = activity(plan.id) {
                    return ProtectionRow(
                        plan: plan,
                        stateText: activity.phase.displayName,
                        isKnown: listed.isKnown, isProtected: listed.isProtected,
                        didFail: false, isRunning: true
                    )
                }
                if !listed.didFail, let problem = standingProblem(plan.id) {
                    return ProtectionRow(
                        plan: plan,
                        stateText: "\(problem.outcome.displayName) — \(relative(problem.finishedAt))",
                        isKnown: listed.isKnown,
                        // A failed run wrote no snapshot, so the newest one
                        // is older than the trouble; a run that completed
                        // with errors (restic exit 3) wrote one.
                        isProtected: listed.isProtected && problem.outcome != .failed,
                        didFail: false, problemOutcome: problem.outcome
                    )
                }
                return listed
            }
            .enumerated()
            .sorted { lhs, rhs in
                (lhs.element.severityRank, lhs.offset) < (rhs.element.severityRank, rhs.offset)
            }
            .map(\.element)
    }

    /// A plan's row as its snapshot listing alone tells it.
    private static func listingRow(
        plan: BackupPlan,
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool,
        relative: (Date) -> String
    ) -> ProtectionRow {
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
                // The sidebar's words and formatter, so the two never
                // disagree side by side: Date.RelativeFormatStyle
                // rounds 1 h 43 min up to "2 hours ago", where
                // Format.relative says "1 hour ago".
                line = "Last backup \(relative(latest.time))"
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
}
