import Foundation

/// One plan's protection state: the rows behind a repository's sidebar
/// warning and its page's Status line.
struct UpToDateRow: Identifiable, Sendable, Equatable {
    let planID: UUID
    let planName: String
    let repositoryID: UUID?
    let stateText: String
    let isKnown: Bool
    let isUpToDate: Bool
    let didFail: Bool
    /// The line says the run's phase.
    let isRunning: Bool
    /// From `PlanStatus.lastBackupAt`. Nil in every state that spells no
    /// moment; the Status line reads the newest across a repository's plans.
    let lastBackupAt: Date?
    /// Set when the line is the standing problem's ("Failed — 3 hours
    /// ago"); nil when the listing or a run in flight says it.
    let problemOutcome: RunRecord.Outcome?
    /// Listed, with no backup of its own yet and nothing gone wrong: the
    /// next scheduled run is the remedy, so no surface warns of it.
    let isAwaitingFirstBackup: Bool
    var id: UUID { planID }

    /// Scanning order is severity, not sidebar order: unreadable first,
    /// then exposed, then pending, then a run in flight, up to date last.
    fileprivate var severityRank: Int {
        if didFail { return 0 }
        // Ahead of the listing's verdict: a first backup in flight has no
        // snapshot yet, and is news being made, not an alarm.
        if isRunning { return 3 }
        if isAwaitingFirstBackup { return 2 }
        if isKnown, !isUpToDate { return 1 }
        if !isKnown { return 2 }
        return 4
    }

    init(
        plan: BackupPlan,
        among plans: [BackupPlan],
        stateText: String,
        isKnown: Bool,
        isUpToDate: Bool,
        didFail: Bool,
        lastBackupAt: Date? = nil,
        isRunning: Bool = false,
        problemOutcome: RunRecord.Outcome? = nil,
        isAwaitingFirstBackup: Bool = false
    ) {
        planID = plan.id
        planName = plan.label(among: plans)
        repositoryID = plan.repositoryID
        self.stateText = stateText
        self.isKnown = isKnown
        self.isUpToDate = isUpToDate
        self.didFail = didFail
        self.lastBackupAt = lastBackupAt
        self.isRunning = isRunning
        self.problemOutcome = problemOutcome
        self.isAwaitingFirstBackup = isAwaitingFirstBackup
    }
}

/// Names one plan; clicking it opens that plan.
struct UpToDateLine: Equatable, Sendable {
    let planID: UUID
    let text: String
    /// The line is the plan's standing problem, so it carries that
    /// problem's fix.
    var isProblem = false
}

/// The repository page's Status line.
struct UpToDateSummary: Equatable, Sendable {
    /// "2 of 2 plans up to date · Last backup 1 hour ago", with the hold's
    /// own words joined on while one is on.
    var text: String
    /// The hold is the user's own Pause Backups, so the line ends with a
    /// Resume.
    var showsResume: Bool
    /// One per plan whose last backup failed ("Code: Failed — 3 hours
    /// ago"), beside the red octagon the plan's own row wears.
    var failureLines: [UpToDateLine] = []
    /// One per other plan that needs the user ("Photos: Last backup 9 days
    /// ago"), beside the warning triangle. Includes up-to-date plans that
    /// are "Not scheduled" (`PlanStatus.willNotRunCaption`), so "all up to
    /// date" cannot hide a plan that has stopped.
    var attentionLines: [UpToDateLine] = []
    /// One per plan that has simply not backed up yet ("Photos: No backups
    /// yet"), with no glyph: the sidebar shows none for it either.
    var awaitingLines: [UpToDateLine] = []
}

/// Derives the protection rows and the recent problems from the
/// configuration and run history.
enum OverviewMetrics {
    /// Not "until the next success": a backup fixes no failed check, prune,
    /// retention run or restore.
    private static let problemWindowLength: TimeInterval = 7 * 86_400

    /// The sidebar's Activity badge and the menu bar's problem line read the
    /// same window, so a problem cannot age out of one before the other.
    static func problemWindowStart(from now: Date) -> Date {
        now.addingTimeInterval(-problemWindowLength)
    }

    /// The one definition of "recent problem". The sidebar's badge counts
    /// its unseen part, healed or not; the menu bar's problem line leads
    /// with its newest entry `isHealed` has not cleared. Recency counts from
    /// when a run finished: a backup that ran all night and failed at dawn is
    /// this morning's news.
    static func problems(in runs: [RunRecord], since: Date) -> [RunRecord] {
        runs.filter {
            $0.finishedAt >= since && $0.outcome.isProblem
        }
    }

    /// Backups only: a failed check, prune, forget or restore is not fixed
    /// by a backup going through. The sidebar's standing problem and the
    /// menu bar's face both go by this.
    static func isHealed(_ problem: RunRecord, in runs: [RunRecord]) -> Bool {
        guard problem.kind == .backup, let planID = problem.planID else { return false }
        return runs.contains {
            $0.isBackup(ofPlan: planID)
                && $0.outcome == .succeeded
                && $0.finishedAt > problem.finishedAt
        }
    }

    /// The records a standing problem still reads, which the history cap
    /// keeps past its count: each plan's newest unhealed problem backup,
    /// however old (the sidebar caption and dot read it), and every other
    /// problem run inside the week, which a backup never heals. Bounded: one
    /// record per plan, and a week of the rest.
    static func standingProblemIDs(in runs: [RunRecord], now: Date) -> Set<UUID> {
        var newestBackupProblem: [UUID: RunRecord] = [:]
        var standing: Set<UUID> = []
        let since = problemWindowStart(from: now)
        for run in runs where run.outcome.isProblem {
            if run.kind == .backup, let planID = run.planID {
                if newestBackupProblem[planID].map({ $0.finishedAt < run.finishedAt }) ?? true {
                    newestBackupProblem[planID] = run
                }
            } else if run.finishedAt >= since {
                standing.insert(run.id)
            }
        }
        for problem in newestBackupProblem.values where !isHealed(problem, in: runs) {
            standing.insert(problem.id)
        }
        return standing
    }

    /// A repository's sidebar row and the menu bar's face wear a warning for
    /// these.
    static func needingAttention(_ rows: [UpToDateRow]) -> [UpToDateRow] {
        rows.filter { $0.severityRank <= 1 }
    }

    /// The lookups are closures so the derivation stays pure while the view
    /// keeps its observation on the model behind them. The view passes the
    /// window's minute clock as `relative`, as the sidebar's captions do.
    static func protectionRows(
        plans: [BackupPlan],
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool,
        activity: (_ planID: UUID) -> PlanActivity?,
        standingProblem: (_ planID: UUID) -> RunRecord?,
        now: Date = .now,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> [UpToDateRow] {
        // Swift's sort is stable: plan order breaks ties inside each rank.
        plans
            .map { plan -> UpToDateRow in
                let listed = listingRow(
                    plan: plan,
                    among: plans,
                    latestSnapshot: latestSnapshot,
                    repositoryHasSnapshots: repositoryHasSnapshots,
                    listingOutcome: listingOutcome,
                    isChecking: isChecking,
                    now: now,
                    relative: relative
                )
                // The sidebar caption's top ranks, in its words
                // (`PlanStatus.sidebarCaption`); an unreadable listing still
                // outranks the problem. The pause stays out of the rows: the
                // caption says it.
                if let activity = activity(plan.id) {
                    return UpToDateRow(
                        plan: plan,
                        among: plans,
                        stateText: activity.phase.displayName,
                        isKnown: listed.isKnown, isUpToDate: listed.isUpToDate,
                        didFail: false, lastBackupAt: listed.lastBackupAt, isRunning: true
                    )
                }
                if !listed.didFail, let problem = standingProblem(plan.id) {
                    return UpToDateRow(
                        plan: plan,
                        among: plans,
                        stateText: "\(problem.outcomeName) — \(relative(problem.finishedAt))",
                        isKnown: listed.isKnown,
                        // A failed run wrote no snapshot, so the newest one
                        // is older than the trouble; restic exit 3 wrote one.
                        isUpToDate: listed.isUpToDate && problem.outcome != .failed,
                        didFail: false, lastBackupAt: listed.lastBackupAt,
                        problemOutcome: problem.outcome
                    )
                }
                return listed
            }
            .sorted { $0.severityRank < $1.severityRank }
    }

    private static func listingRow(
        plan: BackupPlan,
        among plans: [BackupPlan],
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool,
        now: Date,
        relative: (Date) -> String
    ) -> UpToDateRow {
        guard let repositoryID = plan.repositoryID else {
            return UpToDateRow(
                plan: plan,
                among: plans,
                stateText: BackupPlan.noBackupLocationReason,
                isKnown: true, isUpToDate: false, didFail: false
            )
        }
        let latest = latestSnapshot(repositoryID, plan.id)
        let outcome = listingOutcome(repositoryID)
        func failedRow(_ stateText: String) -> UpToDateRow {
            UpToDateRow(plan: plan, among: plans, stateText: stateText, isKnown: false, isUpToDate: false, didFail: true)
        }
        switch outcome {
        case .loaded:
            let line: String
            var moment: Date?
            var isOverdue = false
            if let latest, let stamped = PlanStatus.lastBackupAt(plan: plan, latestSnapshotTime: latest.time) {
                // `relative`, not Date.RelativeFormatStyle, which rounds
                // 1 h 43 min up to "2 hours ago" where the sidebar says "1
                // hour ago".
                moment = stamped
                isOverdue = StaleAlert.isOverdue(plan, lastBackupAt: stamped, now: now)
                line = isOverdue
                    ? StaleAlert.overdueLine(since: stamped, now: now)
                    : "Last backup \(relative(stamped))"
            } else if !repositoryHasSnapshots(repositoryID) {
                line = "No backups yet"
            } else {
                // Snapshots, none from this plan: a bare "No backups yet"
                // would be false about a repository adopted with snapshots.
                line = PlanStatus.noneFromThisPlanFact
            }
            return UpToDateRow(
                plan: plan, among: plans, stateText: line, isKnown: true,
                isUpToDate: latest != nil && !isOverdue, didFail: false, lastBackupAt: moment,
                isAwaitingFirstBackup: latest == nil
            )
        case let .notConnected(volume):
            return failedRow(Format.withoutFinalPeriod(SnapshotListingOutcome.connectText(volume: volume)))
        case let .failed(message, _):
            return failedRow(listingFailureText(message))
        case let .passwordRefused(name):
            return failedRow(listingFailureText(SnapshotListingOutcome.passwordRefusedText(repositoryName: name)))
        case .idle:
            let checking = isChecking(repositoryID)
            return UpToDateRow(
                plan: plan,
                among: plans,
                stateText: checking ? "Verifying…" : listingIdleText,
                isKnown: false, isUpToDate: false, didFail: false
            )
        }
    }

    /// The rows and the caveat say it alike.
    static func listingFailureText(_ message: String) -> String {
        "Can’t read backups — \(Format.withoutFinalPeriod(Format.firstSentence(message)))"
    }

    /// The caveat and the location page's tooltip say it the same way.
    static let listingIdleText = "List of backups not loaded yet"

    /// Nil unless the listing succeeded: no count is honest before it lands
    /// or after it fails. With no plans, the line names the repository's
    /// adoptable side, the count the sidebar's Other backups node carries.
    static func upToDateSummary(
        rows: [UpToDateRow],
        listingLoaded: Bool,
        otherBackupsCount: Int,
        willNotRun: (UUID) -> String?,
        hold: ScheduleHold?,
        now: Date,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> UpToDateSummary? {
        guard listingLoaded else { return nil }
        var segments: [String]
        if rows.isEmpty {
            segments = ["No plans yet"]
            if otherBackupsCount > 0 {
                segments.append(Format.plural(otherBackupsCount, "backup"))
            }
        } else {
            // A plan still being read is in neither number.
            let known = rows.filter(\.isKnown)
            segments = [
                "\(known.filter(\.isUpToDate).count) of \(Format.plural(known.count, "plan")) up to date"
            ]
            // During a first backup "0 of 1 plan up to date" alone would read
            // as an alarm while the remedy is under way.
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
        var failures: [UpToDateLine] = []
        var attention: [UpToDateLine] = []
        var awaiting: [UpToDateLine] = []
        for row in rows where row.isKnown && !row.isUpToDate && !row.isRunning {
            let line = UpToDateLine(
                planID: row.planID, text: "\(row.planName): \(row.stateText)", isProblem: row.problemOutcome != nil
            )
            if row.problemOutcome == .failed {
                if !failures.contains(line) { failures.append(line) }
            } else if row.isAwaitingFirstBackup {
                if !awaiting.contains(line) { awaiting.append(line) }
            } else if !attention.contains(line) {
                attention.append(line)
            }
        }
        // An out-of-date plan's line above already names it.
        for row in rows where row.isKnown && row.isUpToDate && !row.isRunning {
            if let caption = willNotRun(row.planID) {
                attention.append(UpToDateLine(planID: row.planID, text: "\(row.planName): \(caption)"))
            }
        }
        return UpToDateSummary(
            text: segments.joined(separator: " · "),
            showsResume: showsResume,
            failureLines: failures,
            attentionLines: attention,
            awaitingLines: awaiting
        )
    }

    /// `subject` is "here" (repository page) or "of this plan" (plan page).
    /// `snapshots` are newest first, as every listing is, so the oldest is
    /// the last.
    static func snapshotsTile(
        total: Int, otherBackups: Int, repositoryHasPlans: Bool, snapshots: [Snapshot], subject: String, noun: Bool = false
    ) -> TileFace {
        let oldest = snapshots.last?.time
        return TileFace(
            value: snapshotsLine(
                total: total, otherBackups: otherBackups, repositoryHasPlans: repositoryHasPlans,
                since: oldest, noun: noun
            ),
            help: oldest.map { "The oldest backup \(subject) is from \(Format.timestamp($0))" }
        )
    }

    /// The rest go on the sidebar's "Other backups" shelf, whatever made
    /// them (another Mac, a deleted plan, the console, restic elsewhere), so
    /// the line names no cause. A repository with no plans
    /// has nothing to split. `noun` leads with the word ("12 backups") where
    /// no row label above says it.
    static func snapshotsLine(
        total: Int, otherBackups: Int, repositoryHasPlans: Bool, since: Date? = nil, noun: Bool = false
    ) -> String {
        var line = noun ? Format.plural(total, "backup") : Format.count(total)
        if repositoryHasPlans, otherBackups > 0 {
            line += otherBackups == total
                ? ", none from plans here"
                : ", \(Format.count(otherBackups)) from elsewhere"
        }
        // The oldest backup's day, which nothing else on the page says. One
        // backup reaches no further than itself.
        if let since, total > 1 {
            line += " · since \(Format.day(since))"
        }
        return line
    }
}
