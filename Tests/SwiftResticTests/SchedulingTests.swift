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
    func dailyCatchesUp() {
        var schedule = Schedule()
        schedule.frequency = .daily
        schedule.hour = 2
        schedule.minute = 0

        // 02:00 has passed today and the last run was yesterday morning, so the
        // plan must fire rather than silently skipping to tomorrow.
        let next = schedule.nextRunDate(
            after: date("2026-09-04 02:00:00"),
            now: date("2026-09-05 09:30:00"),
            calendar: calendar
        )
        #expect(next == date("2026-09-05 02:00:00"))
        #expect(next! <= date("2026-09-05 09:30:00"))
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
            busyPlanIDs: [busy.id]
        )
        #expect(due.map(\.name) == ["ready"])
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
        #expect(Scheduler.duePlans(in: [plan], now: now).map(\.name) == ["waiting"])

        // While a prune holds the repository, the plan must not start …
        #expect(Scheduler.duePlans(in: [plan], now: now, busyRepositoryIDs: [repositoryID]).isEmpty)

        // … and because nothing was recorded as run, it is still due afterwards.
        #expect(Scheduler.duePlans(in: [plan], now: now).map(\.name) == ["waiting"])
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
