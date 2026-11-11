import Foundation
import Testing

@Suite("Scheduling")
struct SchedulingTests {
    @Test("a manual plan is never due")
    func manualNeverDue() {
        var schedule = Schedule()
        schedule.frequency = .manual
        #expect(schedule.nextRunDate(after: nil, now: utcDate("2026-09-05 12:00:00")) == nil)
    }

    @Test("a scheduled plan that has never run is due immediately")
    func firstRunIsDueNow() {
        var schedule = Schedule()
        let now = utcDate("2026-09-05 12:00:00")
        for frequency in [Schedule.Frequency.hourly, .daily, .weekly] {
            schedule.frequency = frequency
            #expect(schedule.nextRunDate(after: nil, now: now) == now, "\(frequency)")
        }
    }

    @Test("a plan waits its interval after the last run: an hour, a day, a week")
    func intervalAfterLastRun() {
        var schedule = Schedule()
        let lastRun = utcDate("2026-09-05 08:00:00")
        let now = utcDate("2026-09-05 08:30:00")
        for (frequency, next) in [
            (Schedule.Frequency.hourly, "2026-09-05 09:00:00"),
            (.daily, "2026-09-06 08:00:00"),
            (.weekly, "2026-09-12 08:00:00"),
        ] {
            schedule.frequency = frequency
            #expect(schedule.nextRunDate(after: lastRun, now: now) == utcDate(next), "\(frequency)")
        }
    }

    @Test("a daily plan that missed its day while the Mac slept is due as soon as it is awake")
    func dailyCatchesUp() throws {
        var schedule = Schedule()
        schedule.frequency = .daily
        let now = utcDate("2026-09-07 09:30:00")
        let next = try #require(schedule.nextRunDate(after: utcDate("2026-09-04 22:00:00"), now: now))
        #expect(next <= now)
    }

    /// A clock set ahead stamps the run in the future; corrected, the stamp
    /// would hold the plan back until that future date.
    @Test("a last run stamped after now, from a clock set ahead and corrected, counts as no run")
    func futureLastRunIsNoRun() {
        let now = utcDate("2026-09-05 12:00:00")
        let ahead = utcDate("2027-09-05 12:00:00")
        var schedule = Schedule()
        for frequency in [Schedule.Frequency.hourly, .daily, .weekly] {
            schedule.frequency = frequency
            let due = schedule.nextRunDate(after: ahead, now: now)
            let fresh = schedule.nextRunDate(after: nil, now: now)
            #expect(due == fresh, "\(frequency)")
            // Past the window clock's lag a stamp is a clock's, not this minute's run.
            let justPast = now.addingTimeInterval(Schedule.windowClockLag + 1)
            #expect(schedule.nextRunDate(after: justPast, now: now) == fresh, "\(frequency)")
        }
    }

    @Test("a stored time of day or weekday is ignored: only how often is read")
    func storedTimeOfDayIsIgnored() throws {
        let schedule = try JSONDecoder().decode(
            Schedule.self, from: Data(#"{"frequency":"weekly","hour":3,"minute":30,"weekday":1}"#.utf8)
        )
        #expect(schedule.frequency == .weekly)
        let lastRun = utcDate("2026-09-05 08:00:00")
        #expect(schedule.nextRunDate(after: lastRun, now: lastRun) == utcDate("2026-09-12 08:00:00"))
    }

    @Test("only enabled, complete, non-busy plans are returned as due")
    func duePlanFiltering() {
        let repositoryID = UUID()
        func makePlan(name: String, enabled: Bool, path: String) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = repositoryID
            // A plan is called by its path's last component: the name ends it.
            plan.path = path.isEmpty ? "" : path + "/" + name
            plan.schedule.frequency = enabled ? .hourly : .manual
            plan.lastRunAt = nil
            return plan
        }

        let ready = makePlan(name: "ready", enabled: true, path: "/tmp")
        let disabled = makePlan(name: "disabled", enabled: false, path: "/tmp")
        let incomplete = makePlan(name: "incomplete", enabled: true, path: "")
        let busy = makePlan(name: "busy", enabled: true, path: "/tmp")

        let due = Scheduler.duePlans(
            in: [ready, disabled, incomplete, busy],
            now: utcDate("2026-09-05 12:00:00"),
            existingRepositoryIDs: [repositoryID],
            busyPlanIDs: [busy.id]
        )
        #expect(due.map { $0.label(among: []) } == ["ready"])
    }

    @Test("a plan whose repository no longer exists is never due and never announced")
    func danglingRepositoryIsExcluded() {
        let missingRepositoryID = UUID()
        var plan = BackupPlan()
        plan.repositoryID = missingRepositoryID
        plan.path = "/tmp/orphaned"
        plan.schedule.frequency = .hourly

        let now = utcDate("2026-09-05 12:00:00")
        // The repository set is empty, as if the repository was deleted out from
        // under the plan (or a hand-edited config never had it).
        let existing: Set<UUID> = []

        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).isEmpty)
        #expect(Scheduler.nextScheduledRun(in: [plan], now: now, existingRepositoryIDs: existing) == nil)

        #expect(Scheduler.duePlans(
            in: [plan],
            now: now,
            existingRepositoryIDs: [missingRepositoryID]
        ).map { $0.label(among: []) } == ["orphaned"])
        #expect(Scheduler.nextScheduledRun(
            in: [plan],
            now: now,
            existingRepositoryIDs: [missingRepositoryID]
        )?.plan.label(among: []) == "orphaned")
    }

    @Test("upcomingRuns is the scheduler's own enumeration, shared with the plan page's Next backup value")
    func upcomingRunsFiltering() {
        let repositoryID = UUID()
        func makePlan(name: String, enabled: Bool, path: String, lastRunAt: Date?) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = repositoryID
            // A plan is called by its path's last component: the name ends it.
            plan.path = path.isEmpty ? "" : path + "/" + name
            plan.schedule.frequency = enabled ? .hourly : .manual
            plan.lastRunAt = lastRunAt
            return plan
        }

        let now = utcDate("2026-09-05 12:00:00")
        // Ran at 10:00, hourly: next due 11:00 — already past, which is the
        // card's "Due now" case and proves the date comes back unclamped.
        let overdue = makePlan(name: "overdue", enabled: true, path: "/tmp", lastRunAt: utcDate("2026-09-05 10:00:00"))
        let disabled = makePlan(name: "disabled", enabled: false, path: "/tmp", lastRunAt: nil)
        // An incomplete plan must not be listed: the card would announce it
        // as due forever while the scheduler never fires it.
        let incomplete = makePlan(name: "incomplete", enabled: true, path: "", lastRunAt: nil)

        let upcoming = Scheduler.upcomingRuns(
            in: [overdue, disabled, incomplete],
            now: now,
            existingRepositoryIDs: [repositoryID]
        )
        #expect(upcoming.map { $0.plan.label(among: []) } == ["overdue"])
        #expect(upcoming.first?.date == utcDate("2026-09-05 11:00:00"))
    }

    @Test("a plan whose repository is busy is held back, not dropped")
    func repositoryBusyDefersPlan() {
        let repositoryID = UUID()
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        plan.path = "/tmp/waiting"
        plan.schedule.frequency = .hourly

        let now = utcDate("2026-09-05 12:00:00")
        let existing: Set<UUID> = [repositoryID]
        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).map { $0.label(among: []) } == ["waiting"])

        // While a prune holds the repository, the plan must not start …
        #expect(Scheduler.duePlans(
            in: [plan], now: now, existingRepositoryIDs: existing, busyRepositoryIDs: [repositoryID]
        ).isEmpty)

        // … and because nothing was recorded as run, it is still due afterwards.
        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).map { $0.label(among: []) } == ["waiting"])
    }

    @Test("plans due on one repository in the same tick start one at a time, the most overdue first")
    func oneBackupPerRepositoryPerTick() {
        let shared = UUID()
        let other = UUID()
        func makePlan(_ name: String, _ repositoryID: UUID, lastRunAt: String) -> BackupPlan {
            var plan = BackupPlan()
            plan.repositoryID = repositoryID
            plan.path = "/tmp/" + name
            plan.schedule.frequency = .daily
            plan.lastRunAt = utcDate(lastRunAt)
            return plan
        }
        // Two plans on one repository due at the same moment: started
        // together, each backup's retention `forget` takes the repository's
        // exclusive lock and locks the other out, which records
        // "Retention skipped" — so a tick starts only one of them.
        let downloads = makePlan("downloads", shared, lastRunAt: "2026-09-04 02:00:00")
        let dotfiles = makePlan("dotfiles", shared, lastRunAt: "2026-09-04 02:00:00")
        let elsewhere = makePlan("elsewhere", other, lastRunAt: "2026-09-04 02:00:00")
        let existing: Set<UUID> = [shared, other]
        let now = utcDate("2026-09-05 02:00:30")

        #expect(Scheduler.duePlans(
            in: [downloads, dotfiles, elsewhere], now: now, existingRepositoryIDs: existing
        ).map { $0.label(among: []) } == ["downloads", "elsewhere"])

        // Held back, not dropped: while the first runs its repository is busy,
        // and once it has run, the other is due on the next tick.
        #expect(Scheduler.duePlans(
            in: [downloads, dotfiles, elsewhere], now: now, existingRepositoryIDs: existing,
            busyPlanIDs: [downloads.id, elsewhere.id], busyRepositoryIDs: [shared, other]
        ).isEmpty)
        var ran = downloads
        ran.lastRunAt = utcDate("2026-09-05 02:00:40")
        #expect(Scheduler.duePlans(
            in: [ran, dotfiles], now: utcDate("2026-09-05 02:01:30"), existingRepositoryIDs: existing
        ).map { $0.label(among: []) } == ["dotfiles"])

        // The plan whose slot passed longer ago goes first, whatever the
        // order: a daily plan is due a day after its last run, so 01:00
        // beats 02:00.
        let early = makePlan("early", shared, lastRunAt: "2026-09-04 01:00:00")
        #expect(Scheduler.duePlans(
            in: [downloads, early], now: now, existingRepositoryIDs: existing
        ).map { $0.label(among: []) } == ["early"])
    }
}

@Suite("Pausing the schedule")
struct PauseSchedulingTests {
    private let repositoryID = UUID()

    private func dailyPlan(name: String = "Nightly", lastRunAt: Date?) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        plan.path = "/tmp/" + name
        plan.schedule.frequency = .daily
        plan.lastRunAt = lastRunAt
        return plan
    }

    @Test("the hold: a live pause wins, a metered network holds only what would use it, a pause holds nothing from its end on")
    func scheduleHoldPrecedence() {
        let now = utcDate("2026-09-25 12:00:00")
        let inAnHour = now.addingTimeInterval(3600)

        #expect(
            Scheduler.hold(pause: SchedulePause(until: inAnHour), isOnMeteredNetwork: true, repositoryUsesNetwork: true, now: now)
                == .paused(until: inAnHour)
        )
        #expect(
            Scheduler.hold(pause: SchedulePause(until: nil), isOnMeteredNetwork: false, repositoryUsesNetwork: false, now: now)
                == .paused(until: nil)
        )
        #expect(Scheduler.hold(pause: nil, isOnMeteredNetwork: true, repositoryUsesNetwork: true, now: now) == .onMeteredNetwork)
        #expect(Scheduler.hold(pause: nil, isOnMeteredNetwork: true, repositoryUsesNetwork: false, now: now) == nil)
        #expect(Scheduler.hold(pause: nil, isOnMeteredNetwork: false, repositoryUsesNetwork: true, now: now) == nil)
        #expect(
            Scheduler.hold(
                pause: SchedulePause(until: now),
                isOnMeteredNetwork: false,
                repositoryUsesNetwork: true,
                now: now
            ) == nil
        )

        #expect(ScheduleHold.paused(until: inAnHour).resumesAt == inAnHour)
        #expect(ScheduleHold.paused(until: nil).resumesAt == nil)
        #expect(ScheduleHold.onMeteredNetwork.resumesAt == nil)
    }

    @Test("a timed app-wide hold pushes every upcoming run to its end; an open-ended one leaves dates raw")
    func heldUntilClampsUpcoming() {
        let now = utcDate("2026-09-25 12:00:00")
        let heldUntil = now.addingTimeInterval(3600)
        let existing: Set<UUID> = [repositoryID]
        var first = dailyPlan(name: "First", lastRunAt: utcDate("2026-09-23 02:00:00"))
        first.schedule.frequency = .hourly
        let second = dailyPlan(name: "Second", lastRunAt: utcDate("2026-09-23 02:00:00"))

        let held = Scheduler.upcomingRuns(in: [first, second], now: now, existingRepositoryIDs: existing, heldUntil: heldUntil)
        #expect(held.count == 2)
        #expect(held.allSatisfy { $0.date == heldUntil })
        #expect(
            Scheduler.nextScheduledRun(in: [first, second], now: now, existingRepositoryIDs: existing, heldUntil: heldUntil)?
                .date == heldUntil
        )

        // No end to clamp to: the dates stay raw, and a past one stays past —
        // the card's "Waiting" input.
        let raw = Scheduler.upcomingRuns(in: [first, second], now: now, existingRepositoryIDs: existing, heldUntil: nil)
        #expect(raw.count == 2)
        #expect(raw.allSatisfy { $0.date < now })
    }

    @Test("pause lengths end where their names say, across DST and a zone with no midnight")
    func pauseLengthEnds() throws {
        let now = utcDate("2026-09-25 12:00:00")
        #expect(PauseLength.oneHour.end(from: now) == now.addingTimeInterval(3600))
        #expect(PauseLength.untilResumed.end(from: now) == nil)
        #expect(PauseLength.allCases.map(\.menuTitle) == ["For 1 Hour", "Until Tomorrow", "Until I Resume"])

        // The expected strings carry numeric offsets: the `xxx` format
        // prints the zone as "-07:00", never "PDT", whatever the locale.
        func check(_ zone: String, _ components: DateComponents, _ expected: String) throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            let start = try #require(calendar.date(from: components))
            let end = try #require(PauseLength.untilTomorrow.end(from: start, calendar: calendar))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm xxx"
            #expect(formatter.string(from: end) == expected, "\(zone) from \(formatter.string(from: start))")
            #expect(end > start)
            let nextDay = try #require(calendar.date(byAdding: .day, value: 1, to: start))
            #expect(calendar.isDate(end, inSameDayAs: nextDay))
        }
        try check("America/Los_Angeles", DateComponents(year: 2026, month: 9, day: 26, hour: 16), "2026-09-27 00:00 -07:00")
        // Spring forward and fall back.
        try check("America/Los_Angeles", DateComponents(year: 2026, month: 3, day: 7, hour: 22), "2026-03-08 00:00 -08:00")
        try check("America/Los_Angeles", DateComponents(year: 2026, month: 10, day: 31, hour: 23, minute: 59), "2026-11-01 00:00 -07:00")
        // Santiago skips midnight on this date: the day starts at 01:00.
        try check("America/Santiago", DateComponents(year: 2026, month: 9, day: 5, hour: 20), "2026-09-06 01:00 -03:00")
    }
}

@Suite("Upcoming run")
struct UpcomingRunTests {
    private func plan(
        name: String,
        frequency: Schedule.Frequency,
        lastRun: Date?,
        enabled: Bool = true,
        path: String = "/tmp"
    ) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = UUID()
        plan.path = path.isEmpty ? "" : path + "/" + name
        plan.schedule.frequency = enabled ? frequency : .manual
        plan.lastRunAt = lastRun
        return plan
    }

    @Test("the soonest upcoming run wins, manual and incomplete plans are never listed")
    func soonestWins() {
        let soon = plan(name: "hourly", frequency: .hourly, lastRun: utcDate("2026-09-05 11:50:00"))
        let later = plan(name: "daily", frequency: .daily, lastRun: utcDate("2026-09-05 02:00:00"))
        let manual = plan(name: "manual", frequency: .manual, lastRun: nil)
        let disabled = plan(name: "disabled", frequency: .hourly, lastRun: nil, enabled: false)
        let incomplete = plan(name: "incomplete", frequency: .hourly, lastRun: nil, path: "")

        let now = utcDate("2026-09-05 12:00:00")
        let next = Scheduler.nextScheduledRun(
            in: [manual, later, disabled, incomplete, soon],
            now: now,
            existingRepositoryIDs: Set([manual, later, disabled, incomplete, soon].compactMap(\.repositoryID))
        )
        #expect(next?.plan.id == soon.id)
        #expect(next?.date == utcDate("2026-09-05 12:50:00"))
    }

    @Test("an overdue plan is shown as due now, not in the past")
    func overdueIsClampedToNow() {
        // Last ran five hours ago on an hourly schedule: the date is in the past,
        // and the menu bar must not show a negative countdown.
        let overdue = plan(name: "hourly", frequency: .hourly, lastRun: utcDate("2026-09-05 07:00:00"))
        let now = utcDate("2026-09-05 12:00:00")
        let next = Scheduler.nextScheduledRun(in: [overdue], now: now, existingRepositoryIDs: Set([overdue.repositoryID!]))
        #expect(next?.date == now)
    }

    @Test("no runnable plan means no upcoming run")
    func noneScheduled() {
        let manual = plan(name: "manual", frequency: .manual, lastRun: nil)
        #expect(Scheduler.nextScheduledRun(in: [manual], now: utcDate("2026-09-05 12:00:00"), existingRepositoryIDs: []) == nil)
        #expect(Scheduler.nextScheduledRun(in: [], now: utcDate("2026-09-05 12:00:00"), existingRepositoryIDs: []) == nil)
    }
}

@Suite("Repository maintenance scheduling")
struct MaintenanceSchedulingTests {
    private func repository(_ configure: (inout Repository) -> Void) -> Repository {
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/tmp/repo"
        repository.createdAt = utcDate("2026-09-01 00:00:00")
        configure(&repository)
        return repository
    }

    @Test("a freshly added repository counts from when it was added, not from zero")
    func newRepositoryIsNotImmediatelyDue() {
        let repository = repository { _ in }
        // Adding a repository must not kick off a check — or, worse, a prune —
        // the moment it appears in the sidebar.
        #expect(Scheduler.dueMaintenance(
            in: [repository],
            plans: [],
            now: utcDate("2026-09-05 00:00:00")
        ).isEmpty)

        let due = Scheduler.dueMaintenance(in: [repository], plans: [], now: utcDate("2026-09-09 00:00:00"))
        #expect(due.map(\.task) == [.check])
    }

    private func plan(on repository: Repository, retention: RetentionPolicy = RetentionPolicy()) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = "/x"
        plan.retention = retention
        return plan
    }

    @Test("a cleanup comes due only where a plan removes old backups, and is chosen over a check")
    func pruneNeedsRetention() {
        let repository = repository { _ in }
        let now = utcDate("2026-10-10 00:00:00")
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [plan(on: repository)], now: now).map(\.task) == [.prune])
        // Retention off, or on another repository's plan: nothing to free, so
        // an append-only server is never asked for a prune it refuses.
        var keepsAll = RetentionPolicy()
        keepsAll.isEnabled = false
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [plan(on: repository, retention: keepsAll)], now: now).map(\.task) == [.check])
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [plan(on: self.repository { _ in })], now: now).map(\.task) == [.check])
    }

    @Test("checks run 7 days and cleanups 30 days after a repository is added")
    func fixedIntervals() {
        let added = utcDate("2026-10-09 00:00:00")
        #expect(MaintenancePolicy().nextDate(for: .prune, addedAt: added) == utcDate("2026-11-08 00:00:00"))
        #expect(MaintenancePolicy().nextDate(for: .check, addedAt: added) == utcDate("2026-10-16 00:00:00"))
    }

    @Test("a scheduled check reads the data in twelve slices where reading costs only time, the structure where it may be billed, whatever an older build stored")
    func scheduledCheckDepth() throws {
        for kind in [Repository.Kind.local, .sftp] {
            #expect(MaintenancePolicy().scheduledDataSubset(for: kind) == .slice(1, of: 12), "\(kind)")
        }
        for kind in [Repository.Kind.rest, .s3, .rclone] {
            #expect(MaintenancePolicy().scheduledDataSubset(for: kind) == nil, "\(kind)")
        }
        var policy = MaintenancePolicy()
        policy.nextCheckDataSlice = 3
        #expect(policy.scheduledDataSubset(for: .local) == .slice(3, of: 12))
        // Stored by an older build: switches ignored, a stored slice kept.
        let saved = try JSONDecoder().decode(MaintenancePolicy.self, from: Data(#"{"checkEnabled":false,"checkIntervalDays":90,"checkReadDataPercent":5,"pruneEnabled":false,"nextCheckDataSlice":4}"#.utf8))
        #expect(saved.scheduledDataSubset(for: .local) == .slice(4, of: 12))
        #expect(saved.scheduledDataSubset(for: .s3) == nil)
        let added = utcDate("2026-10-09 00:00:00")
        #expect(saved.nextDate(for: .check, addedAt: added) == utcDate("2026-10-16 00:00:00"))
        #expect(CheckDataSubset.slice(3, of: 12).argument == "3/12")
        #expect(CheckDataSubset.percent(5).argument == "5%")
    }

    @Test("a hand-edited slice outside 1 to 12 checks the nearest slice there is, never one restic has no group for")
    func scheduledSliceStaysInRange() {
        var policy = MaintenancePolicy()
        policy.nextCheckDataSlice = 13
        #expect(policy.scheduledDataSubset(for: .local) == .slice(12, of: 12))
        policy.nextCheckDataSlice = 0
        #expect(policy.scheduledDataSubset(for: .local) == .slice(1, of: 12))
    }

    @Test("an editor save keeps the model's maintenance stamps and the check's next slice")
    func repositoryMergingKeepsMaintenanceState() {
        let stored = repository {
            $0.maintenance.lastCheckAt = utcDate("2026-09-08 12:00:00")
            $0.maintenance.lastPruneAt = utcDate("2026-09-01 12:00:00")
            $0.maintenance.nextCheckDataSlice = 4
        }
        var draft = stored
        draft.maintenance.lastCheckAt = nil
        draft.maintenance.lastPruneAt = nil
        draft.maintenance.nextCheckDataSlice = 3
        let merged = stored.merging(draft: draft)
        #expect(merged.maintenance.lastCheckAt == stored.maintenance.lastCheckAt)
        #expect(merged.maintenance.lastPruneAt == stored.maintenance.lastPruneAt)
        #expect(merged.maintenance.nextCheckDataSlice == 4)
    }

    @Test("Last verified after a clean check is its time alone, whatever part of the data it read")
    func lastCheckIsItsTimeAlone() {
        let repository = repository { $0.maintenance.lastCheckAt = utcDate("2026-09-08 12:00:00") }
        let now = utcDate("2026-09-10 12:00:00")
        var check = RunRecord(kind: .check, planName: "repo", repositoryID: repository.id, startedAt: utcDate("2026-09-08 12:00:00"))
        check.outcome = .succeeded
        #expect(Scheduler.lastMaintenanceText(.check, of: repository, runs: [check], now: now) == Format.ago(utcDate("2026-09-08 12:00:00"), now: now))
    }

    @Test("a check recorded with what it read, a key no longer kept, still decodes")
    func storedCheckReadStillDecodes() throws {
        let stored = Data(#"{"kind":"check","outcome":"succeeded","checkRead":"part 3 of 12"}"#.utf8)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: stored)
        #expect(decoded.kind == .check)
        #expect(decoded.outcome == .succeeded)
    }

    @Test("a busy repository is skipped entirely")
    func busyRepositoryIsSkipped() {
        let repository = repository { _ in }
        let now = utcDate("2026-09-10 00:00:00")
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [], now: now).count == 1)
        #expect(Scheduler.dueMaintenance(
            in: [repository],
            plans: [],
            now: now,
            busyRepositoryIDs: [repository.id]
        ).isEmpty)
    }

    @Test("running a task pushes the next one out by a full interval")
    func lastRunMovesTheSchedule() {
        var repository = repository { _ in }
        repository.maintenance.lastCheckAt = utcDate("2026-09-09 00:00:00")
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [], now: utcDate("2026-09-12 00:00:00")).isEmpty)
        #expect(Scheduler.dueMaintenance(in: [repository], plans: [], now: utcDate("2026-09-16 00:00:01")).count == 1)
    }

    @Test("the repository page's Last check reads the newest check run with how it ended, the stamp only without one")
    func lastMaintenanceReadsTheRecord() {
        var repository = repository { _ in }
        let now = utcDate("2026-09-10 12:00:00")
        func check(_ outcome: RunRecord.Outcome, at stamp: String, repository id: UUID? = nil) -> RunRecord {
            var run = RunRecord(kind: .check, planName: "repo", repositoryID: id ?? repository.id, startedAt: utcDate(stamp))
            run.outcome = outcome
            return run
        }
        func last(_ runs: [RunRecord]) -> String {
            Scheduler.lastMaintenanceText(.check, of: repository, runs: runs, now: now)
        }
        #expect(last([]) == "Never")
        // A record without a stamp — history older than the stamp itself.
        #expect(last([check(.succeeded, at: "2026-09-08 12:00:00")]) == Format.ago(utcDate("2026-09-08 12:00:00"), now: now))

        repository.maintenance.lastCheckAt = utcDate("2026-09-09 12:00:00")
        let ago = Format.ago(utcDate("2026-09-09 12:00:00"), now: now)
        // The stamp is written for every attempt; the record says how it went.
        #expect(last([check(.succeeded, at: "2026-09-09 12:00:00")]) == ago)
        #expect(last([check(.failed, at: "2026-09-09 12:00:00")]) == "\(ago) · failed")
        // A check that found damage says what it found, in its record's
        // own words — the Detail column's — not a second spelling.
        var withVerdict = check(.completedWithErrors, at: "2026-09-09 12:00:00")
        withVerdict.detailText = "2 errors — restic repair can recover some damage. A cleanup is suggested."
        #expect(last([withVerdict]) == "\(ago) · 2 errors — restic repair can recover some damage")
        // A record from before the verdict was stored: the outcome itself.
        #expect(last([check(.completedWithErrors, at: "2026-09-09 12:00:00")]) == "\(ago) · completed with warnings")
        #expect(last([check(.cancelled, at: "2026-09-09 12:00:00")]) == "\(ago) · stopped")
        // The newest of the repository's own checks, never a prune's or
        // another repository's.
        var prune = check(.failed, at: "2026-09-09 13:00:00")
        prune.kind = .prune
        #expect(last([
            prune,
            check(.failed, at: "2026-09-09 14:00:00", repository: UUID()),
            check(.succeeded, at: "2026-09-09 12:00:00"),
            check(.failed, at: "2026-09-02 12:00:00"),
        ]) == ago)
        // A record older than the stamp is not the last check — the history
        // lost the newer one: the stamp's moment, without a verdict.
        #expect(last([check(.failed, at: "2026-09-02 12:00:00")]) == ago)
        // The same record is the page's route to the console when it found
        // damage, and only then.
        let damaged = check(.completedWithErrors, at: "2026-09-09 12:00:00")
        let found = Scheduler.newestMaintenanceRun(.check, of: repository, runs: [damaged])
        #expect(found?.id == damaged.id)
        #expect(found.flatMap { RunRecordPresentation.repairRoute(for: $0, repositoryExists: true) } == repository.id)
        #expect(Scheduler.newestMaintenanceRun(.check, of: repository, runs: [check(.completedWithErrors, at: "2026-09-02 12:00:00")]) == nil)
        #expect(last([]) == ago)
    }

    @Test("a check waiting for its repository's drive is no last check")
    func upkeepWaitingForItsDrive() {
        let volume = "SwiftResticAbsentDrive-\(UUID().uuidString)"
        let repository = repository {
            $0.kind = .local
            $0.localPath = "/Volumes/\(volume)/restic"
            $0.maintenance.lastCheckAt = utcDate("2026-09-02 12:00:00")
        }
        let now = utcDate("2026-09-10 12:00:00")
        var failed = RunRecord(kind: .check, planName: "repo", repositoryID: repository.id, startedAt: utcDate("2026-09-02 12:00:00"))
        failed.outcome = .failed
        var waited = RunRecord(kind: .check, planName: "repo", repositoryID: repository.id, startedAt: utcDate("2026-09-10 11:00:00"))
        waited.outcome = .skipped
        waited.detailText = "“\(volume)” is not connected."
        // The skip is no check: the last one is still the failure before it.
        #expect(Scheduler.newestMaintenanceRun(.check, of: repository, runs: [waited, failed])?.id == failed.id)
        #expect(Scheduler.lastMaintenanceText(.check, of: repository, runs: [waited, failed], now: now)
            == "\(Format.ago(utcDate("2026-09-02 12:00:00"), now: now)) · failed")
    }
}

@Suite("Retention policy")
struct RetentionPolicyTests {
    @Test("a policy with every rule at zero refuses to run")
    func emptyPolicyIsUnsafe() {
        // restic reads `forget` with no --keep-* flag as "delete every snapshot".
        // Nothing in the app may ever hand it that command line.
        var policy = RetentionPolicy()
        policy.keepLast = 0
        policy.keepHourly = 0
        policy.keepDaily = 0
        policy.keepWeekly = 0
        policy.keepMonthly = 0
        policy.keepYearly = 0
        #expect(policy.forgetArguments.isEmpty)
        #expect(policy.isSafeToRun == false)
    }

    @Test("rules become --keep-* flags, skipping the zeros")
    func flags() {
        var policy = RetentionPolicy()
        policy.keepLast = 0
        policy.keepHourly = 24
        policy.keepDaily = 7
        policy.keepWeekly = 0
        policy.keepMonthly = 12
        policy.keepYearly = 0
        #expect(policy.forgetArguments == [
            "--keep-hourly", "24",
            "--keep-daily", "7",
            "--keep-monthly", "12",
        ])
        #expect(policy.isSafeToRun)
    }
}

@Suite("Repository configuration")
struct RepositoryTests {
    @Test("each backend produces the repository string restic expects")
    func repositoryStrings() {
        var local = Repository()
        local.kind = .local
        local.localPath = "/Volumes/Backup/restic"
        #expect(local.resticRepositoryString == "/Volumes/Backup/restic")

        // restic is spawned without a shell, so the tilde must never reach
        // it — the expansion the shell would do happens in the model.
        var tilde = Repository()
        tilde.kind = .local
        tilde.localPath = "~/Backups/restic"
        #expect(tilde.resolvedLocalPath == NSHomeDirectory() + "/Backups/restic")
        #expect(tilde.resticRepositoryString == NSHomeDirectory() + "/Backups/restic")

        var sftp = Repository()
        sftp.kind = .sftp
        sftp.sftpHost = "backup@nas.local"
        sftp.sftpPath = "/volume1/restic"
        #expect(sftp.resticRepositoryString == "sftp:backup@nas.local:/volume1/restic")
        // ssh's own port keeps the colon form, byte for byte.
        sftp.sftpHost = "backup@nas.local:22"
        #expect(sftp.resticRepositoryString == "sftp:backup@nas.local:/volume1/restic")

        var s3 = Repository()
        s3.kind = .s3
        s3.s3Endpoint = "s3.eu-central-1.amazonaws.com"
        s3.s3Bucket = "my-bucket"
        #expect(s3.resticRepositoryString == "s3:s3.eu-central-1.amazonaws.com/my-bucket")
        // A folder in the bucket is typed after it, in the same field.
        s3.s3Bucket = "/my-bucket/macs/laptop/"
        #expect(s3.resticRepositoryString == "s3:s3.eu-central-1.amazonaws.com/my-bucket/macs/laptop")
        #expect(s3.label(among: []) == "my-bucket")

        var rest = Repository()
        rest.kind = .rest
        rest.restURL = "https://host:8000/"
        #expect(rest.resticRepositoryString == "rest:https://host:8000/")
    }

    @Test("an SFTP port other than 22 moves to restic's URL form, the only one that carries a port")
    func sftpPortString() throws {
        var sftp = Repository()
        sftp.kind = .sftp
        sftp.sftpHost = "backup@nas.local:2222"
        // The first slash ends the connection settings: an absolute path
        // keeps its own after it.
        sftp.sftpPath = "/volume1/restic"
        #expect(sftp.resticRepositoryString == "sftp://backup@nas.local:2222//volume1/restic")
        // One slash for a path relative to the login's home.
        sftp.sftpPath = "restic"
        #expect(sftp.resticRepositoryString == "sftp://backup@nas.local:2222/restic")
        // Percent-encoded: restic reads the form as a URL, where a `#`
        // would end the path.
        sftp.sftpPath = "/volume1/Mac #1"
        #expect(sftp.resticRepositoryString == "sftp://backup@nas.local:2222//volume1/Mac%20%231")
        sftp.sftpHost = "nas.local:2222"
        #expect(sftp.resticRepositoryString == "sftp://nas.local:2222//volume1/Mac%20%231")

        // A port typed after the host, the editor's only way to give one.
        var typed = Repository()
        typed.kind = .sftp
        typed.sftpHost = "backup@nas.local:2222"
        typed.sftpPath = "/volume1/restic"
        #expect(typed.sftpUser == "backup")
        #expect(typed.sftpHostName == "nas.local")
        #expect(typed.sftpPortText == "2222")
        #expect(typed.resticRepositoryString == "sftp://backup@nas.local:2222//volume1/restic")
        typed.sftpHost = "backup@nas.local:22"
        #expect(typed.resticRepositoryString == "sftp:backup@nas.local:/volume1/restic")
        // The user ends at the last @.
        typed.sftpHost = "me@example.com@nas.local"
        #expect(typed.sftpUser == "me@example.com")
        #expect(typed.sftpHostName == "nas.local")

        // A port kept in a field of its own is no port: the key is ignored.
        let old = try JSONDecoder().decode(
            Repository.self,
            from: Data(#"{"kind":"sftp","name":"NAS","sftpHost":"nas.local","sftpPort":"2222","sftpPath":"/r"}"#.utf8)
        )
        #expect(old.sftpPortText == "")
        #expect(old.resticRepositoryString == "sftp:nas.local:/r")
    }

    @Test("provider secrets map to the environment variables each backend reads")
    func credentialEnvironment() {
        var s3 = Repository()
        s3.kind = .s3
        s3.s3AccessKeyID = "AKIA"
        let s3Env = s3.credentialEnvironment(secret: "shhh")
        #expect(s3Env["AWS_ACCESS_KEY_ID"] == "AKIA")
        #expect(s3Env["AWS_SECRET_ACCESS_KEY"] == "shhh")

        var local = Repository()
        local.kind = .local
        #expect(local.credentialEnvironment(secret: nil).isEmpty)
    }

    @Test("a location reads in the reader's words, not restic's repository string")
    func displayLocation() {
        var local = Repository()
        local.localPath = NSHomeDirectory() + "/Backups"
        #expect(local.displayLocation == "~/Backups")

        var s3 = Repository()
        s3.kind = .s3
        s3.s3Endpoint = "s3.us-west-004.backblazeb2.com"
        s3.s3Bucket = "photos"
        #expect(s3.displayLocation == "photos on s3.us-west-004.backblazeb2.com")
        s3.s3Bucket = "photos/mac/"
        #expect(s3.displayLocation == "photos/mac on s3.us-west-004.backblazeb2.com")

        var sftp = Repository()
        sftp.kind = .sftp
        sftp.sftpHost = "backup@nas.local:2222"
        sftp.sftpPath = "/volume1/SwiftRestic Backups"
        #expect(sftp.displayLocation == "backup@nas.local:/volume1/SwiftRestic Backups")

        var rclone = Repository()
        rclone.kind = .rclone
        rclone.rcloneRemote = "gdrive:"
        rclone.rclonePath = "backups"
        #expect(rclone.displayLocation == "gdrive:backups")

        var rest = Repository()
        rest.kind = .rest
        rest.restURL = "rest:https://host:8000/"
        #expect(rest.displayLocation == "https://host:8000/")
    }

    @Test("a REST server's login rides in restic's environment from the Keychain, never in the stored URL")
    func restCredentials() throws {
        var rest = Repository()
        rest.kind = .rest
        rest.restURL = "https://host:8000/"
        rest.restUser = "alice"
        // The password is the provider secret: the editor shows its field.
        #expect(rest.secretFieldLabel == "Server password")
        let env = rest.credentialEnvironment(secret: "s3cret")
        #expect(env["RESTIC_REST_USERNAME"] == "alice")
        #expect(env["RESTIC_REST_PASSWORD"] == "s3cret")
        #expect(rest.resticRepositoryString == "rest:https://host:8000/")

        let split = try #require(Repository.splittingRESTCredentials("https://alice:p%40ss@host:8000/repo/"))
        #expect(split.url == "https://host:8000/repo/")
        #expect(split.user == "alice")
        #expect(split.password == "p@ss")
        let prefixed = try #require(Repository.splittingRESTCredentials("rest:http://bob@10.0.0.2:8000/"))
        #expect(prefixed.url == "rest:http://10.0.0.2:8000/")
        #expect(prefixed.user == "bob")
        #expect(prefixed.password == nil)
        // Nothing to take, or no server yet while the user is typing.
        #expect(Repository.splittingRESTCredentials("https://host:8000/") == nil)
        #expect(Repository.splittingRESTCredentials("https://alice:pa@") == nil)

        // A repository saved with its login in the URL keeps working as it
        // did: the URL passes through, and restic prefers its credentials.
        let old = try JSONDecoder().decode(
            Repository.self,
            from: Data(#"{"kind":"rest","name":"Server","restURL":"https://alice:s3cret@host:8000/"}"#.utf8)
        )
        #expect(old.restUser == "")
        #expect(old.resticRepositoryString == "rest:https://alice:s3cret@host:8000/")
    }

    @Test("plan tags are stable and unique per plan")
    func planTags() {
        let id = UUID()
        #expect(ResticService.planTag(id) == ResticService.planTag(id))
        #expect(ResticService.planTag(id) != ResticService.planTag(UUID()))
        #expect(ResticService.planTag(id).hasPrefix("swiftrestic-plan-"))
    }

    @Test("exclude patterns get the tilde expansion the shell would normally do")
    func tildeExpansion() {
        let expanded = ResticService.expandTilde("~/Library/Caches")
        #expect(expanded.hasPrefix(NSHomeDirectory()))
        #expect(ResticService.expandTilde("/absolute/path") == "/absolute/path")
        #expect(ResticService.expandTilde("**/node_modules") == "**/node_modules")
    }

    @Test("a stand-in home changes where a tilde path starts, never how NSString tidies it")
    func tildeExpansionAgainstAStandInHome() {
        // With the real home every shape is NSString's, slashes tidied: a
        // plan's typed "~/" or "~/Documents/" names the folder restic and
        // the rest of the app compare against.
        let shapes = ["~", "~/", "~/Documents", "~/Documents/", "~//Documents", "~/a//b", "~root", "~/Library/Mail/V*/MailData/Envelope Index*"]
        for shape in shapes {
            #expect(ResticService.expandTilde(shape) == (shape as NSString).expandingTildeInPath, "\(shape)")
        }
        #expect(ResticService.expandTilde("~", home: "/Users/probe") == "/Users/probe")
        #expect(ResticService.expandTilde("~/", home: "/Users/probe") == "/Users/probe")
        #expect(ResticService.expandTilde("~/Documents/", home: "/Users/probe") == "/Users/probe/Documents")
        #expect(ResticService.expandTilde("~//a//b", home: "/Users/probe") == "/Users/probe/a/b")
        // Another user's home is NSString's to find.
        #expect(ResticService.expandTilde("~root/x", home: "/Users/probe") == ("~root/x" as NSString).expandingTildeInPath)
    }
}

@Suite("Additional backends")
struct AdditionalBackendTests {
    @Test("rclone builds the repository string restic expects")
    func repositoryStrings() {
        var rclone = Repository()
        rclone.kind = .rclone
        rclone.rcloneRemote = "mydrive"
        rclone.rclonePath = "backups/mac/"
        #expect(rclone.resticRepositoryString == "rclone:mydrive:backups/mac")
        // A remote typed with rclone's own trailing colon must not double up.
        rclone.rcloneRemote = "mydrive:"
        #expect(rclone.resticRepositoryString == "rclone:mydrive:backups/mac")
        // The leading slash is rclone's absolute path: on sftp and local
        // remotes "/srv/x" and "srv/x" (from the login's home, or the
        // current folder) are different places.
        rclone.rclonePath = "/srv/backups/"
        #expect(rclone.resticRepositoryString == "rclone:mydrive:/srv/backups")
    }

    @Test("rclone needs no credentials of its own, only its helper")
    func credentialEnvironment() {
        var rclone = Repository()
        rclone.kind = .rclone
        #expect(rclone.credentialEnvironment(secret: nil).isEmpty)
        #expect(rclone.requiresRcloneBinary)
    }

    @Test("a config written before these backends existed still loads")
    func decodesLegacyRepository() throws {
        // Only the keys an older build wrote. The synthesized decoder would throw
        // on every field added since, losing the user's whole configuration.
        let json = #"{"id":"0753DDAB-181D-4E00-9340-8FDF7FD52504","name":"Old","kind":"local","createdAt":"2026-09-05T00:00:00Z","localPath":"/tmp/repo"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repository = try decoder.decode(Repository.self, from: Data(json.utf8))
        // The name an older build stored is no longer read: a repository
        // is called by where it is.
        #expect(repository.label(among: [repository]) == "repo")
        #expect(repository.localPath == "/tmp/repo")
        #expect(repository.s3Endpoint == "s3.amazonaws.com")
        #expect(repository.rcloneRemote.isEmpty)
    }

    @Test("a location of a kind no longer offered still loads, as a folder not yet chosen")
    func decodesRemovedKind() throws {
        for kind in ["b2", "azure", "gcs"] {
            let json = #"{"kind":"\#(kind)","b2Bucket":"photos","azureContainer":"photos","gcsBucket":"photos"}"#
            let repository = try JSONDecoder().decode(Repository.self, from: Data(json.utf8))
            #expect(repository.kind == .local, "\(kind)")
            #expect(!repository.isConfigurationComplete, "\(kind)")
        }
    }
}

@Suite("Repository completeness")
struct RepositoryCompletenessTests {
    /// The non-secret fields each backend needs before restic can be run at
    /// all, one setter per field. Computed, not stored: closure tables are not
    /// `Sendable` and Swift 6 refuses a shared static one.
    private static var requiredFields: [Repository.Kind: [(inout Repository) -> Void]] {
        [
            .local: [{ $0.localPath = "/Volumes/Backup" }],
            .sftp: [{ $0.sftpHost = "nas.local" }, { $0.sftpPath = "/volume1/restic" }],
            .s3: [{ $0.s3Bucket = "bucket" }, { $0.s3AccessKeyID = "AKIA" }],
            .rest: [{ $0.restURL = "https://host:8000" }],
            .rclone: [{ $0.rcloneRemote = "mydrive" }],
        ]
    }

    @Test("a repository is complete exactly when every one of its backend's required fields is filled")
    func completenessPerKind() {
        for kind in Repository.Kind.allCases {
            guard let fields = Self.requiredFields[kind] else {
                Issue.record("no required-field spec for \(kind)")
                continue
            }
            func filled(except skipped: Int?) -> Repository {
                var repository = Repository()
                repository.kind = kind
                for (index, fill) in fields.enumerated() where index != skipped { fill(&repository) }
                return repository
            }
            #expect(filled(except: nil).isConfigurationComplete, "\(kind) with every required field must be complete")
            // The scheduler refuses to schedule incomplete repositories, so a
            // missing field must never read as runnable.
            for index in fields.indices {
                #expect(!filled(except: index).isConfigurationComplete, "\(kind) missing required field \(index + 1) must be incomplete")
            }
        }
    }
}

@Suite("Login item")
struct LoginItemTests {
    @Test("a build folder is never a valid place to register a login item from")
    func rejectsBuildLocations() {
        // Registering from DerivedData leaves an entry pointing at a bundle that
        // the next compile replaces — and the stale entry outlives the build.
        #expect(!LoginItem.isInstallableLocation(
            "/Users/me/Library/Developer/Xcode/DerivedData/SwiftRestic-abc/Build/Products/Debug/SwiftRestic.app"
        ))
        #expect(!LoginItem.isInstallableLocation("/Users/me/Downloads/SwiftRestic.app"))
        #expect(!LoginItem.isInstallableLocation("/Volumes/SwiftRestic/SwiftRestic.app"))
        #expect(!LoginItem.isInstallableLocation("/tmp/SwiftRestic.app"))
        // A test runner's xctest lives in Xcode, inside /Applications.
        #expect(!LoginItem.isInstallableLocation(
            "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
        ))
    }

    @Test("the login item follows the schedules: on while a plan has one, off once none has, never from outside Applications")
    func followsSchedules() {
        func change(_ scheduled: Bool, _ state: LoginItemState, installable: Bool = true) -> Bool? {
            LoginItem.change(hasScheduledPlan: scheduled, state: state, isInstallable: installable)
        }
        #expect(change(true, .off) == true)
        #expect(change(true, .notFound) == true)
        #expect(change(true, .enabled) == nil)
        // Waiting for approval is the user's step in Login Items, not ours.
        #expect(change(true, .needsApproval) == nil)
        #expect(change(true, .off, installable: false) == nil)
        #expect(change(false, .enabled) == false)
        #expect(change(false, .needsApproval) == false)
        #expect(change(false, .enabled, installable: false) == false)
        #expect(change(false, .off) == nil)
    }

    @Test("an installed copy is accepted")
    func acceptsInstalledLocations() {
        #expect(LoginItem.isInstallableLocation("/Applications/SwiftRestic.app"))
        #expect(LoginItem.isInstallableLocation("/Applications/Utilities/SwiftRestic.app"))
        #expect(LoginItem.isInstallableLocation("\(NSHomeDirectory())/Applications/SwiftRestic.app"))
    }
}

extension Scheduler {
    /// `lastMaintenanceText` over a run history, finding the newest run the
    /// way the repository page does.
    static func lastMaintenanceText(
        _ task: MaintenanceTask,
        of repository: Repository,
        runs: [RunRecord],
        now: Date = .now
    ) -> String {
        lastMaintenanceText(task, of: repository, newest: newestMaintenanceRun(task, of: repository, runs: runs), now: now)
    }
}
