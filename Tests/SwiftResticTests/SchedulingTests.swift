import Foundation
import Testing

@Suite("Scheduling")
struct SchedulingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    @Test("a manual plan is never due")
    func manualNeverDue() {
        var schedule = Schedule()
        schedule.frequency = .manual
        #expect(schedule.nextRunDate(after: nil, now: date("2026-09-05 12:00:00")) == nil)
    }

    @Test("an hourly plan that has never run is due immediately")
    func hourlyFirstRun() {
        var schedule = Schedule()
        schedule.frequency = .hourly
        schedule.intervalHours = 4
        let now = date("2026-09-05 12:00:00")
        #expect(schedule.nextRunDate(after: nil, now: now) == now)
    }

    @Test("an hourly plan waits the full interval after a run")
    func hourlyInterval() {
        var schedule = Schedule()
        schedule.frequency = .hourly
        schedule.intervalHours = 4
        let lastRun = date("2026-09-05 08:00:00")
        let next = schedule.nextRunDate(after: lastRun, now: date("2026-09-05 09:00:00"))
        #expect(next == date("2026-09-05 12:00:00"))
    }

    @Test("a daily plan that missed its window while asleep is due now")
    func dailyCatchesUp() throws {
        var schedule = Schedule()
        schedule.frequency = .daily
        schedule.hour = 2
        schedule.minute = 0

        // 02:00 has passed today and the last run was yesterday morning, so the
        // plan must fire rather than silently skipping to tomorrow.
        let next = try #require(schedule.nextRunDate(
            after: date("2026-09-04 02:00:00"),
            now: date("2026-09-05 09:30:00"),
            calendar: calendar
        ))
        #expect(next == date("2026-09-05 02:00:00"))
        #expect(next <= date("2026-09-05 09:30:00"))
    }

    @Test("a daily plan that already ran today waits for tomorrow")
    func dailyAlreadyRan() {
        var schedule = Schedule()
        schedule.frequency = .daily
        schedule.hour = 2
        let next = schedule.nextRunDate(
            after: date("2026-09-05 02:00:05"),
            now: date("2026-09-05 09:30:00"),
            calendar: calendar
        )
        #expect(next == date("2026-09-06 02:00:00"))
    }

    // 2026-08-31 and 2026-09-07 are both Mondays (weekday 2); 2026-09-05 is a
    // Saturday, so the most recent firing before "now" below is 08-31 02:00.
    @Test("a weekly plan that missed its window is due at the missed slot")
    func weeklyCatchesUp() {
        var schedule = Schedule()
        schedule.frequency = .weekly
        schedule.weekday = 2
        schedule.hour = 2
        let next = schedule.nextRunDate(
            after: date("2026-08-24 02:00:00"),
            now: date("2026-09-05 12:00:00"),
            calendar: calendar
        )
        #expect(next == date("2026-08-31 02:00:00"))
    }

    @Test("a weekly plan that never ran is due at the most recent slot, not the next one")
    func weeklyNeverRan() {
        var schedule = Schedule()
        schedule.frequency = .weekly
        schedule.weekday = 2
        schedule.hour = 2
        let next = schedule.nextRunDate(
            after: nil,
            now: date("2026-09-05 12:00:00"),
            calendar: calendar
        )
        #expect(next == date("2026-08-31 02:00:00"))
    }

    @Test("a weekly plan that already ran at its slot waits for the next week")
    func weeklyAlreadyRan() {
        var schedule = Schedule()
        schedule.frequency = .weekly
        schedule.weekday = 2
        schedule.hour = 2
        // Exactly at the slot counts as having run it; a few seconds later too.
        for lastRun in [date("2026-08-31 02:00:00"), date("2026-08-31 02:00:05")] {
            let next = schedule.nextRunDate(
                after: lastRun,
                now: date("2026-09-05 12:00:00"),
                calendar: calendar
            )
            #expect(next == date("2026-09-07 02:00:00"))
        }
    }

    @Test("only enabled, complete, non-busy plans are returned as due")
    func duePlanFiltering() {
        let repositoryID = UUID()
        func makePlan(name: String, enabled: Bool, sources: [String]) -> BackupPlan {
            var plan = BackupPlan()
            plan.name = name
            plan.repositoryID = repositoryID
            plan.sources = sources
            plan.isEnabled = enabled
            plan.schedule.frequency = .hourly
            plan.schedule.intervalHours = 1
            plan.lastRunAt = nil
            return plan
        }

        let ready = makePlan(name: "ready", enabled: true, sources: ["/tmp"])
        let disabled = makePlan(name: "disabled", enabled: false, sources: ["/tmp"])
        let incomplete = makePlan(name: "incomplete", enabled: true, sources: [])
        let busy = makePlan(name: "busy", enabled: true, sources: ["/tmp"])

        let due = Scheduler.duePlans(
            in: [ready, disabled, incomplete, busy],
            now: date("2026-09-05 12:00:00"),
            existingRepositoryIDs: [repositoryID],
            busyPlanIDs: [busy.id]
        )
        #expect(due.map(\.name) == ["ready"])
    }

    @Test("a plan whose repository no longer exists is never due and never announced")
    func danglingRepositoryIsExcluded() {
        let missingRepositoryID = UUID()
        var plan = BackupPlan()
        plan.name = "orphaned"
        plan.repositoryID = missingRepositoryID
        plan.sources = ["/tmp"]
        plan.schedule.frequency = .hourly
        plan.schedule.intervalHours = 1

        let now = date("2026-09-05 12:00:00")
        // The repository set is empty, as if the repository was deleted out from
        // under the plan (or a hand-edited config never had it).
        let existing: Set<UUID> = []

        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).isEmpty)
        #expect(Scheduler.nextScheduledRun(in: [plan], now: now, existingRepositoryIDs: existing) == nil)

        // With the repository present the plan behaves normally again.
        #expect(Scheduler.duePlans(
            in: [plan],
            now: now,
            existingRepositoryIDs: [missingRepositoryID]
        ).map(\.name) == ["orphaned"])
        #expect(Scheduler.nextScheduledRun(
            in: [plan],
            now: now,
            existingRepositoryIDs: [missingRepositoryID]
        )?.plan.name == "orphaned")
    }

    @Test("a plan whose repository is busy is held back, not dropped")
    func repositoryBusyDefersPlan() {
        let repositoryID = UUID()
        var plan = BackupPlan()
        plan.name = "waiting"
        plan.repositoryID = repositoryID
        plan.sources = ["/tmp"]
        plan.schedule.frequency = .hourly
        plan.schedule.intervalHours = 1

        let now = date("2026-09-05 12:00:00")
        let existing: Set<UUID> = [repositoryID]
        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).map(\.name) == ["waiting"])

        // While a prune holds the repository, the plan must not start …
        #expect(Scheduler.duePlans(
            in: [plan], now: now, existingRepositoryIDs: existing, busyRepositoryIDs: [repositoryID]
        ).isEmpty)

        // … and because nothing was recorded as run, it is still due afterwards.
        #expect(Scheduler.duePlans(in: [plan], now: now, existingRepositoryIDs: existing).map(\.name) == ["waiting"])
    }
}

@Suite("Schedule across DST transitions")
struct DSTScheduleTests {
    /// Los Angeles observes DST, which the UTC-pinned suites never exercise.
    private var losAngeles: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// A wall-clock instant in Los Angeles. Unlike `DateFormatter`, which
    /// returns nil for a time inside the spring-forward gap, `Calendar`
    /// resolves a nonexistent time to the edge of the gap — which is exactly
    /// the behaviour under test.
    private func la(_ hour: Int, _ minute: Int = 0, _ day: Int, _ month: Int, year: Int = 2026) -> Date {
        losAngeles.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func dailySchedule(hour: Int, minute: Int) -> Schedule {
        var schedule = Schedule()
        schedule.frequency = .daily
        schedule.hour = hour
        schedule.minute = minute
        return schedule
    }

    @Test("a daily slot inside the spring-forward gap still fires once, close to its wall-clock time")
    func springForward() throws {
        // 2026-03-08 02:00 PST becomes 03:00 PDT: a 02:30 slot does not exist
        // that day. Whatever instant Calendar resolves the missing time to, the
        // run must be due that morning (not skipped, not pushed to the next
        // day) and the following day must be back at the ordinary slot.
        let schedule = dailySchedule(hour: 2, minute: 30)
        let now = la(9, 0, 8, 3) // after the gap
        let next = try #require(schedule.nextRunDate(
            after: la(2, 30, 7, 3),
            now: now,
            calendar: losAngeles
        ))

        #expect(next > la(2, 30, 7, 3), "the last run must not cover the gap day")
        #expect(next <= now, "the missed gap-slot must be due immediately when the app wakes up — the catch-up rule, not a skip to tomorrow")
        // Calendar resolves the nonexistent 02:30 to 03:00, half an hour late.
        #expect(
            abs(next.timeIntervalSince(la(2, 30, 8, 3))) < 3600,
            "the resolution must stay within an hour of the intended wall-clock slot"
        )

        let followingDay = try #require(schedule.nextRunDate(after: next, now: now, calendar: losAngeles))
        #expect(followingDay == la(2, 30, 9, 3), "the next day is back at the ordinary slot")
    }

    @Test("a daily slot inside the fall-back repeat fires once, not twice")
    func fallBack() throws {
        // 2026-11-01 01:00 PDT becomes 01:00 PST: 01:30 happens twice. The
        // schedule must treat the day as having exactly one 01:30 slot.
        let schedule = dailySchedule(hour: 1, minute: 30)
        let now = la(12, 0, 1, 11)

        // Never ran: due at that morning's slot (either 01:30 occurrence —
        // which instant Calendar picks is its policy — but the same day).
        let first = try #require(schedule.nextRunDate(after: nil, now: now, calendar: losAngeles))
        let day = losAngeles.dateComponents([.year, .month, .day], from: first)
        #expect(day == DateComponents(year: 2026, month: 11, day: 1))
        let secondOccurrence = la(1, 30, 1, 11).addingTimeInterval(3600)
        #expect(first >= la(1, 30, 1, 11) && first <= secondOccurrence, "the resolved instant is one of the two 01:30s")

        // Having run at that slot, the next firing is tomorrow's — the repeated
        // hour must not trigger a second run.
        let next = try #require(schedule.nextRunDate(after: first, now: now, calendar: losAngeles))
        #expect(next == la(1, 30, 2, 11))
    }

    @Test("an ordinary afternoon slot is unaffected by either transition")
    func ordinarySlotUnchanged() {
        let schedule = dailySchedule(hour: 12, minute: 0)
        #expect(schedule.nextRunDate(
            after: la(12, 0, 7, 3),
            now: la(13, 0, 8, 3),
            calendar: losAngeles
        ) == la(12, 0, 8, 3))
        #expect(schedule.nextRunDate(
            after: la(12, 0, 1, 11),
            now: la(13, 0, 2, 11),
            calendar: losAngeles
        ) == la(12, 0, 2, 11))
    }
}

@Suite("Upcoming run")
struct UpcomingRunTests {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func plan(
        name: String,
        frequency: Schedule.Frequency,
        lastRun: Date?,
        enabled: Bool = true,
        sources: [String] = ["/tmp"]
    ) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = UUID()
        plan.sources = sources
        plan.isEnabled = enabled
        plan.schedule.frequency = frequency
        plan.schedule.intervalHours = 1
        plan.schedule.hour = 2
        plan.lastRunAt = lastRun
        return plan
    }

    @Test("the soonest upcoming run wins, manual and incomplete plans are never listed")
    func soonestWins() {
        let soon = plan(name: "hourly", frequency: .hourly, lastRun: date("2026-09-05 11:50:00"))
        let later = plan(name: "daily", frequency: .daily, lastRun: date("2026-09-05 02:00:00"))
        let manual = plan(name: "manual", frequency: .manual, lastRun: nil)
        let disabled = plan(name: "disabled", frequency: .hourly, lastRun: nil, enabled: false)
        let incomplete = plan(name: "incomplete", frequency: .hourly, lastRun: nil, sources: [])

        let now = date("2026-09-05 12:00:00")
        let next = Scheduler.nextScheduledRun(
            in: [manual, later, disabled, incomplete, soon],
            now: now,
            existingRepositoryIDs: Set([manual, later, disabled, incomplete, soon].compactMap(\.repositoryID))
        )
        #expect(next?.plan.id == soon.id)
        // An hourly plan that ran ten minutes ago is due in fifty.
        #expect(next?.date == date("2026-09-05 12:50:00"))
    }

    @Test("an overdue plan is shown as due now, not in the past")
    func overdueIsClampedToNow() {
        // Last ran five hours ago on an hourly schedule: the date is in the past,
        // and the menu bar must not show a negative countdown.
        let overdue = plan(name: "hourly", frequency: .hourly, lastRun: date("2026-09-05 07:00:00"))
        let now = date("2026-09-05 12:00:00")
        let next = Scheduler.nextScheduledRun(in: [overdue], now: now, existingRepositoryIDs: Set([overdue.repositoryID!]))
        #expect(next?.date == now)
    }

    @Test("no runnable plan means no upcoming run")
    func noneScheduled() {
        let manual = plan(name: "manual", frequency: .manual, lastRun: nil)
        #expect(Scheduler.nextScheduledRun(in: [manual], now: date("2026-09-05 12:00:00"), existingRepositoryIDs: []) == nil)
        #expect(Scheduler.nextScheduledRun(in: [], now: date("2026-09-05 12:00:00"), existingRepositoryIDs: []) == nil)
    }
}

@Suite("Repository maintenance scheduling")
struct MaintenanceSchedulingTests {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: string)!
    }

    private func repository(_ configure: (inout Repository) -> Void) -> Repository {
        var repository = Repository()
        repository.name = "Repo"
        repository.kind = .local
        repository.localPath = "/tmp/repo"
        repository.createdAt = date("2026-09-01 00:00:00")
        configure(&repository)
        return repository
    }

    @Test("a freshly added repository counts from when it was added, not from zero")
    func newRepositoryIsNotImmediatelyDue() {
        let repository = repository { $0.maintenance.checkIntervalDays = 7 }
        // Adding a repository must not kick off a check — or, worse, a prune —
        // the moment it appears in the sidebar.
        #expect(Scheduler.dueMaintenance(
            in: [repository],
            now: date("2026-09-05 00:00:00")
        ).isEmpty)

        let due = Scheduler.dueMaintenance(in: [repository], now: date("2026-09-09 00:00:00"))
        #expect(due.map(\.task) == [.check])
    }

    @Test("prune is chosen over check when both have fallen due")
    func pruneWinsOverCheck() {
        let repository = repository {
            $0.maintenance.checkIntervalDays = 1
            $0.maintenance.pruneEnabled = true
            $0.maintenance.pruneIntervalDays = 1
        }
        let due = Scheduler.dueMaintenance(in: [repository], now: date("2026-09-10 00:00:00"))
        #expect(due.map(\.task) == [.prune])
    }

    @Test("a disabled task never comes due")
    func disabledTasksNeverDue() {
        let repository = repository {
            $0.maintenance.checkEnabled = false
            $0.maintenance.pruneEnabled = false
        }
        #expect(Scheduler.dueMaintenance(in: [repository], now: date("2027-01-01 00:00:00")).isEmpty)
        #expect(repository.maintenance.summary == "Off")
    }

    @Test("a busy repository is skipped entirely")
    func busyRepositoryIsSkipped() {
        let repository = repository { $0.maintenance.checkIntervalDays = 1 }
        let now = date("2026-09-10 00:00:00")
        #expect(Scheduler.dueMaintenance(in: [repository], now: now).count == 1)
        #expect(Scheduler.dueMaintenance(
            in: [repository],
            now: now,
            busyRepositoryIDs: [repository.id]
        ).isEmpty)
    }

    @Test("running a task pushes the next one out by a full interval")
    func lastRunMovesTheSchedule() {
        var repository = repository { $0.maintenance.checkIntervalDays = 7 }
        repository.maintenance.lastCheckAt = date("2026-09-09 00:00:00")
        #expect(Scheduler.dueMaintenance(in: [repository], now: date("2026-09-12 00:00:00")).isEmpty)
        #expect(Scheduler.dueMaintenance(in: [repository], now: date("2026-09-16 00:00:01")).count == 1)
    }

    @Test("the policy summary names both tasks and a deep check's read percentage")
    func policySummary() {
        #expect(MaintenancePolicy().summary == "Check every 7d")

        var deep = MaintenancePolicy()
        deep.checkReadDataPercent = 25
        #expect(deep.summary == "Check every 7d (reads 25% of data)")

        var both = MaintenancePolicy()
        both.pruneEnabled = true
        #expect(both.summary == "Check every 7d, Prune every 30d")
    }

    @Test("the schedule summarises itself for the plan list")
    func scheduleSummary() {
        var manual = Schedule()
        manual.frequency = .manual
        #expect(manual.summary == "Manually")

        var hourly = Schedule()
        hourly.frequency = .hourly
        hourly.intervalHours = 4
        #expect(hourly.summary == "Every 4 hours")
        hourly.intervalHours = 1
        #expect(hourly.summary == "Every hour")

        var daily = Schedule()
        daily.frequency = .daily
        daily.hour = 2
        daily.minute = 5
        #expect(daily.summary == "Daily at 02:05")

        // The weekday name comes from Calendar.current, so the words depend on
        // the machine's locale — assert only the shape.
        var weekly = Schedule()
        weekly.frequency = .weekly
        weekly.hour = 3
        #expect(weekly.summary.hasSuffix(" at 03:00"))
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

    @Test("a disabled policy never runs even with rules set")
    func disabledPolicy() {
        var policy = RetentionPolicy()
        policy.isEnabled = false
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

    @Test("the summary spells out what is kept, or why nothing will be")
    func summaries() {
        var disabled = RetentionPolicy()
        disabled.isEnabled = false
        #expect(disabled.summary == "Keep everything")

        var empty = RetentionPolicy()
        empty.keepHourly = 0
        empty.keepDaily = 0
        empty.keepWeekly = 0
        empty.keepMonthly = 0
        empty.keepYearly = 0
        #expect(empty.summary == "No rules set")

        var mixed = RetentionPolicy()
        mixed.keepLast = 3
        mixed.keepHourly = 24
        mixed.keepDaily = 0
        mixed.keepWeekly = 0
        mixed.keepMonthly = 12
        mixed.keepYearly = 0
        #expect(mixed.summary == "Keep 3 latest, 24h, 12m")
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

        var sftp = Repository()
        sftp.kind = .sftp
        sftp.sftpUser = "backup"
        sftp.sftpHost = "nas.local"
        sftp.sftpPath = "/volume1/restic"
        #expect(sftp.resticRepositoryString == "sftp:backup@nas.local:/volume1/restic")

        var s3 = Repository()
        s3.kind = .s3
        s3.s3Endpoint = "s3.eu-central-1.amazonaws.com"
        s3.s3Bucket = "my-bucket"
        s3.s3Prefix = "/macs/laptop/"
        #expect(s3.resticRepositoryString == "s3:s3.eu-central-1.amazonaws.com/my-bucket/macs/laptop")

        var b2 = Repository()
        b2.kind = .b2
        b2.b2Bucket = "my-bucket"
        b2.b2Prefix = "laptop"
        #expect(b2.resticRepositoryString == "b2:my-bucket:laptop")

        var rest = Repository()
        rest.kind = .rest
        rest.restURL = "https://host:8000/"
        #expect(rest.resticRepositoryString == "rest:https://host:8000/")
    }

    @Test("provider secrets map to the environment variables each backend reads")
    func credentialEnvironment() {
        var s3 = Repository()
        s3.kind = .s3
        s3.s3AccessKeyID = "AKIA"
        let s3Env = s3.credentialEnvironment(secret: "shhh")
        #expect(s3Env["AWS_ACCESS_KEY_ID"] == "AKIA")
        #expect(s3Env["AWS_SECRET_ACCESS_KEY"] == "shhh")

        var b2 = Repository()
        b2.kind = .b2
        b2.b2AccountID = "0011"
        let b2Env = b2.credentialEnvironment(secret: "key")
        #expect(b2Env["B2_ACCOUNT_ID"] == "0011")
        #expect(b2Env["B2_ACCOUNT_KEY"] == "key")

        var local = Repository()
        local.kind = .local
        #expect(local.credentialEnvironment(secret: nil).isEmpty)
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
}

@Suite("Additional backends")
struct AdditionalBackendTests {
    @Test("azure, gcs and rclone build the repository strings restic expects")
    func repositoryStrings() {
        var azure = Repository()
        azure.kind = .azure
        azure.azureContainer = "backups"
        azure.azureAccountName = "acct"
        #expect(azure.resticRepositoryString == "azure:backups")
        azure.azurePrefix = "/mac/laptop/"
        #expect(azure.resticRepositoryString == "azure:backups:/mac/laptop")

        var gcs = Repository()
        gcs.kind = .gcs
        gcs.gcsBucket = "my-bucket"
        #expect(gcs.resticRepositoryString == "gs:my-bucket")
        gcs.gcsPrefix = "laptop"
        #expect(gcs.resticRepositoryString == "gs:my-bucket:/laptop")

        var rclone = Repository()
        rclone.kind = .rclone
        rclone.rcloneRemote = "mydrive"
        rclone.rclonePath = "/backups/mac/"
        #expect(rclone.resticRepositoryString == "rclone:mydrive:backups/mac")
        // A remote typed with rclone's own trailing colon must not double up.
        rclone.rcloneRemote = "mydrive:"
        #expect(rclone.resticRepositoryString == "rclone:mydrive:backups/mac")
    }

    @Test("credentials map to each backend's environment variables")
    func credentialEnvironment() {
        var azure = Repository()
        azure.kind = .azure
        azure.azureAccountName = "acct"
        let azureEnv = azure.credentialEnvironment(secret: "key")
        #expect(azureEnv["AZURE_ACCOUNT_NAME"] == "acct")
        #expect(azureEnv["AZURE_ACCOUNT_KEY"] == "key")

        var gcs = Repository()
        gcs.kind = .gcs
        gcs.gcsProjectID = "proj"
        gcs.gcsCredentialsPath = "~/key.json"
        let gcsEnv = gcs.credentialEnvironment(secret: nil)
        #expect(gcsEnv["GOOGLE_PROJECT_ID"] == "proj")
        // The path is expanded here because restic opens the file itself and
        // gets no shell to do it for us.
        #expect(gcsEnv["GOOGLE_APPLICATION_CREDENTIALS"] == NSHomeDirectory() + "/key.json")

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
        #expect(repository.name == "Old")
        #expect(repository.localPath == "/tmp/repo")
        #expect(repository.s3Endpoint == "s3.amazonaws.com")
        #expect(repository.azureContainer.isEmpty)
        #expect(repository.rcloneRemote.isEmpty)
    }
}

@Suite("Repository completeness")
struct RepositoryCompletenessTests {
    /// The non-secret fields each backend needs before restic can be run at all.
    /// Computed, not stored: closure tables are not `Sendable` and Swift 6
    /// refuses a shared static one.
    private static var requiredFields: [Repository.Kind: (inout Repository) -> Void] {
        [
            .local: { $0.localPath = "/Volumes/Backup" },
            .sftp: { $0.sftpHost = "nas.local"; $0.sftpPath = "/volume1/restic" },
            .s3: { $0.s3Bucket = "bucket"; $0.s3AccessKeyID = "AKIA" },
            .b2: { $0.b2Bucket = "bucket"; $0.b2AccountID = "0011" },
            .azure: { $0.azureContainer = "container"; $0.azureAccountName = "acct" },
            .gcs: { $0.gcsBucket = "bucket"; $0.gcsCredentialsPath = "~/key.json" },
            .rest: { $0.restURL = "https://host:8000" },
            .rclone: { $0.rcloneRemote = "mydrive" },
        ]
    }

    @Test("a repository is complete exactly when its backend's required fields are filled")
    func completenessPerKind() {
        for kind in Repository.Kind.allCases {
            guard let fill = Self.requiredFields[kind] else {
                Issue.record("no required-field spec for \(kind)")
                continue
            }

            var complete = Repository()
            complete.name = "Repo"
            complete.kind = kind
            fill(&complete)
            #expect(complete.isConfigurationComplete, "\(kind) with every required field must be complete")

            // A fresh repository of the same kind has none of them filled. The
            // scheduler refuses to schedule incomplete repositories, so this
            // must never read as runnable.
            var bare = Repository()
            bare.name = "Repo"
            bare.kind = kind
            #expect(!bare.isConfigurationComplete, "a fresh \(kind) repository must be incomplete")
        }
    }

    @Test("a blank name makes even a fully configured repository incomplete")
    func blankNameIsIncomplete() {
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/Backup"
        repository.name = "   "
        #expect(!repository.isConfigurationComplete)
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
    }

    @Test("an installed copy is accepted")
    func acceptsInstalledLocations() {
        #expect(LoginItem.isInstallableLocation("/Applications/SwiftRestic.app"))
        #expect(LoginItem.isInstallableLocation("/Applications/Utilities/SwiftRestic.app"))
        #expect(LoginItem.isInstallableLocation("\(NSHomeDirectory())/Applications/SwiftRestic.app"))
    }
}
