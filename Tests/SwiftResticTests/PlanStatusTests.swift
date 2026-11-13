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

    private func completeDailyPlan() -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        plan.path = "/Users/someone/Documents"
        plan.schedule.frequency = .daily
        plan.lastRunAt = now.addingTimeInterval(-3600)
        return plan
    }

    @Test("an enabled plan the scheduler skips reads Not scheduled, never a date")
    func skippedPlanTile() {
        var orphaned = completeDailyPlan()
        orphaned.repositoryID = nil
        // The schedule still computes a date for it — the one the scheduler
        // never fires; the tile must override it.
        #expect(orphaned.schedule.nextRunDate(after: orphaned.lastRunAt, now: now) != nil)
        #expect(
            PlanStatus.nextBackupTile(for: orphaned, existingRepositoryIDs: [repositoryID], now: now).value
                == "Not scheduled"
        )
        // The plan page has no Configuration card; Edit Plan is where the
        // setup is finished.
        #expect(
            PlanStatus.nextBackupTile(for: orphaned, existingRepositoryIDs: [repositoryID], now: now).help
                == "This plan isn’t scheduled because its setup is incomplete. To finish it, choose Edit Plan"
        )

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
        // The row asks when; the schedule row above it says "Manually".
        #expect(PlanStatus.nextBackupTile(for: manual, existingRepositoryIDs: [repositoryID], now: now).value
            == "When you click Back Up Now")
    }

    @Test("a backup that started this minute counts at once: the window's clock is the minute's start, earlier than the run's stamp")
    func runStampedWithinTheWindowsMinute() throws {
        // The window's now is TimelineView(.everyMinute)'s: the current
        // minute's start. A run that began 20 s into it stamps lastRunAt after
        // that now; the page read the stamp as one from a clock set ahead and
        // said Due now until the minute turned (seen in the VM, 7:49 PM).
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var plan = completeDailyPlan()
        plan.lastRunAt = minute.addingTimeInterval(20)
        let afterRun = try #require(plan.schedule.nextRunDate(after: plan.lastRunAt, now: minute.addingTimeInterval(21)))
        #expect(afterRun > minute.addingTimeInterval(60))

        let tile = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], now: minute)
        #expect(tile.value == Format.tileTimestamp(afterRun, now: minute))
        #expect(tile.value != "Due now")
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
        #expect(paused.help == "This plan is due and runs once backups resume", "help was \(String(describing: paused.help))")

        let metered = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], hold: .onMeteredNetwork, now: now)
        #expect(metered.value == "Waiting")
        #expect(metered.help == "This plan is due and runs once this Mac is on another network")
    }

    @Test("under an open-ended hold a plan not yet due reads Waiting: no date it would really run at")
    func heldFuturePlanWaits() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now

        let timed = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: now.addingTimeInterval(3_600)), now: now
        )
        #expect(timed.value != "Waiting")

        let paused = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: nil), now: now
        )
        #expect(paused.value == "Waiting")
        #expect(paused.help == "This plan runs once backups resume")

        let metered = PlanStatus.nextBackupTile(for: plan, existingRepositoryIDs: [repositoryID], hold: .onMeteredNetwork, now: now)
        #expect(metered.value == "Waiting")
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

    @Test("a timed hold names itself in the tile's help")
    func timedHoldIsNamed() {
        var plan = completeDailyPlan()
        plan.lastRunAt = now.addingTimeInterval(-2 * 86_400)
        let later = now.addingTimeInterval(7200)
        let tile = PlanStatus.nextBackupTile(
            for: plan, existingRepositoryIDs: [repositoryID], hold: .paused(until: later), now: now
        )
        #expect(tile.help == "\(Format.timestamp(later)). \(ScheduleHold.paused(until: later).summary(now: now))")
    }

    private func relative(_ date: Date) -> String { "5 minutes ago" }

    @Test("an overdue plan's sidebar row says so with the warning glyph, and a manual plan's never does")
    func overdueSidebarCaption() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var plan = completeDailyPlan()
        plan.lastSuccessAt = now.addingTimeInterval(-9 * 86_400)
        let existing = Set([plan.repositoryID].compactMap { $0 })

        let overdue = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil, existingRepositoryIDs: existing, now: now, relative: relative
        )
        #expect(overdue?.text == "Not backed up for 9 days")
        #expect(overdue?.outcome == .completedWithErrors)

        plan.schedule.frequency = .manual
        let manual = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil, existingRepositoryIDs: existing, now: now, relative: relative
        )
        #expect(manual == nil)
    }

    @Test("a plan waiting for its turn says so over its standing problem, and a run in flight over both")
    func queuedCaption() {
        let plan = completeDailyPlan()
        let waiting = PlanStatus.sidebarCaption(
            for: plan, activity: nil, isQueued: true, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(waiting == PlanCaption(text: "Waiting for another backup…"))
        let running = PlanStatus.sidebarCaption(
            for: plan, activity: PlanActivity(phase: .backingUp), isQueued: true, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(running?.text == "Backing up…")
    }

    @Test("a completed-with-errors caption has a short spelling for a narrow column; other outcomes none")
    func captionShortForm() throws {
        let plan = completeDailyPlan()
        let withErrors = try #require(PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: run(.completedWithErrors),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        ))
        #expect(withErrors.text.hasPrefix("Completed with warnings — "))
        #expect(withErrors.shortText == "Warnings — " + withErrors.text.dropFirst("Completed with warnings — ".count))
        let failed = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(failed?.shortText == nil)
    }

    @Test("a plan the scheduler skips never promises its schedule; a running one names its phase")
    func skippedAndRunningCaptions() {
        // Enabled, never backed up, no repository: the scheduler skips it,
        // and "Every day" would promise a run that never comes.
        var orphaned = completeDailyPlan()
        orphaned.repositoryID = nil
        orphaned.lastSuccessAt = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: orphaned, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            )?.text == "Not scheduled"
        )
        var fresh = completeDailyPlan()
        fresh.lastSuccessAt = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: fresh, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            ) == nil
        )
        var manual = fresh
        manual.schedule.frequency = .manual
        manual.repositoryID = nil
        #expect(
            PlanStatus.sidebarCaption(
                for: manual, activity: nil, problem: nil,
                existingRepositoryIDs: [repositoryID], now: now, relative: relative
            ) == nil
        )

        var activity = PlanActivity()
        activity.phase = .backingUp
        let running = PlanStatus.sidebarCaption(
            for: completeDailyPlan(), activity: activity, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(running == PlanCaption(text: "Backing up…", outcome: nil))
    }

    @Test("a healthy row is one line; Not scheduled shows with the warning glyph even after a backup")
    func healthyRowIsQuiet() {
        var plan = completeDailyPlan()
        plan.lastSuccessAt = now.addingTimeInterval(-3600)
        let healthy = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(healthy == nil)
        var fresh = plan
        fresh.lastSuccessAt = nil
        #expect(PlanStatus.sidebarCaption(
            for: fresh, activity: nil, problem: nil,
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        ) == nil)

        // Its repository gone: the scheduler skips it though it has a backup.
        let skipped = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: nil,
            existingRepositoryIDs: [], now: now, relative: relative
        )
        #expect(skipped == PlanCaption(text: "Not scheduled", outcome: .completedWithErrors))

        let failed = PlanStatus.sidebarCaption(
            for: plan, activity: nil, problem: run(.failed),
            existingRepositoryIDs: [repositoryID], now: now, relative: relative
        )
        #expect(failed != nil)
    }

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
        #expect(abortSummary.facts == ["1 failed script"])
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
        #expect(summary.headline == "Backup completed with warnings")
        // The card lists the first five items with their fixes and leaves
        // the rest — restic's count less the listed — to Activity; the
        // message explains what the items do not (here the retention line).
        #expect(summary.items == Array(items.prefix(5)))
        #expect(summary.unlistedItemCount == 115)
        #expect(summary.message == RunRecord.retentionSkippedOnScreenPrefix + "locked")
        #expect(summary.facts == ["120 unreadable items", "Old backups not removed"])

        // Two items: both listed, nothing left over, no message to repeat
        // them — and the count dropped from the facts, which the item list
        // below the card's facts line states outright.
        var two = run(.completedWithErrors)
        two.itemErrors = Array(items.prefix(2))
        two.itemErrorCount = 2
        let twoSummary = PlanStatus.summary(of: two)
        #expect(twoSummary.items == Array(items.prefix(2)))
        #expect(twoSummary.unlistedItemCount == 0)
        #expect(twoSummary.message == nil)
        #expect(twoSummary.facts.isEmpty)

        // The card's when-line: the problem's stretch, said as one.
        #expect(PlanStatus.standingProblemWhen(inARow: 1, ago: "2 days ago") == "2 days ago")
        #expect(PlanStatus.standingProblemWhen(inARow: 2, ago: "just now") == "2 times in a row · just now")
        #expect(PlanStatus.standingProblemWhen(inARow: 3, ago: "2 days ago") == "3 times in a row · 2 days ago")
    }

    @Test("a retention line already in history still reads as Old backups not removed")
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
        #expect(PlanStatus.facts(for: stored) == ["1 unreadable item", "Old backups not removed"])
    }

    @Test("a warning from after-hooks alone names the hook, and a bare exit 3 still says something")
    func hookOnlyAndBareWarnings() {
        var hooked = run(.completedWithErrors)
        hooked.hookMessages = ["notify.sh exited with status 1"]
        let hookSummary = PlanStatus.summary(of: hooked)
        #expect(hookSummary.message == "notify.sh exited with status 1")
        #expect(hookSummary.facts == ["1 failed script"])
        #expect(hookSummary.items.isEmpty)

        // restic exited 3 and named nothing: the row must not be a bare
        // headline, and it uses the banner's own words — with Activity's
        // fact under them, word for word.
        var bare = run(.completedWithErrors)
        bare.exitCode = 3
        let bareSummary = PlanStatus.summary(of: bare)
        #expect(bareSummary.message == RunRecord.unexplainedWarningMessage)
        #expect(bareSummary.facts == ["Some source data couldn’t be read"])
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
        #expect(summary.message == RunRecord.retentionSkippedOnScreenPrefix + "repository is already locked by PID 4242 on demo-mac")
        #expect(summary.facts == ["Some source data couldn’t be read", "Old backups not removed"])
        #expect(RunRecordPresentation.detail(for: partial) == summary.facts.joined(separator: " · "))

        // Only a warning that is the retention skip alone lets its message
        // stand for the fact.
        var withHook = run(.completedWithErrors)
        withHook.exitCode = 0
        withHook.itemErrors = partial.itemErrors
        withHook.hookMessages = ["Hook “notify” exited 1"]
        let hookSummary = PlanStatus.summary(of: withHook)
        #expect(hookSummary.facts == ["Old backups not removed", "1 failed script"])
        #expect(RunRecordPresentation.detail(for: withHook) == hookSummary.facts.joined(separator: " · "))
    }

    @Test("a decoding gap leads only when nothing unreadable was named, and is never counted")
    func decodingLineIsNotAnUnreadableItem() {
        var gap = run(.completedWithErrors)
        gap.itemErrors = ["1 restic message could not be decoded — a restic update may have changed its output; the run’s numbers may be incomplete."]
        gap.itemErrorCount = 0
        let summary = PlanStatus.summary(of: gap)
        #expect(summary.message == gap.itemErrors[0])
        #expect(summary.facts.isEmpty)
    }

    @Test("only a failed read or an away disk gives the row a second line")
    func nothingUnlessFailed() {
        #expect(PlanStatus.repositoryCaption(outcome: .idle) == nil)
        #expect(PlanStatus.repositoryCaption(outcome: .loaded) == nil)
    }

    @Test("a local repository whose drive is away says so, its whole message in the tooltip")
    func notConnectedNamesTheDrive() {
        let message = "Connect “Archive SSD” to see its backups."
        let outcome = SnapshotListingOutcome.notConnected(volume: "Archive SSD")
        let caption = PlanStatus.repositoryCaption(outcome: outcome)
        #expect(caption == .notConnected(full: message))
        #expect(caption?.text == "Not connected")
        #expect(caption?.help == message)
    }

    @Test("a read that failed keeps its first sentence, Locate or not")
    func failedKeepsItsSentence() {
        // restic's exit 10 on a local location carries Locate too, and is a
        // read that failed.
        let missing = AppModel.missingRepositoryReason(kind: .local)
        let located = SnapshotListingOutcome.failed(missing, fix: .locate(UUID()))
        #expect(PlanStatus.repositoryCaption(outcome: located) == .failed(Format.firstSentence(missing), full: missing))

        let refused = "Cannot reach nas.local: connection refused. Check the host and try again."
        let caption = PlanStatus.repositoryCaption(outcome: .failed(refused))
        #expect(caption == .failed("Cannot reach nas.local: connection refused", full: refused))
        #expect(caption?.help == refused)
    }
}

/// What every surface calls a plan, which has no name of its own.
@Suite("Plan labels")
struct PlanLabelTests {
    @Test("a plan is called by its path's last component, and two in one repository ending alike by their paths")
    func labels() {
        let home = UUID()
        var documents = BackupPlan()
        documents.repositoryID = home
        documents.path = "/Users/someone/Documents"
        var file = BackupPlan()
        file.repositoryID = home
        file.path = "/Users/someone/notes.txt"
        #expect(documents.label(among: [documents, file]) == "Documents")
        #expect(file.label(among: [documents, file]) == "notes.txt")
        var homeFolder = BackupPlan()
        homeFolder.repositoryID = home
        homeFolder.path = "~"
        #expect(homeFolder.label(among: [homeFolder]) == (NSHomeDirectory() as NSString).lastPathComponent)
        #expect(BackupPlan().label(among: []) == "Untitled Plan")

        var mine = documents
        mine.path = NSHomeDirectory() + "/Documents"
        var drive = BackupPlan()
        drive.repositoryID = home
        drive.path = "/Volumes/Archive/Documents"
        #expect(mine.label(among: [mine, drive]) == "~/Documents")
        #expect(drive.label(among: [mine, drive]) == "/Volumes/Archive/Documents")
        var elsewhere = drive
        elsewhere.repositoryID = UUID()
        #expect(mine.label(among: [mine, elsewhere]) == "Documents")
        #expect(elsewhere.label(among: [mine, elsewhere]) == "Documents")
    }
}

/// What every surface calls a repository, which has no name of its own.
@Suite("Repository labels")
struct RepositoryLabelTests {
    private func local(_ path: String) -> Repository {
        var repository = Repository()
        repository.kind = .local
        repository.localPath = path
        return repository
    }

    @Test("a repository is called by where it is: a drive's name, a folder's, a host, a bucket, a remote")
    func labels() {
        #expect(local("/Volumes/backup").label(among: []) == "backup")
        #expect(local("/Volumes/T7/restic").label(among: []) == "T7")
        #expect(local("~/Backups/restic").label(among: []) == "restic")
        var sftp = Repository()
        sftp.kind = .sftp
        sftp.sftpHost = "nas.local"
        sftp.sftpPath = "/volume1/restic"
        #expect(sftp.label(among: []) == "nas.local")
        sftp.sftpHost = "nas.local:2222"
        #expect(sftp.label(among: []) == "nas.local", "a port typed after the host is not part of its name")
        var rest = Repository()
        rest.kind = .rest
        rest.restURL = "rest:https://backup.example.com:8000/me/"
        #expect(rest.label(among: []) == "backup.example.com")
        var s3 = Repository()
        s3.kind = .s3
        s3.s3Bucket = "photos-archive"
        #expect(s3.label(among: []) == "photos-archive")
        s3.s3Bucket = "/photos-archive/mac/"
        #expect(s3.label(among: []) == "photos-archive", "a folder typed after the bucket is not part of its name")
        var rclone = Repository()
        rclone.kind = .rclone
        rclone.rcloneRemote = "gdrive:"
        rclone.rclonePath = "restic"
        #expect(rclone.label(among: []) == "gdrive")
        #expect(Repository().label(among: []) == "Untitled Location")
    }

    @Test("two repositories that would read alike each read as their location")
    func twins() {
        let t7 = local("/Volumes/T7/restic-macbook")
        let t7Again = local("/Volumes/T7/restic-imac")
        #expect(t7.label(among: [t7, t7Again]) == "/Volumes/T7/restic-macbook")
        #expect(t7Again.label(among: [t7, t7Again]) == "/Volumes/T7/restic-imac")
        var nas = Repository()
        nas.kind = .sftp
        nas.sftpHost = "nas.local"
        nas.sftpPath = "/volume1/restic"
        var nasAgain = nas
        nasAgain.id = UUID()
        nasAgain.sftpPath = "/volume2/restic"
        #expect(nas.label(among: [nas, nasAgain]) == "nas.local:/volume1/restic")
        let other = local("/Volumes/Samsung/restic")
        #expect(t7.label(among: [t7, other]) == "T7")
        // A REST server's twins read as their URLs — without the login a URL
        // saved before the login had fields of its own still carries: the
        // label is every surface's, notifications, hooks and
        // webhooks among them.
        var me = Repository()
        me.kind = .rest
        me.restURL = "rest:https://alice:s3cret@backup.example.com:8000/me/"
        var work = me
        work.id = UUID()
        work.restURL = "https://backup.example.com:8000/work/"
        #expect(me.label(among: [me, work]) == "https://backup.example.com:8000/me/")
        #expect(work.label(among: [me, work]) == "https://backup.example.com:8000/work/")
        #expect(me.displayLocation == "https://backup.example.com:8000/me/")
        // restic still gets the URL as saved, login and all.
        #expect(me.resticRepositoryString == "rest:https://alice:s3cret@backup.example.com:8000/me/")
    }
}
