import Foundation

/// One plan's protection state — the rows behind a repository's sidebar
/// warning and its page's Protection line. Data only, so the counts and the
/// words are pinned by tests.
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
    /// The moment the plan's "Last backup" counts from, from
    /// `PlanStatus.lastBackupAt` — the one derivation every surface reads.
    /// Nil in every state that spells no moment; the Protection line reads
    /// the newest of these across a repository's plans.
    let lastBackupAt: Date?
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
        lastBackupAt: Date? = nil,
        isRunning: Bool = false
    ) {
        planID = plan.id
        planName = plan.displayName
        repositoryID = plan.repositoryID
        self.stateText = stateText
        self.isKnown = isKnown
        self.isProtected = isProtected
        self.didFail = didFail
        self.lastBackupAt = lastBackupAt
        self.isRunning = isRunning
    }
}

/// The repository page's Protection line: its text, and whether it ends
/// with the hold's Resume. Data only — `OverviewMetrics.protectionSummary`
/// derives it, so the counts and the words are pinned beside the rows they
/// come from.
struct ProtectionSummary: Equatable, Sendable {
    /// "2 of 2 plans protected · Last backup 1 hour ago" — the app-wide
    /// hold's own words joined on while one is on.
    var text: String
    /// The hold is the user's own Pause Backups, so the line ends with a
    /// Resume; the battery's ends by plugging in, and has no button.
    var showsResume: Bool
    /// One line per plan that is not protected, in the sidebar warning's
    /// words ("Code: Failed — 3 hours ago"), so the count names its subject.
    /// Empty when every plan is protected.
    var attentionLines: [String] = []
}

/// Derives the protection rows and the recent problems from the
/// configuration and run history.
///
/// Pure and separate from the view so it can be tested.
enum OverviewMetrics {
    /// The window a "recent problem" counts over: the Recent problems card,
    /// the sidebar's Activity badge and the menu bar's problem line all read
    /// the same week, so a problem cannot age out of one surface before
    /// another.
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
    /// counts this set and the Recent problems card lists it, healed or not;
    /// the menu bar's problem line leads with its newest entry `isHealed`
    /// has not cleared. Recency counts from when a run finished: a backup
    /// that ran all night and failed at dawn is this morning's news, not
    /// eight days old.
    static func problems(in runs: [RunRecord], since: Date) -> [RunRecord] {
        runs.filter {
            $0.finishedAt >= since
                && ($0.outcome == .failed || $0.outcome == .completedWithErrors)
        }
    }

    /// Whether a backup problem no longer stands: a successful backup of the
    /// same plan finished after it — the next run fixed it. A run skipped
    /// for an away drive that still wrote a snapshot of the rest counts. Backups only: a
    /// failed check, prune, forget or restore is not fixed by a backup going
    /// through, and Apply Retention Now… records its forget under the plan's
    /// ID, so its success heals nothing. The sidebar's standing problem and
    /// the menu bar's face both go by this.
    static func isHealed(_ problem: RunRecord, in runs: [RunRecord]) -> Bool {
        guard problem.kind == .backup, let planID = problem.planID else { return false }
        return runs.contains {
            $0.kind == .backup && $0.planID == planID
                && ($0.outcome == .succeeded || $0.outcome == .skipped && $0.snapshotID != nil)
                && $0.finishedAt > problem.finishedAt
        }
    }

    /// One repository's share of that set, every kind of run: a check or
    /// prune has no plan, so the repository's page is the only place near it
    /// its failure can be read.
    static func problems(in runs: [RunRecord], since: Date, repositoryID: UUID) -> [RunRecord] {
        problems(in: runs, since: since).filter { $0.repositoryID == repositoryID }
    }

    /// The rows whose plan is not protected and should be: an unreadable
    /// listing, a plan known to have no backup, or one whose last backup
    /// failed. A repository's sidebar row wears a warning for these, since
    /// the badge and the menu bar count failed runs only, and an unreadable
    /// repository has none.
    static func needingAttention(_ rows: [ProtectionRow]) -> [ProtectionRow] {
        rows.filter { $0.severityRank <= 1 }
    }

    /// The protection rows, one per plan. The lookups arrive as closures so
    /// the derivation stays pure while the view keeps its observation on the
    /// model behind them. `relative` spells a past moment; the view passes
    /// the window's minute clock, as the sidebar's captions do.
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
                // phase, then a standing problem; an unreadable listing
                // still outranks the problem. The pause stays out of the
                // rows — the caption says it. Protected is the listing's,
                // except that a standing failure takes it away below.
                if let activity = activity(plan.id) {
                    return ProtectionRow(
                        plan: plan,
                        stateText: activity.phase.displayName,
                        isKnown: listed.isKnown, isProtected: listed.isProtected,
                        didFail: false, lastBackupAt: listed.lastBackupAt, isRunning: true
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
                        didFail: false, lastBackupAt: listed.lastBackupAt
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
            // The moment the line above counts from, when it counts one.
            var moment: Date?
            if let latest, let stamped = PlanStatus.lastBackupAt(plan: plan, latestSnapshot: latest) {
                // The sidebar's words and formatter, and the one moment
                // every surface's "Last backup" counts from
                // (`PlanStatus.lastBackupAt`). Date.RelativeFormatStyle
                // rounds 1 h 43 min up to "2 hours ago", where
                // Format.relative says "1 hour ago".
                moment = stamped
                line = "Last backup \(relative(stamped))"
            } else if !repositoryHasSnapshots(repositoryID) {
                line = "No snapshots yet"
            } else {
                // The repository has snapshots but none from this plan —
                // the same distinction the plan page's Snapshots row draws;
                // a bare "No snapshots yet" would be false about a
                // repository adopted with snapshots already in it.
                line = "The repository has snapshots, but none from this plan yet."
            }
            return ProtectionRow(
                plan: plan, stateText: line, isKnown: true,
                isProtected: latest != nil, didFail: false, lastBackupAt: moment
            )
        case let .failed(message):
            return ProtectionRow(
                plan: plan,
                stateText: listingFailureText(message),
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

    /// An unreadable snapshot listing in one sentence — the rows behind the
    /// sidebar's warning and the caveat under a card say it alike.
    static func listingFailureText(_ message: String) -> String {
        "Can't read snapshots — \(Format.firstSentence(message))"
    }

    /// The repository page's Protection line: how many of the repository's
    /// plans are protected, when its newest backup landed, and, while one is
    /// on, the app-wide hold's own words. Nil unless the listing has
    /// succeeded: no count is honest before it lands or after it fails.
    ///
    /// With no plans, the line names the repository's adoptable side — the
    /// same count the sidebar's Other backups node carries — what "no plans"
    /// means on a page whose repository may hold history.
    static func protectionSummary(
        rows: [ProtectionRow],
        listingLoaded: Bool,
        otherBackupsCount: Int,
        hold: ScheduleHold?,
        now: Date,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> ProtectionSummary? {
        guard listingLoaded else { return nil }
        var segments: [String]
        if rows.isEmpty {
            segments = ["No plans yet"]
            if otherBackupsCount > 0 {
                segments.append("\(Format.plural(otherBackupsCount, "backup")) from no plan here")
            }
        } else {
            // The Protection line's own rule: a plan still being read is
            // in neither number.
            let known = rows.filter(\.isKnown)
            segments = [
                "\(known.filter(\.isProtected).count) of \(Format.plural(known.count, "plan")) protected"
            ]
            // A run in flight, in the sidebar caption's phase words: during a
            // first backup "0 of 1 plan protected" alone would read as an
            // alarm while the remedy is under way.
            segments += rows.filter(\.isRunning).map { "\($0.planName) — \($0.stateText)" }
            if let newest = rows.compactMap(\.lastBackupAt).max() {
                segments.append("Last backup \(relative(newest))")
            }
        }
        if let hold {
            segments.append(hold.summary(now: now))
        }
        var showsResume = false
        if case .paused = hold { showsResume = true }
        // The sidebar warning's own join of the same rows (attentionMark), so
        // the card and the triangle beside it cannot disagree.
        var attention: [String] = []
        for row in rows where row.isKnown && !row.isProtected && !row.isRunning {
            let line = "\(row.planName): \(row.stateText)"
            if !attention.contains(line) { attention.append(line) }
        }
        return ProtectionSummary(
            text: segments.joined(separator: " · "),
            showsResume: showsResume,
            attentionLines: attention
        )
    }

    /// The repository page's Snapshots value: the whole count, split when
    /// some backups belong to no plan of it — the same count the sidebar's
    /// Other backups node and the Protection line carry. When none is a
    /// plan's, "all" says so instead of repeating the count.
    static func snapshotsLine(total: Int, otherBackups: Int) -> String {
        if otherBackups == 0 { return Format.count(total) }
        if otherBackups == total { return "\(Format.count(total)) · all from no plan here" }
        return "\(Format.count(total)) · \(Format.count(otherBackups)) from no plan here"
    }
}
