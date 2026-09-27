import Foundation
import Testing

/// What the plan page says about a plan: the Next backup tile, which must
/// agree with the scheduler that actually fires the runs, and the status row
/// for a problem that still stands, which must count unreadable items the way
/// restic did rather than the way the record happens to store its lines.
@Suite("Plan page status")
struct PlanStatusTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let repositoryID = UUID()

    /// A daily plan the scheduler would run: named, pointed at an existing
    /// repository, with a folder, last run an hour ago.
    private func completeDailyPlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.name = "Documents"
        plan.repositoryID = repositoryID
        plan.sources = ["/Users/someone/Documents"]
        plan.schedule.frequency = .daily
        plan.lastRunAt = now.addingTimeInterval(-3600)
        return plan
    }

    // MARK: - Next backup tile

    @Test("a paused plan's Next backup tile says Paused, not Manually")
    func pausedPlanTile() {
        var plan = completeDailyPlan()
        plan.isEnabled = false

        let tile = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now)

        #expect(tile.value == "Paused")
        #expect(tile.help?.contains("Resume Schedule") == true, "help was \(String(describing: tile.help))")
        #expect(tile.help?.contains(plan.schedule.summary) == true, "help was \(String(describing: tile.help))")
    }

    @Test("a paused manual plan's tile promises no schedule to resume")
    func pausedManualPlanTile() {
        // Pause Schedule is offered on every enabled plan, and removing a
        // repository pauses all of its plans — manual ones too.
        var plan = completeDailyPlan()
        plan.schedule.frequency = .manual
        plan.isEnabled = false

        let tile = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now)

        #expect(tile.value == "Paused")
        #expect(tile.help?.contains("Resume Schedule") == false, "help was \(String(describing: tile.help))")
        #expect(tile.help?.contains("Back Up Now") == true, "help was \(String(describing: tile.help))")
    }

    @Test("an enabled plan the scheduler skips reads Not scheduled, never a date")
    func skippedPlanTile() {
        // The state removing a repository leaves behind (the plan paused,
        // its repository cleared), after Resume Schedule.
        var orphaned = completeDailyPlan()
        orphaned.repositoryID = nil
        // The old rule had a date to show for it — the one the scheduler
        // never fires.
        #expect(orphaned.schedule.nextRunDate(after: orphaned.lastRunAt, now: now) != nil)
        #expect(
            PlanStatus.nextBackupTile(for: orphaned, existingRepositoryIDs: [repositoryID], now: now).value
                == "Not scheduled"
        )

        // A repository ID the configuration no longer holds is the same skip.
        let dangling = completeDailyPlan()
        #expect(
            PlanStatus.nextBackupTile(for: dangling, existingRepositoryIDs: [UUID()], now: now).value
                == "Not scheduled"
        )
    }

    @Test("a scheduled plan's tile shows the scheduler's own date")
    func scheduledPlanTile() throws {
        let plan = completeDailyPlan()
        let scheduled = try #require(
            Scheduler.upcomingRuns(in: [plan], now: now, existingRepositoryIDs: [repositoryID]).first?.date
        )

        let tile = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now)
        #expect(tile.value == Format.tileTimestamp(scheduled, now: now))
        #expect(tile.help == Format.timestamp(scheduled))

        var manual = completeDailyPlan()
        manual.schedule.frequency = .manual
        #expect(PlanStatus.nextBackupTile(for: manual, existingRepositoryIDs: [repositoryID], now: now).value == "Manually")
    }

    // MARK: - Status row

    private func run(_ outcome: RunRecord.Outcome) -> RunRecord {
        var run = RunRecord(kind: .backup, planID: UUID(), planName: "Documents", startedAt: now.addingTimeInterval(-60))
        run.outcome = outcome
        run.finishedAt = now
        return run
    }

    @Test("a failed run leads with its failure message")
    func failedRunSummary() {
        var failed = run(.failed)
        failed.failureMessage = "Fatal: unable to open repository: the disk “NAS” is not mounted"

        let summary = PlanStatus.summary(of: failed)
        #expect(summary.headline == "Backup failed")
        #expect(summary.message == failed.failureMessage)
        #expect(summary.facts.isEmpty)
        #expect(summary.runID == failed.id)
        #expect(summary.outcome == .failed)
        #expect(summary.finishedAt == failed.finishedAt)

        // A before-hook abort: the reason the backup never started leads,
        // and the hook's own line is counted, not repeated.
        var aborted = run(.failed)
        aborted.failureMessage = "A before-backup hook failed and is set to cancel the backup."
        aborted.hookMessages = ["mount-nas.sh exited with status 1"]
        let abortSummary = PlanStatus.summary(of: aborted)
        #expect(abortSummary.message == aborted.failureMessage)
        #expect(abortSummary.facts == ["1 hook issue"])
    }

    @Test("restic's count, not the stored lines, is the unreadable count")
    func unreadableCountIsRestics() {
        // Every count here stays below 1000, so the locale's grouping
        // separator in Format.plural cannot change the strings
        // (FormattingTests' rule for locale-sensitive output).
        var partial = run(.completedWithErrors)
        let items = (1 ... 50).map { "/Users/someone/Documents/file\($0).pdf: permission denied" }
        partial.itemErrors = items + [RunRecord.retentionSkippedPrefix + "locked"]
        partial.itemErrorCount = 120

        let summary = PlanStatus.summary(of: partial)
        #expect(summary.headline == "Backup completed with errors")
        #expect(summary.message == items[0])
        #expect(summary.facts == ["120 unreadable items", "Retention skipped"])
    }

    @Test("a retention line already in history still reads as Retention skipped")
    func storedRetentionLineIsRecognised() {
        // The bytes records in config.json already carry, spelled out rather
        // than read from RunRecord.retentionSkippedPrefix: every other test
        // builds its line from the constant, so only this one fails if the
        // constant drifts and stored records silently lose their fact.
        var stored = run(.completedWithErrors)
        stored.itemErrors = [
            "open /Users/someone/Documents/Taxes/2025/locked.pdf: permission denied",
            "Retention skipped: repository is already locked by PID 4242 on demo-mac",
        ]
        stored.itemErrorCount = 1
        #expect(PlanStatus.facts(for: stored) == ["1 unreadable item", "Retention skipped"])
    }

    @Test("a warning from after-hooks alone names the hook, and a bare exit 3 still says something")
    func hookOnlyAndBareWarnings() {
        var hooked = run(.completedWithErrors)
        hooked.hookMessages = ["notify.sh exited with status 1"]
        let hookSummary = PlanStatus.summary(of: hooked)
        #expect(hookSummary.message == "notify.sh exited with status 1")
        #expect(hookSummary.facts == ["1 hook issue"])

        // restic exited 3 and named nothing: the row must not be a bare
        // headline, and it uses the banner's own words — with Activity's
        // fact under them, word for word.
        var bare = run(.completedWithErrors)
        bare.exitCode = 3
        let bareSummary = PlanStatus.summary(of: bare)
        #expect(bareSummary.message == RunRecord.unexplainedWarningMessage)
        #expect(bareSummary.facts == ["Some source data could not be read"])
    }

    @Test("an unnamed exit 3 beside a retention skip still says some data was not read")
    func unnamedExitThreeBesideARetentionSkip() {
        // The retention line explains the retention skip, not the snapshot
        // restic left short: the row must say both, in the words of
        // Activity's Detail column.
        var partial = run(.completedWithErrors)
        partial.exitCode = 3
        partial.itemErrors = [RunRecord.retentionSkippedPrefix + "repository is already locked by PID 4242 on demo-mac"]
        let summary = PlanStatus.summary(of: partial)
        #expect(summary.message == partial.itemErrors[0])
        #expect(summary.facts == ["Some source data could not be read", "Retention skipped"])
        #expect(RunRecordPresentation.detail(for: partial) == summary.facts.joined(separator: " · "))

        // Only a warning that is the retention skip alone lets its message
        // stand for the fact.
        var withHook = run(.completedWithErrors)
        withHook.exitCode = 0
        withHook.itemErrors = partial.itemErrors
        withHook.hookMessages = ["Hook “notify” exited 1"]
        let hookSummary = PlanStatus.summary(of: withHook)
        #expect(hookSummary.facts == ["Retention skipped", "1 hook issue"])
        #expect(RunRecordPresentation.detail(for: withHook) == hookSummary.facts.joined(separator: " · "))
    }

    @Test("a decoding gap leads only when nothing unreadable was named, and is never counted")
    func decodingLineIsNotAnUnreadableItem() {
        var gap = run(.completedWithErrors)
        gap.itemErrors = ["1 restic message could not be decoded — a restic update may have changed its output; the run's numbers may be incomplete."]
        gap.itemErrorCount = 0
        let summary = PlanStatus.summary(of: gap)
        #expect(summary.message == gap.itemErrors[0])
        #expect(summary.facts.isEmpty)
    }
}
