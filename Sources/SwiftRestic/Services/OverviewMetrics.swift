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
    /// The standing problem's outcome when the line is that problem's
    /// ("Failed — 3 hours ago"); nil when the listing or a run in flight
    /// says it. A failed one wears the failed run's red octagon on the
    /// repository's surfaces, as on the plan's own row
    /// (`OverviewMetrics.attentionOutcome`).
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
        among plans: [BackupPlan],
        stateText: String,
        isKnown: Bool,
        isProtected: Bool,
        didFail: Bool,
        lastBackupAt: Date? = nil,
        isRunning: Bool = false,
        problemOutcome: RunRecord.Outcome? = nil
    ) {
        planID = plan.id
        planName = plan.label(among: plans)
        repositoryID = plan.repositoryID
        self.stateText = stateText
        self.isKnown = isKnown
        self.isProtected = isProtected
        self.didFail = didFail
        self.lastBackupAt = lastBackupAt
        self.isRunning = isRunning
        self.problemOutcome = problemOutcome
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
    /// One line per plan whose last backup failed, in the sidebar warning's
    /// words ("Code: Failed — 3 hours ago"), beside the failed run's red
    /// octagon that the plan's own row wears. Empty when none failed.
    var failureLines: [String] = []
    /// One line per other plan that is not protected — no backup yet, no
    /// repository — in the sidebar warning's words ("Photos: No backups
    /// yet"), beside the warning triangle. With the failure lines, the
    /// count names its subject; both are empty when every plan is
    /// protected.
    var attentionLines: [String] = []
    /// One line per protected plan whose newest backup left an away
    /// drive's folders out, in the record's own words ("Journal: “Archive
    /// SSD” is not connected; the other folders were backed up.") —
    /// protected, since the rest is backed up, but not whole. Empty when
    /// every plan's newest backup read every folder.
    var skippedLines: [String] = []
    /// One line per protected plan that will not run by itself now — its
    /// pause, or "Not scheduled" — in the sidebar's words ("Photos: Paused
    /// — Sunday at 3:00 AM"), so "all protected" cannot hide a plan that has
    /// stopped. A pause is a choice, not a problem: the card gives these
    /// the pause glyph, not the warning's.
    var heldLines: [String] = []
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
            $0.finishedAt >= since && $0.outcome.isProblem
        }
    }

    /// One Recent problems row: the newest run of a plan's (or a
    /// repository's upkeep's) problems that ended the same way, and how many
    /// the window holds.
    struct ProblemGroup: Equatable, Identifiable {
        var newest: RunRecord
        var count: Int
        var id: UUID { newest.id }
    }

    /// The card's reading of `problems`, newest first: a cause that stands —
    /// one unreadable file warns every run — is one row with its count, not
    /// a row per run pushing every other problem off the card. Grouped by
    /// plan, kind and outcome, never by a guessed cause; Activity keeps each
    /// run. Display only: the stored history is untouched.
    static func problemGroups(_ problems: [RunRecord]) -> [ProblemGroup] {
        var groups: [ProblemKey: ProblemGroup] = [:]
        for run in problems {
            let key = ProblemKey(run)
            if var group = groups[key] {
                group.count += 1
                if run.finishedAt > group.newest.finishedAt { group.newest = run }
                groups[key] = group
            } else {
                groups[key] = ProblemGroup(newest: run, count: 1)
            }
        }
        return groups.values.sorted { $0.newest.finishedAt > $1.newest.finishedAt }
    }

    /// What one Recent problems row collects: a plan's (or a repository's
    /// upkeep's) runs of one kind that ended the same way.
    private struct ProblemKey: Hashable {
        var planID: UUID?
        var repositoryID: UUID?
        var kind: RunRecord.Kind
        var outcome: RunRecord.Outcome

        init(_ run: RunRecord) {
            planID = run.planID
            repositoryID = run.repositoryID
            kind = run.kind
            outcome = run.outcome
        }
    }

    /// Whether a backup problem no longer stands: a successful backup of the
    /// same plan finished after it — the next run fixed it. A run skipped
    /// for an away drive that still wrote a snapshot of the rest counts. Backups only: a
    /// failed check, prune, forget or restore is not fixed by a backup going
    /// through, and Apply Retention Now records its forget under the plan's
    /// ID, so its success heals nothing. The sidebar's standing problem and
    /// the menu bar's face both go by this.
    static func isHealed(_ problem: RunRecord, in runs: [RunRecord]) -> Bool {
        guard problem.kind == .backup, let planID = problem.planID else { return false }
        return runs.contains {
            $0.kind == .backup && $0.planID == planID
                && ($0.outcome == .succeeded || $0.isPartialSkip)
                && $0.finishedAt > problem.finishedAt
        }
    }

    /// The records a standing problem still reads, which the history cap
    /// keeps past its count: each plan's newest failed or completed-with-
    /// errors backup no later success healed — the sidebar caption and the
    /// dot read it however old it is — and every other run's problem inside
    /// the week, which a backup never heals (the repository's Recent
    /// problems, the Activity badge, the menu bar). Bounded: one record per
    /// plan, and a week of the rest.
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

    /// The outcome whose glyph and hue a repository's warning wears for
    /// these rows: a failed run's red octagon while one of them is a plan
    /// whose last backup failed — the glyph that plan's own row wears
    /// beneath — else the warning's orange triangle, as for a run that
    /// completed with warnings (the banners' rule: one colour, one
    /// meaning). An unreadable listing stays orange, as its page says it.
    static func attentionOutcome(_ rows: [ProtectionRow]) -> RunRecord.Outcome {
        rows.contains { $0.problemOutcome == .failed } ? .failed : .completedWithErrors
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
        // Swift's sort is stable: plan order breaks ties inside each rank.
        plans
            .map { plan -> ProtectionRow in
                let listed = listingRow(
                    plan: plan,
                    among: plans,
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
                        among: plans,
                        stateText: activity.phase.displayName,
                        isKnown: listed.isKnown, isProtected: listed.isProtected,
                        didFail: false, lastBackupAt: listed.lastBackupAt, isRunning: true
                    )
                }
                if !listed.didFail, let problem = standingProblem(plan.id) {
                    return ProtectionRow(
                        plan: plan,
                        among: plans,
                        stateText: "\(problem.outcome.displayName) — \(relative(problem.finishedAt))",
                        isKnown: listed.isKnown,
                        // A failed run wrote no snapshot, so the newest one
                        // is older than the trouble; a run that completed
                        // with errors (restic exit 3) wrote one.
                        isProtected: listed.isProtected && problem.outcome != .failed,
                        didFail: false, lastBackupAt: listed.lastBackupAt,
                        problemOutcome: problem.outcome
                    )
                }
                return listed
            }
            .sorted { $0.severityRank < $1.severityRank }
    }

    /// A plan's row as its snapshot listing alone tells it.
    private static func listingRow(
        plan: BackupPlan,
        among plans: [BackupPlan],
        latestSnapshot: (_ repositoryID: UUID, _ planID: UUID) -> Snapshot?,
        repositoryHasSnapshots: (UUID) -> Bool,
        listingOutcome: (UUID) -> SnapshotListingOutcome,
        isChecking: (UUID) -> Bool,
        relative: (Date) -> String
    ) -> ProtectionRow {
        guard let repositoryID = plan.repositoryID else {
            return ProtectionRow(
                plan: plan,
                among: plans,
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
                line = "No backups yet"
            } else {
                // The repository has snapshots but none from this plan —
                // the same distinction the plan page's Snapshots row draws;
                // a bare "No snapshots yet" would be false about a
                // repository adopted with snapshots already in it.
                line = "The repository has backups, but none from this plan yet."
            }
            return ProtectionRow(
                plan: plan, among: plans, stateText: line, isKnown: true,
                isProtected: latest != nil, didFail: false, lastBackupAt: moment
            )
        case let .failed(message):
            return ProtectionRow(
                plan: plan,
                among: plans,
                stateText: listingFailureText(message),
                isKnown: false, isProtected: false, didFail: true
            )
        case .idle:
            let checking = isChecking(repositoryID)
            return ProtectionRow(
                plan: plan,
                among: plans,
                stateText: checking ? "Checking…" : listingIdleText,
                isKnown: false, isProtected: false, didFail: false
            )
        }
    }

    /// An unreadable snapshot listing in one sentence — the rows behind the
    /// sidebar's warning and the caveat under a card say it alike.
    static func listingFailureText(_ message: String) -> String {
        "Can’t read backups — \(Format.firstSentence(message))"
    }

    /// The listing not read yet, in the sidebar's words — the caveat under a
    /// card and the repository page's tooltip say it the same way.
    static let listingIdleText = "List of backups not loaded yet"

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
        willNotRun: (UUID) -> String?,
        partialSkip: (UUID) -> String? = { _ in nil },
        hold: ScheduleHold?,
        now: Date,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> ProtectionSummary? {
        guard listingLoaded else { return nil }
        var segments: [String]
        if rows.isEmpty {
            segments = ["No plans yet"]
            if otherBackupsCount > 0 {
                segments.append(Format.plural(otherBackupsCount, "backup"))
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
        // the card and the mark beside it cannot disagree — a failed run's
        // lines apart, under its glyph.
        var failures: [String] = []
        var attention: [String] = []
        for row in rows where row.isKnown && !row.isProtected && !row.isRunning {
            let line = "\(row.planName): \(row.stateText)"
            if row.problemOutcome == .failed {
                if !failures.contains(line) { failures.append(line) }
            } else if !attention.contains(line) {
                attention.append(line)
            }
        }
        // The protected plans that will not run by themselves
        // (`PlanStatus.willNotRunCaption`); an unprotected one's line above
        // already names it.
        var held: [String] = []
        // And the protected plans whose newest backup went around an away
        // drive (`partialSkip`: the record's words), which "protected"
        // alone would hide.
        var skipped: [String] = []
        for row in rows where row.isKnown && row.isProtected && !row.isRunning {
            if let caption = willNotRun(row.planID) { held.append("\(row.planName): \(caption)") }
            if let skip = partialSkip(row.planID) { skipped.append("\(row.planName): \(skip)") }
        }
        return ProtectionSummary(
            text: segments.joined(separator: " · "),
            showsResume: showsResume,
            failureLines: failures,
            attentionLines: attention,
            skippedLines: skipped,
            heldLines: held
        )
    }

    /// The Snapshots tile of a repository page (`subject` "here") or a plan
    /// page ("of this plan"): `snapshotsLine` on its face, the oldest
    /// backup's moment behind it. `snapshots` are newest first, as every
    /// listing is (the pages read their newest from `first`), so the oldest
    /// is the last.
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

    /// The repository page's Snapshots value: the whole count, split by the
    /// shelf the sidebar puts the rest on — "Other backups", whatever made
    /// them (another Mac, a deleted plan, the console, restic elsewhere), so
    /// the line names the place, not a cause. A repository with no plans
    /// shelves everything under "Backups": there is nothing to split.
    /// `noun` leads the line with the word ("12 backups") where no row label
    /// above it says it; the bare count is the default.
    static func snapshotsLine(
        total: Int, otherBackups: Int, repositoryHasPlans: Bool, since: Date? = nil, noun: Bool = false
    ) -> String {
        var line = noun ? Format.plural(total, "backup") : Format.count(total)
        if repositoryHasPlans, otherBackups > 0 {
            line += otherBackups == total
                ? " · all in Other backups"
                : " · \(Format.count(otherBackups)) in Other backups"
        }
        // How far back the history reaches — the oldest backup's day, which
        // nothing else on the page says and which both the Backups tab's
        // list and the Files tab's picker put at the end of a long list. One
        // backup reaches no further than itself.
        if let since, total > 1 {
            line += " · since \(Format.day(since))"
        }
        return line
    }
}
