import Foundation

/// The plan page's status row for the run `AppModel.currentProblem(for:)`
/// names.
struct PlanProblemSummary: Equatable, Sendable {
    let runID: RunRecord.ID
    let outcome: RunRecord.Outcome
    let finishedAt: Date
    let headline: String
    let message: String?
    let facts: [String]
    /// restic's own lines, at most `PlanStatus.listedItemLimit`; the view
    /// gives each the drawer's fixes.
    let items: [String]
    /// From restic's count, never the stored lines.
    let unlistedItemCount: Int
}

struct TileFace: Equatable, Sendable {
    let value: String
    let help: String?
}

/// A plan's sidebar row, under its name.
struct PlanCaption: Equatable, Sendable {
    var text: String
    /// Its glyph leads `text`.
    var outcome: RunRecord.Outcome?
    /// For a column too narrow for `text` ("Files skipped — 2 days ago"),
    /// tried before the middle cut.
    var shortText: String? = nil
}

/// A repository's sidebar row, under its name, after a failed read or while
/// its disk is away. `full` is the tooltip under the truncated text.
enum RepositoryCaption: Equatable, Sendable {
    /// A normal state, so it carries no glyph.
    case notConnected(full: String)
    case failed(String, full: String)

    var text: String {
        switch self {
        case .notConnected: "Not connected"
        case .failed(let line, full: _): line
        }
    }

    var help: String {
        switch self {
        case .notConnected(let full), .failed(_, let full): full
        }
    }
}

/// The plan page's words and the one "Last backup" moment
/// (`lastBackupAt`) every surface counts from, outside the view so tests
/// reach them.
enum PlanStatus {
    private static let retentionSkippedFact = "Old backups not removed"
    private static let unnamedUnreadFact = "Some files couldn’t be read"
    /// Also the Overview's count line and the Backups tab's empty state:
    /// one wording on every surface.
    static let noneFromThisPlanFact = "No backups of this folder yet."
    /// The usual run names one or two; a home folder macOS blocked in bulk
    /// is a diagnosis, not a list. The drawer holds the rest.
    private static let listedItemLimit = 5

    /// "In a row" because a success in between starts the count
    /// (`RunRecord.problemStretch`) over.
    static func standingProblemWhen(inARow count: Int, ago: String) -> String {
        count > 1 ? "\(count) times in a row · \(ago)" : ago
    }

    /// The one source of a run's problem facts, so every surface reads the
    /// same words. The unreadable count is `itemErrorCount`, never the
    /// stored line count: a lock-contention retention skip (`restic forget`
    /// exit 11) would otherwise read "1 unreadable item".
    static func facts(for run: RunRecord) -> [String] {
        var facts: [String] = []
        if run.itemErrorCount > 0 {
            facts.append(Format.plural(run.itemErrorCount, "unreadable item"))
        } else if run.kind == .backup, run.exitCode == ResticError.backupPartialSuccessCode {
            // Exit 3 with nothing named: without this fact the run would
            // pass for clean, or the retention skip for the whole story.
            facts.append(unnamedUnreadFact)
        }
        if retentionLine(of: run) != nil {
            facts.append(retentionSkippedFact)
        }
        return facts
    }

    /// Always says something. A decoding gap or skipped retention step is
    /// never presented as an unreadable file.
    static func summary(of run: RunRecord) -> PlanProblemSummary {
        // The row lists the items itself, so the message never repeats the
        // first of them; it explains what the items do not.
        let (listedItems, unlisted) = run.unreadableItemListing(limit: listedItemLimit)
        let explanation = run.trailingItemErrorsOnScreen.first
        let message: String? = if run.outcome == .failed {
            run.failureMessage ?? explanation
        } else {
            // The bare-exit-3 words only while the row lists nothing:
            // listed items are the explanation.
            explanation ?? run.failureMessage
                ?? (run.outcome == .completedWithErrors && listedItems.isEmpty ? RunRecord.unexplainedWarningMessage : nil)
        }

        var facts = facts(for: run)
        // Once every item is listed the count says nothing new; it stays
        // while items are left to Activity or none was listed.
        if !listedItems.isEmpty, unlisted == 0 {
            facts.removeAll { $0 == Format.plural(run.itemErrorCount, "unreadable item") }
        }
        // A retention-only warning says so in its message; beside any other
        // fact the line stays, matching Activity's Detail column.
        if let message, message.hasPrefix(RunRecord.retentionSkippedOnScreenPrefix), facts == [retentionSkippedFact] {
            facts = []
        }
        return PlanProblemSummary(
            runID: run.id,
            outcome: run.outcome,
            finishedAt: run.finishedAt,
            // A plan's problem is always a backup record (its forget and
            // rewrite runs never are), so the noun is fixed.
            headline: run.outcome == .completedWithErrors ? run.outcomeName : "Backup \(run.outcomeName.lowercased())",
            message: message,
            facts: facts,
            items: Array(listedItems),
            unlistedItemCount: unlisted
        )
    }

    /// Falls back to the newest snapshot's time: history a plan arrives with
    /// (adopted, or a repository added with snapshots) is still its last
    /// backup. Every "Last backup" surface reads this one moment, so they
    /// cannot disagree side by side.
    static func lastBackupAt(plan: BackupPlan, latestSnapshotTime: Date?) -> Date? {
        plan.lastSuccessAt ?? latestSnapshotTime
    }

    /// The newest run that stamped `lastSuccessAt`. The predicate must
    /// follow `markPlanRun`'s: the stamp lands once the snapshot is written,
    /// so a skipped retention (`.completedWithErrors`) and a retention
    /// stopped afterwards (`.cancelled` with a snapshot) count.
    static func lastBackupRun(planID: UUID, in runs: [RunRecord]) -> RunRecord? {
        runs
            .filter {
                $0.isBackup(ofPlan: planID)
                    && ($0.outcome == .succeeded || $0.outcome == .completedWithErrors || $0.snapshotID != nil)
            }
            .max { $0.startedAt < $1.startedAt }
    }

    /// From `Scheduler.upcomingRuns`, so the page cannot show a date nothing
    /// will fire at. Under an open-ended hold no date is promised.
    static func nextBackupTile(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        hold: ScheduleHold? = nil,
        isBackingUp: Bool = false,
        now: Date = .now
    ) -> TileFace {
        guard plan.isScheduled else {
            // Not "Manually": the row asks when; the schedule row above
            // says how.
            return TileFace(value: "When you click Back Up Now", help: nil)
        }
        guard let next = Scheduler.upcomingRuns(
            in: [plan],
            now: now,
            existingRepositoryIDs: existingRepositoryIDs,
            heldUntil: hold?.resumesAt
        ).first?.date else {
            return TileFace(
                value: "Not scheduled",
                help: "This plan isn’t scheduled because its setup is incomplete. To finish it, choose Edit Plan"
            )
        }
        // Nothing stamps the slot until the run ends, so "Running now" must
        // win over "Waiting" and "Due now"; a Back Up Now under a hold also
        // stamps the slot.
        if isBackingUp, next <= now {
            return TileFace(value: "Running now", help: nil)
        }
        if let hold, next <= now || hold.resumesAt == nil {
            let when = switch hold {
            case .paused: "once backups resume"
            case .onMeteredNetwork: "once this Mac is on another network"
            }
            return TileFace(value: "Waiting", help: "This plan \(next <= now ? "is due and runs" : "runs") \(when)")
        }
        var help = Format.timestamp(next)
        if let hold {
            help += ". \(hold.summary(now: now))"
        }
        return TileFace(value: Format.tileTimestamp(next, now: now), help: help)
    }

    /// Nil for a manual plan: never running by itself is its chosen mode.
    static func willNotRunCaption(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        now: Date = .now
    ) -> String? {
        guard plan.isScheduled else { return nil }
        if Scheduler.upcomingRuns(in: [plan], now: now, existingRepositoryIDs: existingRepositoryIDs).isEmpty {
            return "Not scheduled"
        }
        return nil
    }

    /// A standing problem is named for as long as it stands, seen or not.
    /// Nil keeps the row one line. The caption carries no next run: that
    /// stays with the surfaces that act on it (the plan page, the tray,
    /// Settings).
    static func sidebarCaption(
        for plan: BackupPlan,
        activity: PlanActivity?,
        isQueued: Bool = false,
        problem: RunRecord?,
        latestSnapshot: Snapshot? = nil,
        existingRepositoryIDs: Set<UUID>,
        now: Date = .now,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> PlanCaption? {
        if let activity {
            return PlanCaption(text: activity.phase.displayName)
        }
        if isQueued {
            return PlanCaption(text: "Waiting for another backup…")
        }
        if let problem {
            let when = relative(problem.finishedAt)
            let name = problem.outcomeName
            return PlanCaption(
                text: "\(name) — \(when)",
                outcome: problem.outcome,
                // The one name whose words outgrow the column.
                shortText: name == RunRecord.someFilesSkipped ? "Files skipped — \(when)" : nil
            )
        }
        let lastBackupAt = lastBackupAt(plan: plan, latestSnapshotTime: latestSnapshot?.time)
        if let lastBackupAt, StaleAlert.isOverdue(plan, lastBackupAt: lastBackupAt, now: now) {
            return PlanCaption(text: StaleAlert.overdueLine(since: lastBackupAt, now: now), outcome: .completedWithErrors)
        }
        if let willNotRun = willNotRunCaption(for: plan, existingRepositoryIDs: existingRepositoryIDs, now: now) {
            return PlanCaption(text: willNotRun, outcome: .completedWithErrors)
        }
        return nil
    }

    static func repositoryCaption(outcome: SnapshotListingOutcome) -> RepositoryCaption? {
        if case let .notConnected(volume) = outcome {
            return .notConnected(full: SnapshotListingOutcome.connectText(volume: volume))
        }
        guard let message = outcome.failureMessage else { return nil }
        return .failed(Format.firstSentence(message), full: message)
    }

    /// Trailing lines only, so an unreadable item's own text never passes
    /// for it.
    private static func retentionLine(of run: RunRecord) -> String? {
        run.trailingItemErrors.first { $0.hasPrefix(RunRecord.retentionSkippedPrefix) }
    }
}
