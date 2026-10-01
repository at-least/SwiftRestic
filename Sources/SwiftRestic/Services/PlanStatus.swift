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
}

/// The plan page's words, kept out of the view so they can be tested: the
/// status row for a problem that still stands, and the Next backup value.
enum PlanStatus {
    private static let retentionSkippedFact = "Retention skipped"
    static let unnamedUnreadFact = "Some source data could not be read"

    /// A run's problems as short countable facts, in a fixed order: the
    /// unreadable items (or, for a backup restic ended with exit 3 without
    /// naming any, that some source data went unread), a skipped retention
    /// step, failing hooks. The unreadable count is `itemErrorCount` —
    /// restic's items, taken before the engine stores its decoding and
    /// retention lines — never the stored line count, which would call a
    /// lock-contention retention skip (`restic forget` exit 11) "1
    /// unreadable item". Meant as the one source of these facts, so any
    /// other surface that summarises a run (Activity's Detail column) can
    /// read the same words.
    static func facts(for run: RunRecord) -> [String] {
        var facts: [String] = []
        if run.itemErrorCount > 0 {
            facts.append(Format.plural(run.itemErrorCount, "unreadable item"))
        } else if run.kind == .backup, run.exitCode == ResticError.backupPartialSuccessCode {
            // restic exited 3 and named nothing — a file count would pass
            // for a clean run, and a skipped retention step or a failing
            // hook beside it would pass for the whole story. The log keeps
            // restic's own words.
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
    /// something: a failure leads with why it failed; a warning leads with
    /// the first unreadable item, else the line that explains the warning
    /// (a decoding gap or a skipped retention step — never presented as an
    /// unreadable file), else a hook's complaint, else the banner's words
    /// for a bare exit 3.
    static func summary(of run: RunRecord) -> PlanProblemSummary {
        let explanation = run.unreadableItems.first
            ?? trailingLines(of: run).first
            ?? run.hookMessages.first
        let message: String? = if run.outcome == .failed {
            run.failureMessage ?? explanation
        } else {
            explanation ?? run.failureMessage
                ?? (run.outcome == .completedWithErrors ? RunRecord.unexplainedWarningMessage : nil)
        }

        var facts = facts(for: run)
        // A retention-only warning already says so in its message. Beside
        // any other fact the line stays, so the facts read as Activity's
        // Detail column does, word for word.
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
            facts: facts
        )
    }

    /// The plan page's Next backup value (named for the tile it once was),
    /// from the same enumeration the scheduler, the Overview's Next runs
    /// card and the tray read, so the page cannot show a date nothing will
    /// fire at. A paused plan says so instead of
    /// "Manually" — a paused manual one without promising a schedule to
    /// resume; an enabled plan the scheduler skips — no repository, a
    /// repository since removed, no folders — says it is not scheduled.
    /// A timed pause, the plan's own or the app-wide `hold`, moves the date
    /// to its end; under an open-ended hold a run already due reads
    /// "Waiting", as on the Overview's card, never "Due now".
    static func nextBackupTile(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        hold: ScheduleHold? = nil,
        now: Date = .now
    ) -> TileFace {
        guard plan.isEnabled else {
            // Removing a repository pauses all of its plans, manual ones
            // too, but a manual plan has no schedule for Resume to bring
            // back.
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
            return TileFace(value: "Manually", help: "This plan runs only when you click Back Up Now.")
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
        if let hold, next <= now {
            let when = switch hold {
            case .paused: "once backups resume"
            case .onBattery: "once this Mac is on power again"
            }
            return TileFace(value: "Waiting", help: "\(hold.summary(now: now)). This plan is due and runs \(when).")
        }
        let pauseEnd = plan.activePauseEnd(at: now)
        var namesPlanPause = pauseEnd != nil
        var namesHold = hold != nil
        if let pauseEnd, let holdEnd = hold?.resumesAt {
            // Both timed, and both read "paused until": naming both said one
            // pause twice with two times. The later end is the date, so that
            // pause is the one named — on a tie the app-wide one, which
            // covers the plan's. A hold with no end (the battery, Until I
            // Resume) sets no date and stays named beside the plan's.
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

    /// Whether a plan's sidebar row wears the pause glyph: its schedule is
    /// held, by Pause Schedule's either kind or by the editor's switch.
    static func showsPauseMarker(for plan: BackupPlan, now: Date = .now) -> Bool {
        !plan.isScheduleActive(at: now)
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

    /// The plan page's Configuration row: the sidebar's pause words, with
    /// the schedule named under either pause — the row is where the
    /// schedule is stated, so it never drops it. An open-ended pause's
    /// caption already names it (a manual plan's has none to name); a timed
    /// one's names only its end, so the schedule it resumes follows.
    static func scheduleRow(for plan: BackupPlan, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let pause = pauseCaption(for: plan, now: now, calendar: calendar) else {
            return plan.schedule.summary
        }
        guard plan.isEnabled else { return pause }
        return "\(pause) — \(plan.schedule.summary)"
    }

    /// A plan's sidebar caption. In rank: the phase of a run in flight; a
    /// standing problem, named for as long as it stands, seen or not; the
    /// pause; the last backup; the schedule. A problem and a pause are both
    /// news, so a paused plan with a standing problem gets both — the
    /// problem first, beside its glyph, and the pause on a line of its own
    /// (before, the pause took the line and an unseen problem showed only
    /// as the dot). A never-run plan the scheduler skips — no repository, a
    /// repository since removed, no folders — reads "Not scheduled", as its
    /// Next backup value does, rather than a schedule it will not keep.
    static func sidebarCaption(
        for plan: BackupPlan,
        activity: PlanActivity?,
        problem: RunRecord?,
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
            return PlanCaption(
                text: "\(problem.outcome.displayName) — \(relative(problem.finishedAt))",
                outcome: problem.outcome,
                pauseNote: pause
            )
        }
        if let pause {
            return PlanCaption(text: pause)
        }
        if let lastSuccessAt = plan.lastSuccessAt {
            return PlanCaption(text: "Last backup \(relative(lastSuccessAt))")
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
