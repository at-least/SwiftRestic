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

/// The plan page's words, kept out of the view so they can be tested: the
/// status row for a problem that still stands, and the Next backup tile.
enum PlanStatus {
    private static let retentionSkippedFact = "Retention skipped"
    private static let unnamedUnreadFact = "Some source data could not be read"

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

    /// The Next backup tile, from the same enumeration the scheduler, the
    /// Overview's Next runs card and the tray read, so the tile cannot show
    /// a date nothing will fire at. A paused plan says so instead of
    /// "Manually" — a paused manual one without promising a schedule to
    /// resume; an enabled plan the scheduler skips — no repository, a
    /// repository since removed, no folders — says it is not scheduled.
    static func nextBackupTile(
        for plan: BackupPlan,
        existingRepositoryIDs: Set<UUID>,
        now: Date = .now
    ) -> TileFace {
        guard plan.isEnabled else {
            // Pause Schedule is offered on every plan, and removing a
            // repository pauses all of its plans, but a manual plan has no
            // schedule for Resume to bring back.
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
            existingRepositoryIDs: existingRepositoryIDs
        ).first?.date else {
            return TileFace(
                value: "Not scheduled",
                help: "The scheduler skips this plan until its setup is complete — see Configuration below."
            )
        }
        return TileFace(value: Format.tileTimestamp(next, now: now), help: Format.timestamp(next))
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
