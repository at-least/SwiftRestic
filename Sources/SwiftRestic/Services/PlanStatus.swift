import Foundation

/// What the plan page's status row says about the plan's standing problem —
/// the run `AppModel.currentProblem(for:)` names.
struct PlanProblemSummary: Equatable, Sendable {
    let runID: RunRecord.ID
    let outcome: RunRecord.Outcome
    let finishedAt: Date
    let headline: String
    let message: String?
    let facts: [String]
    /// The unreadable items the card lists, restic's own lines, at most
    /// `PlanStatus.listedItemLimit` of them, each with the drawer's fixes.
    let items: [String]
    /// How many unreadable items the card leaves to Activity — from
    /// restic's count, never the stored lines.
    let unlistedItemCount: Int
}

/// A stat tile's face: the value on it and the tooltip behind it.
struct TileFace: Equatable, Sendable {
    let value: String
    let help: String?
}

/// What a plan's sidebar row says under its name.
struct PlanCaption: Equatable, Sendable {
    /// The row's news: the running phase, a standing problem, the pause,
    /// the last backup or the schedule.
    var text: String
    /// The standing problem's outcome, whose glyph leads `text`.
    var outcome: RunRecord.Outcome?
    /// The pause, on a line of its own, when a standing problem took the
    /// first one — so neither state hides the other.
    var pauseNote: String?
    /// A shorter spelling of `text` for a column too narrow for it —
    /// "Errors — 2 days ago" for "Completed with errors — 2 days ago" —
    /// tried before the middle cut that reads "Completed with…rors". Nil
    /// when no shorter form exists.
    var shortText: String? = nil
}

/// The plan page's words and the app's one "Last backup" moment, kept out
/// of the view so they can be tested: the status row for a problem that
/// still stands, the Next backup value, the sidebar caption, and the
/// moment (`lastBackupAt`) every surface's "Last backup" counts from.
enum PlanStatus {
    private static let retentionSkippedFact = "Retention skipped"
    static let unnamedUnreadFact = "Some source data could not be read"
    /// How many unreadable items the plan page's card lists; the drawer
    /// holds the rest. Five: the usual run names one or two, and a home
    /// folder macOS blocked in bulk is a diagnosis, not a list.
    static let listedItemLimit = 5

    /// The card's when-line: the week's count of this problem in the
    /// Recent problems card's words ("3 times · 2 days ago",
    /// `OverviewMetrics.recurrences`), else the moment alone.
    static func problemWhen(count: Int, ago: String) -> String {
        count > 1 ? "\(count) times · \(ago)" : ago
    }

    /// A run's problems as short countable facts, in a fixed order: the
    /// unreadable items (or, for a backup restic ended with exit 3 without
    /// naming any, that some source data went unread), a skipped retention
    /// step, failing hooks. The unreadable count is `itemErrorCount` —
    /// restic's items, taken before the engine stores its decoding and
    /// retention lines — never the stored line count, which would call a
    /// lock-contention retention skip (`restic forget` exit 11) "1
    /// unreadable item". The one source of these facts, so every surface
    /// that summarises a run reads the same words.
    static func facts(for run: RunRecord) -> [String] {
        var facts: [String] = []
        if run.itemErrorCount > 0 {
            facts.append(Format.plural(run.itemErrorCount, "unreadable item"))
        } else if run.kind == .backup, run.exitCode == ResticError.backupPartialSuccessCode {
            // restic exited 3 and named nothing: a file count would pass for
            // a clean run, and a skipped retention step or a failing hook
            // would pass for the whole story. The log keeps restic's own
            // words.
            facts.append(unnamedUnreadFact)
        }
        if retentionLine(of: run) != nil {
            facts.append(retentionSkippedFact)
        }
        if !run.hookMessages.isEmpty {
            facts.append(Format.plural(run.hookMessages.count, "hook issue"))
        }
        return facts
    }

    /// The row for a failed or completed-with-errors backup. It always says
    /// something: a failure leads with why it failed; a warning with the
    /// first unreadable item, else the line that explains the warning
    /// (a decoding gap or a skipped retention step — never presented as an
    /// unreadable file), else a hook's complaint, else the banner's words
    /// for a bare exit 3.
    static func summary(of run: RunRecord) -> PlanProblemSummary {
        // The card lists the unreadable items (each with Reveal and
        // Exclude, as the drawer's lines), so the message never repeats
        // the first of them: it explains the warning past the items — a
        // decoding gap, a skipped retention step — or a hook's complaint.
        let (listedItems, unlisted) = run.unreadableItemListing(limit: listedItemLimit)
        let explanation = trailingLines(of: run).first
            ?? run.hookMessages.first
        let message: String? = if run.outcome == .failed {
            run.failureMessage ?? explanation
        } else {
            // The banner's words for a bare exit 3 — only while the card
            // lists nothing: listed items are the explanation.
            explanation ?? run.failureMessage
                ?? (run.outcome == .completedWithErrors && listedItems.isEmpty ? RunRecord.unexplainedWarningMessage : nil)
        }

        var facts = facts(for: run)
        // A retention-only warning already says so in its message; beside
        // any other fact the line stays, so the facts read as Activity's
        // Detail column does.
        if let message, message == retentionLine(of: run), facts == [retentionSkippedFact] {
            facts = []
        }
        return PlanProblemSummary(
            runID: run.id,
            outcome: run.outcome,
            finishedAt: run.finishedAt,
            // A plan's problem is a backup record: the backup engine is the
            // only writer that stamps a planID on a run, so the noun is fixed.
            headline: "Backup \(run.outcome.displayName.lowercased())",
            message: message,
            facts: facts,
            items: Array(listedItems),
            unlistedItemCount: unlisted
        )
    }

    /// The moment a plan's "Last backup" says — the run's stamp when the
    /// app ran it, else its newest snapshot's own time: history a plan
    /// arrives with (adopted, or a repository added with its snapshots
    /// already in it) is still its last backup. The sidebar caption, the
    /// repository page's Protection line and the plan page's Last backup
    /// row all read this one moment, so the same backup cannot read three
    /// ways side by side.
    static func lastBackupAt(plan: BackupPlan, latestSnapshot: Snapshot?) -> Date? {
        plan.lastSuccessAt ?? latestSnapshot?.time
    }

    /// The run the plan page's Last backup value lands on: the newest
    /// backup that stamped `lastSuccessAt` — the moment `lastBackupAt`
    /// names while the plan's history is runs of its own; history that
    /// arrived with the repository has no run to land on. The predicate
    /// follows `markPlanRun`'s: the stamp lands once the snapshot is
    /// written, so a run whose after-hooks then failed counts
    /// (`.completedWithErrors`), and so does one whose retention was
    /// stopped afterwards (`.cancelled`, snapshot written); a failed run,
    /// or one stopped before its snapshot, never stamped.
    static func lastBackupRun(planID: UUID, in runs: [RunRecord]) -> RunRecord? {
        runs
            .filter {
                $0.planID == planID && $0.kind == .backup
                    && ($0.outcome == .succeeded || $0.outcome == .completedWithErrors || $0.snapshotID != nil)
            }
            .max { $0.startedAt < $1.startedAt }
    }

    /// The plan page's Next backup value, from the same enumeration the
    /// scheduler and the tray read, so the page cannot show a date nothing
    /// will fire at. A paused plan says so instead of "Manually" — a paused
    /// manual one without promising a schedule to resume; an enabled plan
    /// the scheduler skips — no folders, or a repository it cannot find —
    /// says it is not scheduled. A timed pause, the plan's own or the
    /// app-wide `hold`, moves the date to its end; under an open-ended hold
    /// a due run reads "Waiting", never "Due now". A due slot whose backup
    /// is in flight reads "Running now".
    /// The plan editor's Schedule tab: the Next backup tile of the plan as
    /// Save would store it — the stored plan's run stamps and pause under
    /// the draft's schedule (`merging(draft:)`) — so the editor cannot
    /// promise a run the page will not show once saved. Nil where the tab
    /// already speaks: a manual or switched-off schedule, a timed pause
    /// (its own line), and a setup the footer says is incomplete.
    static func editorNextBackup(
        draft: BackupPlan,
        stored: BackupPlan?,
        existingRepositoryIDs: Set<UUID>,
        hold: ScheduleHold? = nil,
        isBackingUp: Bool = false,
        now: Date = .now
    ) -> TileFace? {
        let plan = stored?.merging(draft: draft) ?? draft
        guard plan.isEnabled, plan.schedule.frequency != .manual,
              plan.activePauseEnd(at: now) == nil, plan.isConfigurationComplete
        else { return nil }
        return nextBackupTile(
            for: plan, existingRepositoryIDs: existingRepositoryIDs, hold: hold, isBackingUp: isBackingUp, now: now
        )
    }

    static func nextBackupTile(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        hold: ScheduleHold? = nil,
        isBackingUp: Bool = false,
        now: Date = .now
    ) -> TileFace {
        guard plan.isEnabled else {
            // A manual plan has no schedule for Resume to bring back.
            if plan.schedule.frequency == .manual {
                return TileFace(
                    value: "Paused",
                    help: "This plan has no schedule to resume — it runs only when you click Back Up Now."
                )
            }
            return TileFace(
                value: "Paused",
                help: "Scheduled runs are paused (\(plan.schedule.summary)). Resume Schedule to run on it again — Back Up Now still works."
            )
        }
        guard plan.schedule.frequency != .manual else {
            // The row asks when; "Manually" answered how. The schedule row
            // above it keeps the word.
            return TileFace(value: "When you click Back Up Now", help: "This plan runs only when you click Back Up Now.")
        }
        guard let next = Scheduler.upcomingRuns(
            in: [plan],
            now: now,
            existingRepositoryIDs: existingRepositoryIDs,
            heldUntil: hold?.resumesAt
        ).first?.date else {
            return TileFace(
                value: "Not scheduled",
                help: "The scheduler skips this plan until its setup is complete — see Configuration below."
            )
        }
        // Nothing stamps the slot until the run ends, so "Running now"
        // must beat "Waiting" and the "Due now" below — a Back Up Now
        // under a hold runs and stamps the slot too.
        if isBackingUp, next <= now {
            return TileFace(value: "Running now", help: "This plan is backing up now.")
        }
        if let hold, next <= now {
            let when = switch hold {
            case .paused: "once backups resume"
            case .onBattery: "once this Mac is on power again"
            case .onMeteredNetwork: "once this Mac is on another network"
            }
            return TileFace(value: "Waiting", help: "\(hold.summary(now: now)). This plan is due and runs \(when).")
        }
        let pauseEnd = plan.activePauseEnd(at: now)
        var namesPlanPause = pauseEnd != nil
        var namesHold = hold != nil
        if let pauseEnd, let holdEnd = hold?.resumesAt {
            // Both timed, and both read "paused until": naming both would
            // say one pause twice with two times. The later end is the
            // date, so that pause is the one named — on a tie the app-wide
            // one, which covers the plan's. A hold with no end (the
            // battery, Until I Resume) sets no date and stays named beside
            // the plan's.
            namesPlanPause = pauseEnd > holdEnd
            namesHold = !namesPlanPause
        }
        var help = Format.timestamp(next)
        if namesPlanPause, let pauseEnd {
            help += " — scheduled runs are paused until \(Format.pauseEnd(pauseEnd, now: now))"
        }
        if namesHold, let hold {
            help += ". \(hold.summary(now: now))."
        }
        return TileFace(value: Format.tileTimestamp(next, now: now), help: help)
    }

    /// The pause as the sidebar words it, `nil` while the schedule runs: a
    /// timed pause names its end, an open-ended one the schedule it holds —
    /// a manual plan's none, since it has no schedule to hold ("Paused",
    /// as its Next backup value says, never "Paused — Manually").
    static func pauseCaption(for plan: BackupPlan, now: Date = .now, calendar: Calendar = .current) -> String? {
        if !plan.isEnabled {
            return plan.schedule.frequency == .manual ? "Paused" : "Paused — \(plan.schedule.summary)"
        }
        if let end = plan.activePauseEnd(at: now) {
            return "Paused until \(Format.pauseEnd(end, now: now, calendar: calendar))"
        }
        return nil
    }

    /// Why a scheduled plan will not run by itself now, for the Protection
    /// card: its pause in the sidebar's words, else "Not scheduled" when
    /// the scheduler skips it (the sidebar's and Next backup's word). Nil
    /// while it will, and for a manual plan, which never does — paused or
    /// not, that is its chosen mode.
    static func willNotRunCaption(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String? {
        guard plan.schedule.frequency != .manual else { return nil }
        if let pause = pauseCaption(for: plan, now: now, calendar: calendar) { return pause }
        if Scheduler.upcomingRuns(in: [plan], now: now, existingRepositoryIDs: existingRepositoryIDs).isEmpty {
            return "Not scheduled"
        }
        return nil
    }

    /// The plan page's Configuration row: the sidebar's pause words, with
    /// the schedule named under a pause — the row is where the schedule is
    /// stated, so it never drops it. An open-ended pause's caption already
    /// names it (a manual plan's has none); a timed one's names only its
    /// end, so the schedule it resumes follows.
    static func scheduleRow(for plan: BackupPlan, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let pause = pauseCaption(for: plan, now: now, calendar: calendar) else {
            return plan.schedule.summary
        }
        guard plan.isEnabled else { return pause }
        return "\(pause) — \(plan.schedule.summary)"
    }

    /// A plan's sidebar caption. In rank: a run in flight's phase; a
    /// standing problem, named for as long as it stands, seen or not; the
    /// pause; the last backup; the schedule. A problem and a pause are both
    /// news, so a paused plan with a standing problem gets both — the
    /// problem first, beside its glyph, the pause on a line of its own. The
    /// last backup is `lastBackupAt`'s one moment, so history a plan
    /// arrived with counts here as well. A plan with no backup that the
    /// scheduler skips — no folders, or a repository it cannot find — reads
    /// "Not scheduled", as its Next backup value does, rather than a
    /// schedule it will not keep.
    ///
    /// The caption carries no next run: the sidebar says only the last
    /// backup, and a plan's next run stays with the surfaces that act on
    /// it — the plan page's Next backup value, the tray and Settings.
    static func sidebarCaption(
        for plan: BackupPlan,
        activity: PlanActivity?,
        problem: RunRecord?,
        latestSnapshot: Snapshot? = nil,
        existingRepositoryIDs: Set<UUID>,
        now: Date = .now,
        calendar: Calendar = .current,
        relative: (Date) -> String = { Format.relative($0) }
    ) -> PlanCaption {
        if let activity {
            return PlanCaption(text: activity.phase.displayName)
        }
        let pause = pauseCaption(for: plan, now: now, calendar: calendar)
        if let problem {
            let when = relative(problem.finishedAt)
            return PlanCaption(
                text: "\(problem.outcome.displayName) — \(when)",
                outcome: problem.outcome,
                pauseNote: pause,
                // The one outcome whose words outgrow the column; the glyph
                // beside them carries the severity either way.
                shortText: problem.outcome == .completedWithErrors ? "Errors — \(when)" : nil
            )
        }
        if let pause {
            return PlanCaption(text: pause)
        }
        if let lastBackupAt = lastBackupAt(plan: plan, latestSnapshot: latestSnapshot) {
            return PlanCaption(text: "Last backup \(relative(lastBackupAt))")
        }
        if plan.schedule.frequency != .manual,
           Scheduler.upcomingRuns(in: [plan], now: now, existingRepositoryIDs: existingRepositoryIDs).isEmpty
        {
            return PlanCaption(text: "Not scheduled")
        }
        return PlanCaption(text: plan.schedule.summary)
    }

    /// The lines stored after the unreadable items: the decoding-gap warning,
    /// then the retention line (`RunRecord.itemErrors`' order).
    private static func trailingLines(of run: RunRecord) -> ArraySlice<String> {
        run.itemErrors.dropFirst(run.unreadableItems.count)
    }

    /// Searched among the trailing lines only, so an unreadable item's own
    /// text can never pass for it.
    private static func retentionLine(of run: RunRecord) -> String? {
        trailingLines(of: run).first { $0.hasPrefix(RunRecord.retentionSkippedPrefix) }
    }
}
