import Foundation
import Testing

/// The run engines' sequencing and outcome mapping, driven through a mock
/// client and a recording sink — no process, no binary, milliseconds per
/// case. The stub-shell and real-restic suites still own everything below
/// the `ResticClient` seam.
@MainActor
@Suite("backup run engine")
struct BackupRunEngineTests {
    /// Records every sink call in order; the ordered log is what the
    /// sequencing assertions read.
    final class RecordingSink: BackupRunEngine.Sink {
        var log: [String] = []
        var deliveredRecords: [RunRecord] = []

        var cancellationMessage = "cancelled in test"

        func service() throws -> any ResticClient { throw ResticError.repositoryMissing }
        func context(for repository: Repository) async throws -> RepositoryContext {
            log.append("context")
            return RepositoryContext(repository: repository, password: "test")
        }

        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
            log.append("phase:\(phase)")
        }

        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
            log.append("reporter-built")
            return { _ in }
        }

        func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool) {
            log.append("mark:\(succeeded)")
        }

        func noteAuthFailure(_ error: Error, repositoryID: UUID) {
            log.append("auth-noted")
        }

        func addStartPing(_ event: NotificationEvent) {
            log.append("ping:\(event.stage)")
        }

        func refreshSnapshots(repositoryID: UUID) async {
            log.append("refresh")
        }

        func deliver(record: RunRecord, plan: BackupPlan) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
        }

        func makeHookRunner() -> HookRunner {
            HookRunner(runner: ResticRunner())
        }
    }

    private func makePlan(retentionEnabled: Bool = true) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = "Engine Plan"
        plan.repositoryID = Repository().id
        plan.sources = ["/tmp/engine-source"]
        if !retentionEnabled { plan.retention.isEnabled = false }
        return plan
    }

    private func successOutcome(snapshotID: String? = "cafe0000") -> BackupOutcome {
        var summary = ResticSummary()
        summary.snapshotID = snapshotID
        summary.filesNew = 2
        summary.totalBytesProcessed = 1234
        return BackupOutcome(summary: summary, itemErrors: [], exitCode: 0)
    }

    @Test("a clean run pings, backs up, applies retention, refreshes, delivers")
    func cleanRunSequencing() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome()))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: StubServiceSink(client: client, base: sink))

        // The ping must precede the backup (a monitor's timer starts at the
        // ping), the success stamp must land before anything later can fail
        // the run, retention must follow a produced snapshot, and the
        // closing refresh must follow retention (lock ordering).
        #expect(sink.log == [
            "context",
            "ping:started",
            "phase:backingUp",
            "reporter-built",
            "mark:true",
            "phase:applyingRetention",
            "refresh",
            "deliver:succeeded",
        ], "log was \(sink.log)")
        #expect(sink.deliveredRecords.count == 1)
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
        #expect(sink.deliveredRecords[0].snapshotID == "cafe0000")
    }

    @Test("no snapshot written means retention never runs")
    func retentionNeedsASnapshot() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(.success(successOutcome(snapshotID: nil)))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: StubServiceSink(client: client, base: sink))

        #expect(!sink.log.contains { $0.hasPrefix("phase:applyingRetention") })
        // The run itself still succeeded and was delivered.
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
    }

    @Test("a failed backup is marked failed, noted for auth when exit 12, delivered")
    func failedRun() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onBackup(
            .failure(ResticError.commandFailed(exitCode: 12, message: "wrong password", command: "restic backup"))
        )
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: StubServiceSink(client: client, base: sink))

        #expect(sink.log.contains("mark:false"))
        #expect(sink.log.contains("auth-noted"))
        #expect(sink.deliveredRecords[0].outcome == .failed)
    }

    @Test("a retention failure degrades to warnings, never fails the run")
    func retentionFailureIsADegradation() async throws {
        let sink = RecordingSink()
        let client = MockResticClient()
            .onBackup(.success(successOutcome()))
            .onForget(.failure(ResticError.commandFailed(exitCode: 11, message: "locked", command: "restic forget")))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: StubServiceSink(client: client, base: sink))

        let record = sink.deliveredRecords[0]
        #expect(record.outcome == .completedWithErrors)
        #expect(record.itemErrors.contains { $0.contains("Retention skipped") })
        // The snapshot was written; the run itself stays marked successful.
        #expect(sink.log.contains("mark:true"))
    }

    @Test("item errors from restic read as completed-with-errors")
    func partialReadRun() async throws {
        let sink = RecordingSink()
        let outcome = BackupOutcome(summary: nil, itemErrors: ["/etc/x: permission denied"], exitCode: 3)
        let client = MockResticClient().onBackup(.success(outcome))
        let plan = makePlan()
        await BackupRunEngine.perform(plan: plan, repository: Repository(), sink: StubServiceSink(client: client, base: sink))

        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        #expect(sink.deliveredRecords[0].itemErrors == ["/etc/x: permission denied"])
    }
}

@MainActor
@Suite("maintenance run engine")
struct MaintenanceRunEngineTests {
    final class RecordingSink: MaintenanceRunEngine.Sink {
        var log: [String] = []
        var deliveredRecords: [RunRecord] = []
        var cancellationMessage = "cancelled in test"

        func service() throws -> any ResticClient { throw ResticError.repositoryMissing }
        func context(for repository: Repository) async throws -> RepositoryContext {
            log.append("context")
            return RepositoryContext(repository: repository, password: "test")
        }

        func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void {
            { [weak self] _ in Task { @MainActor in self?.log.append("prune-line") } }
        }

        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
            log.append("stamp:\(task.rawValue)")
        }

        func markPasswordMissing(repositoryID: UUID) {
            log.append("password-missing")
        }

        func noteAuthFailure(_ error: Error, repositoryID: UUID) {
            log.append("auth-noted")
        }

        func deliver(record: RunRecord, repository: Repository) async {
            log.append("deliver:\(record.outcome)")
            deliveredRecords.append(record)
        }

        func refreshSnapshots(repositoryID: UUID) async {
            log.append("refresh")
        }

        func makeHookRunner() -> HookRunner {
            HookRunner(runner: ResticRunner())
        }
    }

    @Test("a clean check is delivered succeeded with its verdict")
    func cleanCheck() async throws {
        let sink = RecordingSink()
        var summary = ResticSummary()
        summary.numErrors = 0
        let client = MockResticClient().onCheck(.success(summary))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: StubMaintenanceServiceSink(client: client, base: sink)
        )
        #expect(sink.deliveredRecords[0].outcome == .succeeded)
        #expect(sink.deliveredRecords[0].detailText == "No errors found.")
        #expect(sink.log.contains("stamp:check"))
    }

    @Test("a check that found errors is a warning, and suggests prune when restic does")
    func checkWithErrors() async throws {
        let sink = RecordingSink()
        var summary = ResticSummary()
        summary.numErrors = 2
        summary.suggestPrune = true
        let client = MockResticClient().onCheck(.success(summary))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: StubMaintenanceServiceSink(client: client, base: sink)
        )
        #expect(sink.deliveredRecords[0].outcome == .completedWithErrors)
        #expect(sink.deliveredRecords[0].detailText?.contains("2 error(s)") == true)
        #expect(sink.deliveredRecords[0].detailText?.contains("suggests running prune") == true)
    }

    @Test("a missing password records nothing and stamps nothing")
    func passwordMissingLeavesNoTrace() async throws {
        let sink = RecordingSink()
        let client = MockResticClient().onCheck(.failure(ResticError.passwordMissing(repositoryName: "R")))
        await MaintenanceRunEngine.perform(
            repository: Repository(),
            task: .check,
            readDataPercentOverride: nil,
            sink: StubMaintenanceServiceSink(client: client, base: sink)
        )
        #expect(sink.log == ["context", "password-missing"])
        #expect(sink.deliveredRecords.isEmpty)
    }
}

/// The recording sinks answer `service()` with the mock — a tiny wrapper so
/// the sink classes above stay pure logs.
@MainActor
private final class StubServiceSink: BackupRunEngine.Sink {
    let client: MockResticClient
    let base: BackupRunEngineTests.RecordingSink
    init(client: MockResticClient, base: BackupRunEngineTests.RecordingSink) {
        self.client = client
        self.base = base
    }

    var cancellationMessage: String { base.cancellationMessage }
    func service() throws -> any ResticClient { client }
    func context(for repository: Repository) async throws -> RepositoryContext {
        try await base.context(for: repository)
    }
    func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID) {
        base.setActivityPhase(phase, for: planID)
    }
    func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void {
        base.progressReporter(planID: planID)
    }
    func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool) {
        base.markPlanRun(planID, at: date, succeeded: succeeded)
    }
    func noteAuthFailure(_ error: Error, repositoryID: UUID) {
        base.noteAuthFailure(error, repositoryID: repositoryID)
    }
    func addStartPing(_ event: NotificationEvent) { base.addStartPing(event) }
    func refreshSnapshots(repositoryID: UUID) async { await base.refreshSnapshots(repositoryID: repositoryID) }
    func deliver(record: RunRecord, plan: BackupPlan) async { await base.deliver(record: record, plan: plan) }
    func makeHookRunner() -> HookRunner { base.makeHookRunner() }
}

@MainActor
private final class StubMaintenanceServiceSink: MaintenanceRunEngine.Sink {
    let client: MockResticClient
    let base: MaintenanceRunEngineTests.RecordingSink
    init(client: MockResticClient, base: MaintenanceRunEngineTests.RecordingSink) {
        self.client = client
        self.base = base
    }

    var cancellationMessage: String { base.cancellationMessage }
    func service() throws -> any ResticClient { client }
    func context(for repository: Repository) async throws -> RepositoryContext {
        try await base.context(for: repository)
    }
    func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void {
        base.lineReporter(repositoryID: repositoryID)
    }
    func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
        base.stampMaintenance(repositoryID: repositoryID, task: task, at: date)
    }
    func markPasswordMissing(repositoryID: UUID) { base.markPasswordMissing(repositoryID: repositoryID) }
    func noteAuthFailure(_ error: Error, repositoryID: UUID) {
        base.noteAuthFailure(error, repositoryID: repositoryID)
    }
    func deliver(record: RunRecord, repository: Repository) async {
        await base.deliver(record: record, repository: repository)
    }
    func refreshSnapshots(repositoryID: UUID) async { await base.refreshSnapshots(repositoryID: repositoryID) }
    func makeHookRunner() -> HookRunner { base.makeHookRunner() }
}
