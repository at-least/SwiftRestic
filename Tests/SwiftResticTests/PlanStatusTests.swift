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
        // The editor's "Run on schedule" switch is on every plan, manual
        // ones included.
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
        // A plan whose repository is gone, still enabled: the scheduler
        // skips it.
        var orphaned = completeDailyPlan()
        orphaned.repositoryID = nil
        // The schedule still computes a date for it — the one the scheduler
        // never fires; the tile must override it.
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

    @Test("an overdue plan under an open-ended hold reads Waiting, never Due now")
    func heldOverduePlanWaits() {
        var plan = completeDailyPlan()
        // Last ran two days ago: its 02:00 slot is overdue.
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)

        let unheld = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now)
        #expect(unheld.value == "Due now")

        let paused = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: nil), now: now
        )
        #expect(paused.value == "Waiting")
        #expect(paused.help?.contains("Backups paused until you resume") == true, "help was \(String(describing: paused.help))")

        let battery = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], hold: .onBattery, now: now)
        #expect(battery.value == "Waiting")
        #expect(battery.help?.contains("battery") == true, "help was \(String(describing: battery.help))")
    }

    @Test("a due plan whose backup is running reads Running now, never Due now")
    func runningDuePlan() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)

        // The scheduler started the due run, and until it ends nothing
        // stamps the slot: the tile must read Running now over it, not Due
        // now beside the sidebar's spinner.
        let running = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], isBackingUp: true, now: now
        )
        #expect(running.value == "Running now")
        // A Back Up Now while backups are held runs too, and stamps the slot.
        let held = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: nil), isBackingUp: true, now: now
        )
        #expect(held.value == "Running now")

        // A run in flight says nothing about a slot that is not due yet.
        var notDue = completeDailyPlan()
        notDue.lastRunAt = now
        let ahead = PlanStatus.nextBackupTile(
            for: notDue, existingRepositoryIDs: [repositoryID], isBackingUp: true, now: now
        )
        #expect(ahead.value == PlanStatus.nextBackupTile(
            for: notDue, existingRepositoryIDs: [repositoryID], now: now
        ).value)
        #expect(ahead.value != "Running now")
    }

    @Test("Last backup lands on the run that stamped it — one whose retention was stopped too")
    func lastBackupRunIsTheStampedOne() {
        let planID = UUID()
        func backup(_ minutesAgo: Double, _ outcome: RunRecord.Outcome, snapshot: String?) -> RunRecord {
            var run = RunRecord(kind: .backup, planName: "Docs", startedAt: now.addingTimeInterval(-minutesAgo * 60))
            run.planID = planID
            run.outcome = outcome
            run.snapshotID = snapshot
            return run
        }
        let older = backup(120, .succeeded, snapshot: "aaaa")
        // Its snapshot was written and stamped lastSuccessAt; then the user
        // stopped the retention that followed, and the record reads
        // cancelled. The value says this run's time, so the landing must be
        // this run, not the one before it.
        let retentionStopped = backup(60, .cancelled, snapshot: "bbbb")
        #expect(PlanStatus.lastBackupRun(planID: planID, in: [older, retentionStopped])?.id == retentionStopped.id)

        // Neither of these ever stamped: a run stopped before its snapshot,
        // and a failed one.
        let stoppedEarly = backup(30, .cancelled, snapshot: nil)
        let failed = backup(10, .failed, snapshot: nil)
        #expect(PlanStatus.lastBackupRun(planID: planID, in: [older, stoppedEarly, failed])?.id == older.id)
    }

    @Test("a timed app-wide hold moves the tile to the hold's end")
    func timedHoldClampsTile() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)
        let end = now.addingTimeInterval(3600)

        let tile = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: end), now: now
        )
        #expect(tile.value == Format.tileTimestamp(end, now: now))
        #expect(tile.help?.hasPrefix(Format.timestamp(end)) == true, "help was \(String(describing: tile.help))")
    }

    @Test("a plan's own timed pause moves its tile to the pause's end and says so")
    func ownTimedPauseClampsTile() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)
        let end = now.addingTimeInterval(5400)
        plan.pausedUntil = end

        let tile = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now)
        #expect(tile.value == Format.tileTimestamp(end, now: now))
        #expect(
            tile.help == "\(Format.timestamp(end)) — scheduled runs are paused until \(Format.pauseEnd(end, now: now))",
            "help was \(String(describing: tile.help))"
        )
    }

    @Test("a plan paused inside an app-wide pause names the pause that sets its date, once")
    func overlappingPausesNameOne() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)
        let sooner = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(7200)

        // The plan's own pause outlasts the app-wide one and sets the date;
        // the help must not name the same pause twice.
        plan.pausedUntil = later
        let own = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: sooner), now: now
        )
        #expect(own.value == Format.tileTimestamp(later, now: now))
        #expect(own.help == "\(Format.timestamp(later)) — scheduled runs are paused until \(Format.pauseEnd(later, now: now))")

        // The app-wide pause outlasts the plan's and sets the date.
        plan.pausedUntil = sooner
        let appWide = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: later), now: now
        )
        #expect(appWide.value == Format.tileTimestamp(later, now: now))
        #expect(appWide.help == "\(Format.timestamp(later)). \(ScheduleHold.paused(until: later).summary(now: now)).")

        // The battery names no end, and says something else: both stay.
        let battery = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .onBattery, now: now
        )
        #expect(
            battery.help
                == "\(Format.timestamp(sooner)) — scheduled runs are paused until \(Format.pauseEnd(sooner, now: now)). \(ScheduleHold.onBattery.summary(now: now))."
        )
    }

    // MARK: - Sidebar caption

    private func relative(_ date: Date) -> String { "5 minutes ago" }

    @Test("a paused manual plan's caption names no schedule, as its tile does")
    func pausedManualPlanCaption() {
        // A switched-off manual plan must not read "Paused — Manually": a
        // schedule it does not have.
        var plan = completeDailyPlan()
        plan.schedule.frequency = .manual
        plan.isEnabled = false

        let caption = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(caption.text == "Paused")
        #expect(caption.text == PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: now).value)

        // Beside a standing problem it keeps its own line, in the same word.
        let withProblem = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(withProblem.pauseNote == "Paused")
    }

    @Test("a paused plan with a standing problem names both, the problem first")
    func pausedProblemNamesBoth() {
        var plan = completeDailyPlan()
        plan.isEnabled = false
        let failed = run(.failed)

        let caption = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: failed,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(caption.text == "Failed — 5 minutes ago")
        #expect(caption.outcome == .failed)
        #expect(caption.pauseNote == "Paused — Daily at 02:00")

        // Unpaused, the problem stands alone.
        plan.isEnabled = true
        let unpaused = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: failed,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(unpaused.pauseNote == nil)
    }

    @Test("the Configuration row names the schedule under either pause, from the sidebar's words")
    func scheduleRowUnderPause() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var plan = completeDailyPlan()
        #expect(PlanStatus.scheduleRow(for: plan, now: now, calendar: calendar) == plan.schedule.summary)

        // Until I Resume: the sidebar's own caption, which names the schedule.
        plan.isEnabled = false
        let openEnded = PlanStatus.scheduleRow(for: plan, now: now, calendar: calendar)
        #expect(openEnded == "Paused — \(plan.schedule.summary)")
        #expect(openEnded == PlanStatus.pauseCaption(for: plan, now: now, calendar: calendar))

        // A timed pause: the sidebar's end, then the schedule it resumes.
        plan.isEnabled = true
        plan.pausedUntil = now.addingTimeInterval(3600)
        let end = Format.pauseEnd(now.addingTimeInterval(3600), now: now, calendar: calendar)
        #expect(PlanStatus.scheduleRow(for: plan, now: now, calendar: calendar) == "Paused until \(end) — \(plan.schedule.summary)")

        // A manual plan switched off has no schedule to name.
        var manual = completeDailyPlan()
        manual.schedule.frequency = .manual
        manual.isEnabled = false
        #expect(PlanStatus.scheduleRow(for: manual, now: now, calendar: calendar) == "Paused")
    }

    @Test("a timed pause names its end; a lapsed one reads as no pause")
    func timedPauseCaption() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var plan = completeDailyPlan()
        plan.lastSuccessAt = now.addingTimeInterval(-3600)
        plan.pausedUntil = now.addingTimeInterval(3600)

        let paused = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, calendar: calendar, relative: relative
        )
        #expect(paused.text == "Paused until \(Format.pauseEnd(now.addingTimeInterval(3600), now: now, calendar: calendar))")
        #expect(paused.outcome == nil)
        #expect(paused.pauseNote == nil)

        plan.pausedUntil = now.addingTimeInterval(-1)
        let lapsed = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, calendar: calendar, relative: relative
        )
        // The pause lapsed, so the schedule is live again: the plain
        // last-backup line, no next run beside it.
        #expect(lapsed.text == "Last backup 5 minutes ago")
        #expect(lapsed.pauseNote == nil)
    }

    @Test("the caption's plain state is the last backup alone, with the schedule active")
    func captionIsLastBackupOnly() {
        // The sidebar says only the last backup: a scheduled, active plan
        // with a last backup reads the bare line, no next run appended —
        // PlanCaption has no field a next run could ride in on.
        var plan = completeDailyPlan()
        plan.lastSuccessAt = now.addingTimeInterval(-3600)
        let caption = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(caption.text == "Last backup 5 minutes ago")
        #expect(caption == PlanCaption(text: "Last backup 5 minutes ago", outcome: nil, pauseNote: nil))
    }

    @Test("a plan the scheduler skips never promises its schedule; a running one names its phase")
    func skippedAndRunningCaptions() {
        // Enabled, never backed up, no repository: the scheduler skips it,
        // and "Daily at 02:00" would promise a run that never comes.
        var orphaned = completeDailyPlan()
        orphaned.repositoryID = nil
        orphaned.lastSuccessAt = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: orphaned, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            ).text == "Not scheduled"
        )
        var fresh = completeDailyPlan()
        fresh.lastSuccessAt = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: fresh, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            ).text == "Daily at 02:00"
        )
        var manual = fresh
        manual.schedule.frequency = .manual
        manual.repositoryID = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: manual, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            ).text == "Manually"
        )

        var activity = PlanActivity()
        activity.phase = .backingUp
        var pausedRunning = completeDailyPlan()
        pausedRunning.isEnabled = false
        let running = PlanStatus.sidebarCaption(
            for: pausedRunning, activity: activity, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(running == PlanCaption(text: "Backing up", outcome: nil, pauseNote: nil))
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
