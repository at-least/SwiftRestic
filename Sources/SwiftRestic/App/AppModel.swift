import Foundation
import Observation
import UserNotifications

/// Live state of one plan that is currently running.
struct PlanActivity: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case starting
        case backingUp
        case applyingRetention
        case runningHooks
        case notifying
        case checking
        case cancelling

        var displayName: String {
            switch self {
            case .starting: "Starting…"
            case .backingUp: "Backing up"
            case .applyingRetention: "Applying retention"
            case .runningHooks: "Running hooks"
            case .notifying: "Sending notifications"
            case .checking: "Checking repository"
            case .cancelling: "Cancelling…"
            }
        }
    }

    var phase: Phase = .starting
    var progress = OperationProgress()
    var startedAt: Date = .now
}

/// Live state of one repository's check or prune.
struct MaintenanceActivity: Sendable, Equatable {
    var task: MaintenanceTask
    var startedAt: Date = .now
    /// The last line the command printed. `prune` narrates in plain text, so
    /// this distinguishes "working" from "hung"; `check --json` stays silent
    /// until it finishes, so there this stays `nil` and elapsed time is the
    /// only live signal.
    var lastOutput: String?
}

/// A transient message shown at the top of the detail pane.
struct Banner: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var message: String
    var isError: Bool
}

/// The single source of truth the SwiftUI views observe.
///
/// Everything that touches persisted state happens here on the main actor;
/// restic itself runs on the `ResticRunner` actor and reports back by hopping
/// home.
@MainActor
@Observable
final class AppModel {
    // MARK: Persisted state

    var configuration = AppConfiguration() {
        didSet { scheduleSave() }
    }

    // MARK: Runtime state

    private(set) var resticVersion: String = ""
    private(set) var binaryProblem: String?
    private(set) var activity: [UUID: PlanActivity] = [:]
    /// Repository upkeep currently in flight, keyed by repository.
    private(set) var maintenance: [UUID: MaintenanceActivity] = [:]
    private(set) var snapshots: [UUID: [Snapshot]] = [:]
    private(set) var repositoryStats: [UUID: RepositoryStats] = [:]
    private(set) var loadingSnapshots: Set<UUID> = []
    /// Repositories with no password in the Keychain yet. Upkeep is not scheduled
    /// for these: there is nothing to run, and stamping a "last checked" time for
    /// a check that never happened would be a lie on the repository screen.
    private(set) var repositoriesMissingPassword: Set<UUID> = []
    private(set) var isLoaded = false
    /// Mirrors `LoginItem.status`, which is not observable on its own.
    private(set) var startsAtLogin = false
    var banner: Banner?
    /// Transient, never persisted: whether Activity shows every run or only
    /// problems. Overview's problem rows and failures tile turn it on when they
    /// send the user over.
    var activityShowsProblemsOnly = false

    /// Progress of a restore, which is always one at a time.
    private(set) var restoreActivity: OperationProgress?
    private(set) var restoreDescription: String = ""

    private let store: ConfigStore
    private let secrets: SecretStore
    private let runner = ResticRunner()
    private var binary: ResticBinary?
    private var planTasks: [UUID: Task<Void, Never>] = [:]
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    /// Start pings in flight. Tracked so quitting mid-backup cannot drop the one
    /// that arms a monitor's timer.
    private var pendingPings: [Task<Void, Never>] = []
    private var restoreTask: Task<Void, Never>?
    private var schedulerTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isSaving = false
    /// Set while `shutdown` is unwinding. A run cancelled this way was not
    /// stopped by the user, and the run record should say so: "Cancelled" sends
    /// someone hunting for a cancel click that never happened.
    private var isShuttingDown = false

    init(store: ConfigStore = ConfigStore(), secrets: SecretStore = .keychain) {
        self.store = store
        self.secrets = secrets
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !isLoaded else { return }
        isLoaded = true

        do {
            configuration = try await store.load()
        } catch {
            banner = Banner(
                title: "Could not read your configuration",
                message: error.localizedDescription,
                isError: true
            )
        }
        // Reset any activity left behind by a crash mid-backup.
        activity.removeAll()
        maintenance.removeAll()
        startsAtLogin = LoginItem.isEnabled
        await resolveBinary()
        // Not awaited: `requestAuthorization` suspends until the user answers the
        // system prompt, and nothing below may wait on that — the scheduler has to
        // start whether or not notifications are ever allowed.
        Task { await self.requestNotificationPermission() }

        // Read the repositories before arming the scheduler. `snapshots`/`stats`
        // hold a shared repository lock while `forget` needs an exclusive one, so
        // starting the scheduler first makes the app race itself on launch: a due
        // plan's retention step fails against our own refresh.
        await refreshAllSnapshots()
        #if DEBUG
        // A capture run must photograph a deterministic state: a live scheduler
        // can fire a due plan mid-capture and put a progress card on screen.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE"] == nil {
            startScheduler()
        }
        #else
        startScheduler()
        #endif
    }

    func shutdown() async {
        isShuttingDown = true
        schedulerTask?.cancel()
        let pending = Array(planTasks.values) + Array(maintenanceTasks.values)
        for task in pending { task.cancel() }
        restoreTask?.cancel()
        await runner.terminateAll()

        // Wait for the cancelled runs to finish unwinding. Their `catch` blocks
        // append a run record and set `lastRunAt`, and those edits only reach disk
        // through a 400 ms debounced save that would never fire once the process
        // exits — so quitting mid-backup would silently lose the run.
        for task in pending { await task.value }
        if let restoreTask { await restoreTask.value }
        // A start ping that never lands would leave a monitor thinking the backup
        // was never attempted rather than that it was interrupted.
        for ping in pendingPings { await ping.value }
        pendingPings.removeAll()

        saveTask?.cancel()
        await flushSave()
    }

    /// Finds the restic binary and reads its version, or records why it could not.
    func resolveBinary() async {
        do {
            let located = try ResticBinary.locate(
                userOverride: configuration.settings.resticPathOverride
            )
            binary = located
            binaryProblem = nil
            let service = ResticService(runner: runner, binary: located.url)
            resticVersion = (try? await service.version()) ?? ""
        } catch {
            binary = nil
            resticVersion = ""
            binaryProblem = error.localizedDescription
        }
    }

    var isResticAvailable: Bool { binary != nil }

    /// Registers or removes the login item, reporting whatever macOS says.
    func setStartsAtLogin(_ enabled: Bool) {
        if enabled, !LoginItem.isInInstallableLocation {
            banner = Banner(
                title: "Cannot start at login from here",
                message: LoginItem.notInstalledMessage,
                isError: true
            )
            startsAtLogin = LoginItem.isEnabled
            return
        }
        do {
            try LoginItem.setEnabled(enabled)
            startsAtLogin = LoginItem.isEnabled
            if enabled, LoginItem.needsApproval {
                banner = Banner(
                    title: "Approval needed",
                    message: LoginItem.statusDescription,
                    isError: false
                )
            }
        } catch {
            startsAtLogin = LoginItem.isEnabled
            banner = Banner(
                title: "Could not change the login item",
                message: error.localizedDescription,
                isError: true
            )
        }
    }

    func refreshLoginItemStatus() { startsAtLogin = LoginItem.isEnabled }

    var resticPath: String { binary?.url.path ?? "" }

    // MARK: - Persistence

    /// Coalesces rapid edits (typing in a text field) into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.flushSave()
        }
    }

    func flushSave() async {
        guard isLoaded else { return }
        // Another write is in progress: wait for it and then write the newer
        // state. Skipping instead would drop the latest edit for good — nothing
        // else would save it, including the single flush at shutdown.
        while isSaving { await Task.yield() }
        isSaving = true
        defer { isSaving = false }
        let snapshot = configuration
        do {
            try await store.save(snapshot)
        } catch {
            banner = Banner(
                title: "Could not save your configuration",
                message: error.localizedDescription,
                isError: true
            )
        }
    }

    // MARK: - Repositories

    func repository(id: UUID?) -> Repository? { configuration.repository(id: id) }

    func upsert(repository: Repository, password: String?, providerSecret: String?) async {
        do {
            try await secrets.save(repository.id, password, providerSecret)
        } catch {
            banner = Banner(title: "Keychain", message: error.localizedDescription, isError: true)
        }
        if password?.isEmpty == false { repositoriesMissingPassword.remove(repository.id) }

        if let index = configuration.repositories.firstIndex(where: { $0.id == repository.id }) {
            configuration.repositories[index] = repository
        } else {
            configuration.repositories.append(repository)
        }

        // The context always applies the stored location and password last, so
        // these entries would silently do nothing. Say so rather than let the
        // user believe a variable is doing work.
        let overridden = RepositoryContext(
            repository: repository,
            password: password ?? "",
            providerSecret: providerSecret
        ).overriddenExtraEnvironmentKeys
        if !overridden.isEmpty {
            banner = Banner(
                title: "Ignored environment variables",
                message: "\(overridden.joined(separator: ", ")) is set by SwiftRestic itself; the value in Extra environment has no effect.",
                isError: false
            )
        }
    }

    /// Removes a repository from the app. The data in the repository is untouched.
    func deleteRepository(id: UUID) {
        configuration.repositories.removeAll { $0.id == id }
        for index in configuration.plans.indices where configuration.plans[index].repositoryID == id {
            configuration.plans[index].repositoryID = nil
            configuration.plans[index].isEnabled = false
        }
        snapshots[id] = nil
        repositoryStats[id] = nil
        Task { [secrets] in await secrets.remove(id) }
    }

    func storedSecrets(for repositoryID: UUID) async -> (password: String?, providerSecret: String?) {
        await secrets.load(repositoryID)
    }

    func storedPassword(for repositoryID: UUID) async -> String? {
        await secrets.load(repositoryID).password
    }

    /// Builds everything a restic command needs, or explains what is missing.
    func context(for repository: Repository) async throws -> RepositoryContext {
        #if DEBUG
        // Capture and CI runs hand over the password through the environment so
        // they never touch the login Keychain. Gated on the throwaway-config
        // override as well, so a stale variable in a developer's shell cannot
        // silently feed the wrong password to a normal debug run.
        if let injected = ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_PASSWORD"],
           !injected.isEmpty,
           ProcessInfo.processInfo.environment["SWIFTRESTIC_CONFIG_DIR"] != nil
        {
            return RepositoryContext(
                repository: repository,
                password: injected,
                providerSecret: ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_SECRET"],
                settings: configuration.settings
            )
        }
        #endif
        let stored = await secrets.load(repository.id)
        guard let password = stored.password, !password.isEmpty else {
            throw ResticError.passwordMissing(repositoryName: repository.name)
        }
        return RepositoryContext(
            repository: repository,
            password: password,
            providerSecret: stored.providerSecret,
            settings: configuration.settings
        )
    }

    func service() throws -> ResticService {
        guard let binary else {
            throw ResticError.binaryNotFound(searched: ResticBinary.searchPaths)
        }
        return ResticService(runner: runner, binary: binary.url)
    }

    // MARK: - Plans

    func plan(id: UUID?) -> BackupPlan? {
        guard let id else { return nil }
        return configuration.plans.first { $0.id == id }
    }

    func upsert(plan: BackupPlan) {
        if let index = configuration.plans.firstIndex(where: { $0.id == plan.id }) {
            configuration.plans[index] = plan
        } else {
            configuration.plans.append(plan)
        }
    }

    func deletePlan(id: UUID) {
        planTasks[id]?.cancel()
        configuration.plans.removeAll { $0.id == id }
        activity[id] = nil
    }

    func isRunning(planID: UUID) -> Bool { activity[planID] != nil }

    var runningPlanIDs: Set<UUID> { Set(activity.keys) }

    // MARK: - Running a backup

    func runBackup(planID: UUID) {
        guard planTasks[planID] == nil else { return }
        guard let plan = plan(id: planID) else { return }
        guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID,
              let repository = repository(id: repositoryID)
        else {
            banner = Banner(
                title: "Plan is incomplete",
                message: "Choose a repository and at least one folder to back up.",
                isError: true
            )
            return
        }

        activity[planID] = PlanActivity()
        planTasks[planID] = Task { [weak self] in
            await self?.performBackup(plan: plan, repository: repository)
            self?.planTasks[planID] = nil
            self?.activity[planID] = nil
        }
    }

    /// Waits for a plan's in-flight run to finish, if there is one.
    func waitForRun(planID: UUID) async {
        await planTasks[planID]?.value
    }

    func cancelBackup(planID: UUID) {
        activity[planID]?.phase = .cancelling
        planTasks[planID]?.cancel()
    }

    private func performBackup(plan: BackupPlan, repository: Repository) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: .backup,
            planID: plan.id,
            planName: plan.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = HookRunner(runner: runner)
        var hookContext = HookRunner.Context(
            event: .beforeBackup,
            planName: plan.name,
            planID: plan.id.uuidString,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            outcome: "starting"
        )

        do {
            let service = try service()
            let context = try await context(for: repository)

            if plan.hooks.contains(where: { $0.event == .beforeBackup && $0.isRunnable }) {
                activity[plan.id]?.phase = .runningHooks
                let result = await hooks.runHooks(plan.hooks, event: .beforeBackup, context: hookContext)
                record.hookMessages.append(
                    contentsOf: result.outcomes.filter { !$0.succeeded }.map(\.summary)
                )
                if result.shouldAbort {
                    record.outcome = .failed
                    record.failureMessage =
                        "A before-backup hook failed and is set to cancel the backup."
                    markPlanRun(plan.id, at: startedAt, succeeded: false)
                    await finish(record: &record, plan: plan, hooks: hooks, context: hookContext)
                    return
                }
            }

            // Healthchecks measures the run against this ping, so it has to go out
            // before the backup starts — but concurrently, so a slow endpoint
            // cannot delay the backup itself.
            let startEvent = NotificationEvent(
                stage: .started,
                planName: plan.name,
                repositoryName: repository.name
            )
            let channels = configuration.settings.notificationChannels
            pendingPings.append(Task.detached {
                _ = await NotificationPoster.broadcast(startEvent, to: channels)
            })
            pendingPings.removeAll { $0.isCancelled }

            activity[plan.id]?.phase = .backingUp
            let planID = plan.id
            let outcome = try await service.backup(context, plan: plan) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.activity[planID] != nil else { return }
                    self.activity[planID]?.progress = progress
                }
            }

            record.snapshotID = outcome.summary?.snapshotID
            record.filesNew = outcome.summary?.filesNew ?? 0
            record.filesChanged = outcome.summary?.filesChanged ?? 0
            record.filesUnmodified = outcome.summary?.filesUnmodified ?? 0
            record.bytesProcessed = outcome.summary?.totalBytesProcessed ?? 0
            record.dataAdded = outcome.summary?.dataAdded ?? 0
            record.itemErrorCount = outcome.itemErrors.count
            record.itemErrors.append(contentsOf: outcome.itemErrors.prefix(50))
            record.outcome = record.itemErrors.isEmpty && !outcome.completedWithErrors
                ? .succeeded
                : .completedWithErrors

            // The snapshot exists from here on. Mark the run before doing anything
            // else, so nothing that follows can make a good backup look like a
            // failed one.
            markPlanRun(plan.id, at: startedAt, succeeded: true)

            // Retention runs only after a backup that actually produced a
            // snapshot, so a failed run can never trigger a forget against stale
            // data.
            if plan.retention.isSafeToRun, record.snapshotID != nil {
                activity[plan.id]?.phase = .applyingRetention
                do {
                    _ = try await service.forget(context, plan: plan)
                } catch {
                    // `forget` needs an exclusive repository lock while `backup`
                    // only takes a shared one, so a second plan backing up to the
                    // same repository makes this fail with exit code 11. The data
                    // is already safe; degrade to a warning instead of reporting
                    // the whole backup as failed.
                    record.outcome = .completedWithErrors
                    record.itemErrors.append("Retention skipped: \(error.localizedDescription)")
                }
            }

            await refreshSnapshots(repositoryID: repository.id)
        } catch ResticError.cancelled {
            record.outcome = .cancelled
            record.failureMessage = cancellationMessage
            markPlanRun(plan.id, at: startedAt, succeeded: false)
        } catch is CancellationError {
            record.outcome = .cancelled
            record.failureMessage = cancellationMessage
            markPlanRun(plan.id, at: startedAt, succeeded: false)
        } catch {
            record.outcome = .failed
            record.failureMessage = error.localizedDescription
            markPlanRun(plan.id, at: startedAt, succeeded: false)
        }

        hookContext.snapshotID = record.snapshotID
        hookContext.filesNew = record.filesNew
        hookContext.filesChanged = record.filesChanged
        hookContext.bytesProcessed = record.bytesProcessed
        hookContext.dataAdded = record.dataAdded
        await finish(record: &record, plan: plan, hooks: hooks, context: hookContext)
    }

    /// Runs the after-backup hooks, then stores and announces the run.
    ///
    /// A cancelled run runs no hooks: the user asked for it to stop, and firing
    /// an "after failure" script at that point would be a surprise.
    private func finish(
        record: inout RunRecord,
        plan: BackupPlan,
        hooks: HookRunner,
        context: HookRunner.Context
    ) async {
        record.finishedAt = .now

        if record.outcome != .cancelled, plan.hooks.contains(where: \.isRunnable) {
            var hookContext = context
            hookContext.outcome = record.outcome.rawValue
            hookContext.errorMessage = record.failureMessage
            hookContext.durationSeconds = record.duration

            let events: [BackupHook.Event] = switch record.outcome {
            case .succeeded: [.afterSuccess, .afterAny]
            case .completedWithErrors: [.afterWarning, .afterAny]
            case .failed: [.afterFailure, .afterAny]
            case .cancelled: []
            }
            for event in events {
                let result = await hooks.runHooks(plan.hooks, event: event, context: hookContext)
                record.hookMessages.append(
                    contentsOf: result.outcomes.filter { !$0.succeeded }.map(\.summary)
                )
            }
            // A failing hook is worth surfacing, but never turns a written
            // snapshot into a failed run.
            if !record.hookMessages.isEmpty, record.outcome == .succeeded {
                record.outcome = .completedWithErrors
            }
            record.finishedAt = .now
        }

        append(record: record)
        notify(about: record)
        await broadcast(record: record, plan: plan)
    }

    /// Tells the configured webhooks and chat channels how the run went.
    ///
    /// Awaited rather than detached so that quitting straight after a failed
    /// backup still gets the alert out; a failure to deliver is shown to the user
    /// but never written into the run record, which describes the backup itself.
    private func broadcast(record: RunRecord, plan: BackupPlan?) async {
        let channels = configuration.settings.notificationChannels
        guard channels.contains(where: \.isUsable) else { return }

        let stage: NotificationEvent.Stage
        switch record.outcome {
        case .succeeded: stage = .succeeded
        case .completedWithErrors: stage = .warned
        case .failed: stage = .failed
        case .cancelled: stage = .cancelled
        }

        if let planID = plan?.id { activity[planID]?.phase = .notifying }

        let event = NotificationEvent(
            stage: stage,
            planName: record.planName,
            repositoryName: repository(id: record.repositoryID)?.name ?? "",
            operation: record.kind.rawValue.capitalized,
            snapshotID: record.snapshotID,
            errorMessage: record.failureMessage,
            // restic's own warnings only. `hookMessages` deliberately does not
            // leave the machine.
            warnings: Array(record.itemErrors.prefix(5)),
            filesNew: record.filesNew,
            bytesProcessed: record.bytesProcessed,
            dataAdded: record.dataAdded,
            duration: record.duration
        )

        let failures = await NotificationPoster.broadcast(event, to: channels)
        if !failures.isEmpty {
            banner = Banner(
                title: "Could not send \(failures.count) notification(s)",
                message: failures.joined(separator: "\n"),
                isError: true
            )
        }
    }

    /// Why a run was cancelled, for the run record: the user's own stop and the
    /// app quitting mid-run are different events worth telling apart.
    private var cancellationMessage: String {
        isShuttingDown ? "Interrupted by quitting SwiftRestic" : "Cancelled"
    }

    private func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == planID }) else { return }
        configuration.plans[index].lastRunAt = date
        if succeeded { configuration.plans[index].lastSuccessAt = date }
    }

    private func append(record: RunRecord) {
        configuration.runs.insert(record, at: 0)
        let limit = max(20, configuration.settings.maxRunHistory)
        if configuration.runs.count > limit {
            configuration.runs.removeLast(configuration.runs.count - limit)
        }
    }

    // MARK: - Snapshots

    /// Generous ceiling on one repository's `snapshots`/`stats` refresh. A
    /// black-holed SFTP host or S3 endpoint would otherwise hang the refresh —
    /// and, at launch, the scheduler that is armed once it finishes — forever.
    static let refreshTimeout: TimeInterval = 300

    func refreshAllSnapshots() async {
        // Concurrent, not serial: the scheduler is armed only after this
        // returns, so one slow or unreachable remote repository must not delay
        // another's backups. The ordering itself is kept — refreshing before the
        // scheduler starts means a due plan's retention step cannot collide with
        // our own snapshot listing.
        await withTaskGroup(of: Void.self) { group in
            for repository in configuration.repositories {
                group.addTask { await self.refreshSnapshots(repositoryID: repository.id) }
            }
        }
    }

    func refreshSnapshots(repositoryID: UUID) async {
        guard let repository = repository(id: repositoryID) else { return }
        guard !loadingSnapshots.contains(repositoryID) else { return }
        loadingSnapshots.insert(repositoryID)
        defer { loadingSnapshots.remove(repositoryID) }

        do {
            let service = try service()
            let context = try await context(for: repository)
            snapshots[repositoryID] = try await service.snapshots(context, timeout: Self.refreshTimeout)
            repositoryStats[repositoryID] = try? await service.stats(context, timeout: Self.refreshTimeout)
            repositoriesMissingPassword.remove(repositoryID)
        } catch ResticError.passwordMissing {
            // Expected before the user has entered a password; not worth a banner.
            repositoriesMissingPassword.insert(repositoryID)
            snapshots[repositoryID] = []
        } catch let ResticError.commandFailed(code, _, _) where code == 10 {
            // Repository not initialised yet.
            snapshots[repositoryID] = []
        } catch {
            snapshots[repositoryID] = []
            banner = Banner(
                title: "Could not read “\(repository.name)”",
                message: error.localizedDescription,
                isError: true
            )
        }
    }

    func snapshots(for repositoryID: UUID?, planID: UUID? = nil) -> [Snapshot] {
        guard let repositoryID, let all = snapshots[repositoryID] else { return [] }
        guard let planID else { return all }
        let tag = ResticService.planTag(planID)
        return all.filter { $0.tags.contains(tag) }
    }

    func children(
        repositoryID: UUID,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let service = try service()
        let context = try await context(for: repository)
        return try await service.listDirectory(context, snapshotID: snapshotID, path: path)
    }

    /// Searches a repository's snapshots for a path pattern.
    func findFiles(
        repositoryID: UUID,
        pattern: String,
        latestOnly: Bool
    ) async throws -> [FindResult] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let service = try service()
        let context = try await context(for: repository)
        return try await service.find(
            context,
            pattern: pattern,
            snapshotID: latestOnly ? "latest" : nil
        )
    }

    /// Compares two snapshots; `+` in the result means present only in `newer`.
    func diffSnapshots(
        repositoryID: UUID,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let service = try service()
        let context = try await context(for: repository)
        return try await service.diff(
            context,
            olderID: olderID,
            newerID: newerID,
            includeMetadata: includeMetadata
        )
    }

    // MARK: - Restore

    var isRestoring: Bool { restoreActivity != nil }

    func restore(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode,
        to destination: URL
    ) {
        beginRestore(repositoryID: repositoryID, label: node.name) { service, context in
            try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination
            ) { [weak self] progress in
                Task { @MainActor in self?.restoreActivity = progress }
            }
        } onSuccess: { [weak self] in
            self?.banner = Banner(
                title: "Restored \(node.name)",
                message: destination.path,
                isError: false
            )
        }
    }

    /// Restores every file in a snapshot, keeping the original absolute layout
    /// beneath `destination`.
    func restoreWholeSnapshot(repositoryID: UUID, snapshotID: String, to destination: URL) {
        beginRestore(repositoryID: repositoryID, label: "snapshot \(snapshotID.prefix(8))") { service, context in
            try await service.restoreWholeSnapshot(
                context,
                snapshotID: snapshotID,
                destinationDirectory: destination
            ) { [weak self] progress in
                Task { @MainActor in self?.restoreActivity = progress }
            }
        } onSuccess: { [weak self] in
            self?.banner = Banner(
                title: "Restored snapshot",
                message: destination.path,
                isError: false
            )
        }
    }

    /// Shared bookkeeping for both restore shapes: one at a time, progress
    /// published, and the outcome written to the run history either way.
    private func beginRestore(
        repositoryID: UUID,
        label: String,
        operation: @escaping @Sendable (ResticService, RepositoryContext) async throws -> ResticSummary?,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard restoreTask == nil else { return }
        restoreActivity = OperationProgress()
        restoreDescription = "Restoring \(label)"

        restoreTask = Task { [weak self] in
            guard let self else { return }
            var record = RunRecord(
                kind: .restore,
                planName: label,
                repositoryID: repositoryID
            )
            do {
                guard let repository = self.repository(id: repositoryID) else {
                    throw ResticError.repositoryMissing
                }
                let summary = try await operation(self.service(), self.context(for: repository))
                record.outcome = .succeeded
                record.bytesProcessed = summary?.bytesRestored ?? 0
                onSuccess()
            } catch ResticError.cancelled {
                record.outcome = .cancelled
                record.failureMessage = self.cancellationMessage
            } catch is CancellationError {
                record.outcome = .cancelled
                record.failureMessage = self.cancellationMessage
            } catch {
                record.outcome = .failed
                record.failureMessage = error.localizedDescription
                self.banner = Banner(
                    title: "Restore failed",
                    message: error.localizedDescription,
                    isError: true
                )
            }
            record.finishedAt = .now
            self.append(record: record)
            self.restoreActivity = nil
            self.restoreDescription = ""
            self.restoreTask = nil
        }
    }

    func cancelRestore() { restoreTask?.cancel() }

    // MARK: - Maintenance

    var runningMaintenanceRepositoryIDs: Set<UUID> { Set(maintenance.keys) }

    /// Repositories that must not be given more work right now.
    ///
    /// `prune` takes an exclusive lock and `backup` a shared one, so anything
    /// already touching a repository — a plan or an upkeep job — makes the whole
    /// repository off limits, not just that one plan.
    var busyRepositoryIDs: Set<UUID> {
        var ids = runningMaintenanceRepositoryIDs
        for planID in activity.keys {
            if let repositoryID = plan(id: planID)?.repositoryID { ids.insert(repositoryID) }
        }
        return ids
    }

    func isMaintenanceRunning(repositoryID: UUID) -> Bool { maintenance[repositoryID] != nil }

    /// Starts a `check` or `prune`. `readDataPercentOverride` lets the UI run a
    /// deeper check than the repository's own policy asks for.
    func runMaintenance(
        repositoryID: UUID,
        task: MaintenanceTask,
        readDataPercentOverride: Int? = nil
    ) {
        guard maintenanceTasks[repositoryID] == nil else { return }
        guard let repository = repository(id: repositoryID) else { return }
        guard !busyRepositoryIDs.contains(repositoryID) else {
            banner = Banner(
                title: "“\(repository.name)” is busy",
                message: "A backup or another maintenance job is already using this repository.",
                isError: false
            )
            return
        }

        maintenance[repositoryID] = MaintenanceActivity(task: task)
        maintenanceTasks[repositoryID] = Task { [weak self] in
            await self?.performMaintenance(
                repository: repository,
                task: task,
                readDataPercentOverride: readDataPercentOverride
            )
            self?.maintenanceTasks[repositoryID] = nil
            self?.maintenance[repositoryID] = nil
        }
    }

    /// Convenience for the menu, which always passes an explicit depth.
    func runMaintenance(id repositoryID: UUID, task: MaintenanceTask, readDataPercent: Int? = nil) {
        runMaintenance(repositoryID: repositoryID, task: task, readDataPercentOverride: readDataPercent)
    }

    func cancelMaintenance(repositoryID: UUID) {
        maintenanceTasks[repositoryID]?.cancel()
    }

    func waitForMaintenance(repositoryID: UUID) async {
        await maintenanceTasks[repositoryID]?.value
    }

    private func performMaintenance(
        repository: Repository,
        task: MaintenanceTask,
        readDataPercentOverride: Int?
    ) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: task == .prune ? .prune : .check,
            planName: repository.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = HookRunner(runner: runner)
        let hookContext = HookRunner.Context(
            event: .beforeMaintenance,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            maintenanceTask: task.rawValue,
            outcome: "starting"
        )

        do {
            let service = try service()
            let context = try await context(for: repository)

            if repository.hooks.contains(where: { $0.event == .beforeMaintenance && $0.isRunnable }) {
                let result = await hooks.runHooks(
                    repository.hooks,
                    event: .beforeMaintenance,
                    context: hookContext
                )
                record.hookMessages.append(
                    contentsOf: result.outcomes.filter { !$0.succeeded }.map(\.summary)
                )
                if result.shouldAbort {
                    record.outcome = .failed
                    record.failureMessage =
                        "A before-maintenance hook failed and is set to cancel the \(task.displayName.lowercased())."
                    // Stamped like any other failure: a hook that always says no
                    // must not have the scheduler asking again every minute.
                    stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
                    await finishMaintenance(
                        record: &record, repository: repository, hooks: hooks, context: hookContext
                    )
                    return
                }
            }

            switch task {
            case .check:
                let percent = readDataPercentOverride ?? repository.maintenance.checkReadDataPercent
                let summary = try await service.check(context, readDataSubsetPercent: percent)
                let errors = summary?.numErrors ?? 0
                record.outcome = errors == 0 ? .succeeded : .completedWithErrors
                record.detailText = errors == 0
                    ? "No errors found."
                    : "\(errors) error(s). `restic repair` can recover some damage."
                if summary?.suggestPrune == true {
                    record.detailText? += " restic suggests running prune."
                }
            case .prune:
                // Prune narrates its progress line by line; surfacing the
                // newest line is the difference between "working" and "hung"
                // across a prune that can run for hours. (Restic's lines are
                // \n-terminated when stdout is a pipe — progress lines like
                // "[0:00] 100.00%  2 / 2 packs processed" arrive as they
                // print, no \r in-place updates to split around.)
                let repositoryID = repository.id
                record.detailText = try await service.prune(context) { [weak self] line in
                    Task { @MainActor in
                        guard let self, self.maintenance[repositoryID] != nil else { return }
                        self.maintenance[repositoryID]?.lastOutput = line
                    }
                }
                record.outcome = .succeeded
            }
        } catch ResticError.cancelled {
            record.outcome = .cancelled
            record.failureMessage = cancellationMessage
        } catch is CancellationError {
            record.outcome = .cancelled
            record.failureMessage = cancellationMessage
        } catch ResticError.passwordMissing {
            // Not finished being set up. Record nothing and stamp nothing: the
            // scheduler skips this repository until a password exists, and the
            // repository screen must not claim a check happened.
            repositoriesMissingPassword.insert(repository.id)
            return
        } catch {
            record.outcome = .failed
            record.failureMessage = error.localizedDescription
        }

        // Stamp the timestamp whatever happened. Leaving it unset on failure would
        // make the scheduler retry every minute against a repository that is very
        // likely still unreachable.
        stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
        await finishMaintenance(record: &record, repository: repository, hooks: hooks, context: hookContext)
    }

    /// Runs the after-maintenance hooks, then stores and announces the run.
    ///
    /// A check that found errors counts as a failure here: that is the outcome a
    /// repository hook exists to report. A cancelled run fires no hooks.
    private func finishMaintenance(
        record: inout RunRecord,
        repository: Repository,
        hooks: HookRunner,
        context: HookRunner.Context
    ) async {
        record.finishedAt = .now
        if record.outcome != .cancelled, repository.hooks.contains(where: \.isRunnable) {
            var hookContext = context
            hookContext.outcome = record.outcome.rawValue
            hookContext.errorMessage = record.failureMessage ?? record.detailText.flatMap {
                record.outcome == .completedWithErrors ? $0 : nil
            }
            hookContext.durationSeconds = record.duration
            let events: [BackupHook.Event] = switch record.outcome {
            case .succeeded: [.afterMaintenanceSuccess, .afterAnyMaintenance]
            case .completedWithErrors, .failed: [.afterMaintenanceFailure, .afterAnyMaintenance]
            case .cancelled: []
            }
            for event in events {
                let result = await hooks.runHooks(repository.hooks, event: event, context: hookContext)
                record.hookMessages.append(
                    contentsOf: result.outcomes.filter { !$0.succeeded }.map(\.summary)
                )
            }
            record.finishedAt = .now
        }

        append(record: record)
        if record.outcome == .failed {
            banner = Banner(
                title: "\(record.kind.rawValue.capitalized) failed on “\(repository.name)”",
                message: record.failureMessage ?? "",
                isError: true
            )
        }
        await broadcast(record: record, plan: nil)
        await refreshSnapshots(repositoryID: repository.id)
    }

    private func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
        guard let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID })
        else { return }
        switch task {
        case .check: configuration.repositories[index].maintenance.lastCheckAt = date
        case .prune: configuration.repositories[index].maintenance.lastPruneAt = date
        }
    }

    func unlockRepository(id repositoryID: UUID) {
        Task { [weak self] in
            guard let self, let repository = self.repository(id: repositoryID) else { return }
            do {
                let service = try self.service()
                try await service.unlock(self.context(for: repository))
                self.banner = Banner(title: "Removed stale locks", message: repository.name, isError: false)
            } catch {
                self.banner = Banner(title: "Unlock failed", message: error.localizedDescription, isError: true)
            }
        }
    }

    /// Sends one channel a sample event so the user can confirm it is wired up.
    func sendTestNotification(_ channel: NotificationChannel) {
        Task { [weak self] in
            guard let self else { return }
            let event = NotificationEvent(
                stage: .succeeded,
                planName: "Test",
                repositoryName: "SwiftRestic",
                dataAdded: 1_234_567,
                duration: 12
            )
            guard let payload = NotificationPayload.request(for: channel, event: event) else {
                self.banner = Banner(
                    title: "That URL does not look usable",
                    message: channel.url,
                    isError: true
                )
                return
            }
            if let failure = await NotificationPoster.send(payload) {
                self.banner = Banner(
                    title: "Test failed for “\(channel.displayName)”",
                    message: failure,
                    isError: true
                )
            } else {
                self.banner = Banner(
                    title: "Test sent to “\(channel.displayName)”",
                    message: "",
                    isError: false
                )
            }
        }
    }

    // MARK: - Console

    /// Runs an arbitrary restic command against a repository and returns what it
    /// printed.
    ///
    /// No `--json` is added: the console exists to show restic's own output, and
    /// the human-readable form is what the user came for.
    func runConsoleCommand(repositoryID: UUID, arguments: [String]) async -> String {
        guard let repository = repository(id: repositoryID) else {
            return "No such repository."
        }
        do {
            let service = try service()
            let context = try await context(for: repository)
            let result = try await service.runRaw(context, arguments: arguments)
            return result.isEmpty ? "(no output)" : result
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Scheduling

    private func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.runDuePlans()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func runDuePlans() {
        if configuration.settings.pauseOnBattery, PowerState.isOnBattery { return }

        // Upkeep is considered first: a due prune should not be starved by a
        // backup, which will simply still be due on the next tick.
        // A repository with no stored password has nothing runnable; treat it as
        // busy so upkeep is skipped rather than failing on every tick.
        var busy = busyRepositoryIDs.union(repositoriesMissingPassword)
        for due in Scheduler.dueMaintenance(
            in: configuration.repositories,
            busyRepositoryIDs: busy
        ) {
            runMaintenance(repositoryID: due.repository.id, task: due.task)
            busy.insert(due.repository.id)
        }

        for plan in Scheduler.duePlans(
            in: configuration.plans,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id)),
            busyPlanIDs: runningPlanIDs,
            busyRepositoryIDs: busy
        ) {
            runBackup(planID: plan.id)
        }
    }

    var nextScheduledRun: (plan: BackupPlan, date: Date)? {
        Scheduler.nextScheduledRun(
            in: configuration.plans,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id))
        )
    }

    // MARK: - Notifications

    /// `UNUserNotificationCenter.current()` traps when the running binary is not
    /// an application bundle, which is exactly the case under a test runner.
    private static var supportsNotifications: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationPermission() async {
        guard Self.supportsNotifications else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func notify(about record: RunRecord) {
        let settings = configuration.settings
        let wantsNotification = switch record.outcome {
        case .succeeded: settings.notifyOnSuccess
        case .completedWithErrors, .failed: settings.notifyOnFailure
        case .cancelled: false
        }
        guard wantsNotification, Self.supportsNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = record.planName.isEmpty ? "SwiftRestic" : record.planName
        content.body = switch record.outcome {
        case .succeeded:
            "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration))."
        case .completedWithErrors:
            "Finished with \(max(record.itemErrorCount, record.itemErrors.count)) unreadable item(s)."
        case .failed:
            record.failureMessage ?? "The backup failed."
        case .cancelled:
            "Cancelled."
        }
        let request = UNNotificationRequest(
            identifier: record.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
