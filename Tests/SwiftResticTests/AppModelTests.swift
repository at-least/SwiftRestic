import Foundation
import Testing

/// Exercises the glue between the scheduler, `ResticService` and the stored run
/// history — the layer where a real backup can succeed while the app still
/// records it wrongly.
@Suite("AppModel backup flow", .serialized, .enabled(if: ResticAvailability.isInstalled))
@MainActor
struct AppModelTests {
    private struct Harness {
        var model: AppModel
        var root: URL
        var repository: Repository
        var plan: BackupPlan
        var sourceDirectory: URL
    }

    /// Builds a ready-to-use repository *before* the model exists.
    ///
    /// `bootstrap()` starts the scheduler, so anything a due plan needs has to be
    /// in place first — otherwise the scheduler's own first tick races the test.
    /// Tests that are not about scheduling use `.manual` so only they decide when
    /// a backup happens.
    private func makeHarness(
        retention: RetentionPolicy = RetentionPolicy(),
        frequency: Schedule.Frequency = .manual
    ) async throws -> Harness {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticApp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.resolvingSymlinksInPath()

        let sourceDirectory = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try "one".write(to: sourceDirectory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: sourceDirectory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        var repository = Repository()
        repository.name = "Test Repo"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path

        var plan = BackupPlan()
        plan.name = "Test Plan"
        plan.repositoryID = repository.id
        plan.sources = [sourceDirectory.path]
        plan.excludePatterns = []
        plan.schedule.frequency = frequency
        plan.schedule.intervalHours = 1
        plan.retention = retention

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]

        let storeDirectory = root.appendingPathComponent("config")
        let store = ConfigStore(directory: storeDirectory)
        try await store.save(configuration)

        let binary = try ResticBinary.locate(userOverride: nil)
        _ = try await ResticService(runner: ResticRunner(), binary: binary.url)
            .initializeRepository(RepositoryContext(repository: repository, password: "test-password"))

        let model = AppModel(
            store: store,
            secrets: .inMemory([repository.id: (password: "test-password", providerSecret: nil)])
        )
        await model.bootstrap()

        return Harness(
            model: model,
            root: root,
            repository: repository,
            plan: plan,
            sourceDirectory: sourceDirectory
        )
    }

    @Test("a successful run updates the plan, the history and the snapshot list")
    func successfulBackup() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .succeeded)
        #expect(record.kind == .backup)
        #expect(record.snapshotID != nil)
        #expect(record.filesNew == 2)
        #expect(record.failureMessage == nil)

        // The sidebar reads these; a run that produced a snapshot must never
        // leave the plan looking like it has never succeeded.
        let plan = try #require(model.plan(id: harness.plan.id))
        #expect(plan.lastSuccessAt != nil)
        #expect(plan.lastRunAt != nil)

        #expect(model.snapshots(for: harness.repository.id, planID: harness.plan.id).count == 1)
        #expect(model.activity.isEmpty)

        await model.shutdown()
    }

    @Test("retention runs after the backup and trims the plan's own snapshots")
    func retentionAfterBackup() async throws {
        var retention = RetentionPolicy()
        retention.keepLast = 1
        retention.keepHourly = 0
        retention.keepDaily = 0
        retention.keepWeekly = 0
        retention.keepMonthly = 0
        retention.keepYearly = 0
        let harness = try await makeHarness(retention: retention)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        for index in 0 ..< 3 {
            try "change \(index)".write(
                to: harness.sourceDirectory.appendingPathComponent("a.txt"),
                atomically: true,
                encoding: .utf8
            )
            model.runBackup(planID: harness.plan.id)
            await model.waitForRun(planID: harness.plan.id)
        }

        #expect(model.configuration.runs.count == 3)
        #expect(model.configuration.runs.allSatisfy { $0.outcome == .succeeded })
        #expect(model.snapshots(for: harness.repository.id, planID: harness.plan.id).count == 1)

        await model.shutdown()
    }

    @Test("a run against a missing repository is recorded as failed, not silently dropped")
    func failedBackupIsRecorded() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // Delete the repository out from under the plan.
        try FileManager.default.removeItem(at: harness.root.appendingPathComponent("repo"))

        model.runBackup(planID: harness.plan.id)
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.failureMessage != nil)
        #expect(model.plan(id: harness.plan.id)?.lastSuccessAt == nil)
        #expect(model.plan(id: harness.plan.id)?.lastRunAt != nil)

        await model.shutdown()
    }

    @Test("an after-success hook runs and is told about the snapshot")
    func afterSuccessHookRuns() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let markerPath = harness.root.appendingPathComponent("hook-output.txt").path
        var hook = BackupHook()
        hook.name = "record snapshot"
        hook.event = .afterSuccess
        hook.command = #"printf '%s %s' "$SWIFTRESTIC_OUTCOME" "$SWIFTRESTIC_SNAPSHOT_ID" > "\#(markerPath)""#

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .succeeded)
        let snapshotID = try #require(record.snapshotID)

        let written = try String(contentsOfFile: markerPath, encoding: .utf8)
        #expect(written == "succeeded \(snapshotID)")

        await model.shutdown()
    }

    @Test("a before-backup hook set to cancel stops the backup happening at all")
    func abortingHookPreventsBackup() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var hook = BackupHook()
        hook.name = "gatekeeper"
        hook.event = .beforeBackup
        hook.command = "echo 'not today' >&2; exit 1"
        hook.failureBehaviour = .abortBackup

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.snapshotID == nil)
        #expect(record.hookMessages.contains { $0.contains("gatekeeper") })
        // Hook output must not be filed as a restic warning: that is what gets
        // sent to external notification channels.
        #expect(record.itemErrors.isEmpty)
        // Nothing may have been written to the repository.
        #expect(model.snapshots(for: harness.repository.id, planID: plan.id).isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt == nil)

        await model.shutdown()
    }

    @Test("a failing after-success hook is recorded but does not undo the backup")
    func failingAfterHookDoesNotFailTheRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var hook = BackupHook()
        hook.name = "noisy"
        hook.event = .afterAny
        hook.command = "exit 9"

        var plan = harness.plan
        plan.hooks = [hook]
        model.upsert(plan: plan)

        model.runBackup(planID: plan.id)
        await model.waitForRun(planID: plan.id)

        let record = try #require(model.configuration.runs.first)
        // The snapshot exists, so the run is not a failure — but the hook's exit
        // code has to be visible somewhere.
        #expect(record.outcome != .failed)
        #expect(record.snapshotID != nil)
        #expect(record.hookMessages.contains { $0.contains("noisy") && $0.contains("exited 9") })
        #expect(record.itemErrors.isEmpty)
        #expect(model.plan(id: plan.id)?.lastSuccessAt != nil)

        await model.shutdown()
    }

    @Test("repository hooks run around a check and are told which task it was")
    func maintenanceHooksRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let markerPath = harness.root.appendingPathComponent("check-hook.txt").path
        var hook = BackupHook()
        hook.name = "record check"
        hook.event = .afterMaintenanceSuccess
        hook.command = #"printf '%s %s %s' "$SWIFTRESTIC_TASK" "$SWIFTRESTIC_OUTCOME" "$SWIFTRESTIC_EVENT" > "\#(markerPath)""#

        var repository = harness.repository
        repository.hooks = [hook]
        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        model.runMaintenance(id: repository.id, task: .check, readDataPercent: 0)
        await model.waitForMaintenance(repositoryID: repository.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.kind == .check)
        #expect(record.outcome == .succeeded)
        #expect(record.hookMessages.isEmpty)
        #expect(try String(contentsOfFile: markerPath, encoding: .utf8) == "check succeeded afterMaintenanceSuccess")

        await model.shutdown()
    }

    @Test("a before-maintenance hook set to cancel stops the check and still stamps the schedule")
    func abortingHookPreventsMaintenance() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        var gate = BackupHook()
        gate.name = "gatekeeper"
        gate.event = .beforeMaintenance
        gate.command = "echo 'disk is busy' >&2; exit 1"
        gate.failureBehaviour = .abortBackup

        let markerPath = harness.root.appendingPathComponent("failure-hook.txt").path
        var onFailure = BackupHook()
        onFailure.name = "report"
        onFailure.event = .afterMaintenanceFailure
        onFailure.command = #"printf '%s' "$SWIFTRESTIC_ERROR" > "\#(markerPath)""#

        var repository = harness.repository
        repository.hooks = [gate, onFailure]
        await model.upsert(repository: repository, password: nil, providerSecret: nil)

        model.runMaintenance(id: repository.id, task: .check, readDataPercent: 0)
        await model.waitForMaintenance(repositoryID: repository.id)

        let record = try #require(model.configuration.runs.first)
        #expect(record.outcome == .failed)
        #expect(record.hookMessages.contains { $0.contains("gatekeeper") && $0.contains("disk is busy") })
        #expect(record.itemErrors.isEmpty)
        // The after-failure hook still fires, with the reason.
        #expect(try String(contentsOfFile: markerPath, encoding: .utf8).contains("cancel the check"))
        // A hook that always refuses must not turn into a retry every minute.
        #expect(model.repository(id: repository.id)?.maintenance.lastCheckAt != nil)

        await model.shutdown()
    }

    @Test("quitting during a backup still gets the run onto disk")
    func shutdownPersistsInFlightRun() async throws {
        let harness = try await makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        // Enough data that the backup is still running when we quit.
        let bulk = harness.sourceDirectory.appendingPathComponent("bulk")
        try FileManager.default.createDirectory(at: bulk, withIntermediateDirectories: true)
        for index in 0 ..< 50 {
            try Data((0 ..< 2_000_000).map { UInt8(($0 &+ index) % 251) })
                .write(to: bulk.appendingPathComponent("f\(index).bin"))
        }

        model.runBackup(planID: harness.plan.id)
        try await Task.sleep(for: .milliseconds(400))

        // shutdown() cancels the run; the record is written while it unwinds, and
        // the debounced save would never fire if shutdown did not wait for it.
        await model.shutdown()

        let reloaded = try await ConfigStore(
            directory: harness.root.appendingPathComponent("config")
        ).load()
        #expect(reloaded.runs.count == 1, "the in-flight run never reached disk")
        #expect(reloaded.runs.first?.outcome != .failed)
        #expect(reloaded.plans.first?.lastRunAt != nil)
    }

    @Test("the scheduler starts a due plan on its own, and the history is persisted")
    func schedulerRunsDuePlanUnprompted() async throws {
        // An hourly plan that has never run is due the moment the app starts, so
        // nothing here triggers the backup — the scheduler has to.
        let harness = try await makeHarness(frequency: .hourly)
        defer { try? FileManager.default.removeItem(at: harness.root) }
        let model = harness.model

        let deadline = Date.now.addingTimeInterval(30)
        while model.configuration.runs.isEmpty, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        await model.waitForRun(planID: harness.plan.id)

        let record = try #require(model.configuration.runs.first, "the scheduler never ran the plan")
        #expect(record.planID == harness.plan.id)
        // The invariant that matters: once a snapshot exists, the run is never
        // recorded as a failure, whatever happens during the retention step.
        #expect(record.outcome != .failed)
        #expect(model.plan(id: harness.plan.id)?.lastSuccessAt != nil)
        #expect(record.outcome == .succeeded, "unexpected warnings: \(record.itemErrors)")

        // Having just run, the plan must not be due again immediately.
        #expect(Scheduler.duePlans(in: model.configuration.plans).isEmpty)

        await model.flushSave()
        let reloaded = try await ConfigStore(
            directory: harness.root.appendingPathComponent("config")
        ).load()
        #expect(reloaded.runs.count == 1)
        #expect(reloaded.runs.first?.outcome == .succeeded)
        #expect(reloaded.plans.first?.lastSuccessAt != nil)

        await model.shutdown()
    }
}
