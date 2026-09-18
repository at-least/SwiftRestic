import Foundation

/// One backup run's lifecycle, extracted from `AppModel` so the sequencing —
/// hooks → start ping → backup → retention → closing refresh → record — is
/// unit-testable against a mock engine (a `ResticClient` in the test bundle)
/// instead of only through the stub-binary and real-restic suites.
///
/// The engine owns *what happens in what order*; everything observable
/// (activity phases, run stamps, banners, records, notifications) is written
/// through the sink, which `AppModel` implements. `AppModel.runBackup` and
/// friends remain the facade the views and the scheduler call — this type is
/// not reachable from outside the model layer.
@MainActor
enum BackupRunEngine {
    /// The model surface a backup run drives. `AppModel` conforms; tests
    /// record the calls instead.
    @MainActor
    protocol Sink: AnyObject {
        var cancellationMessage: String { get }
        func service() throws -> any ResticClient
        func context(for repository: Repository) async throws -> RepositoryContext
        /// Nil-anchored like the activity entry itself: a phase for a plan
        /// whose run has already unwound is dropped, never resurrected.
        func setActivityPhase(_ phase: PlanActivity.Phase, for planID: UUID)
        /// The run's progress reporter, hopping to the sink's own actor —
        /// built by the sink because only it knows its concrete isolation.
        /// (Sink-built is load-bearing: the toolchain accepts @Sendable
        /// capture of a concrete main-actor class, not of an existential or
        /// a generic parameter — compiler probes recorded with commit
        /// 6635470. A future language mode may loosen this.)
        func progressReporter(planID: UUID) -> @Sendable (OperationProgress) -> Void
        func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool)
        func noteAuthFailure(_ error: Error, repositoryID: UUID)
        /// A start ping in flight must not be lost to a quit mid-backup. The
        /// channels are read at send time, not capture time — a channel
        /// edited mid-run applies from this ping on.
        func addStartPing(_ event: NotificationEvent)
        /// The closing refresh also feeds the snapshot index — which is why
        /// it must stay after retention: the index's restic calls hold
        /// shared locks, and a forget needs the exclusive one.
        func refreshSnapshots(repositoryID: UUID) async
        /// Stores and announces a finished run: run history, banner, user
        /// notification, external channels.
        func deliver(record: RunRecord, plan: BackupPlan) async
        /// Runs the plan's shell hooks around the run.
        func makeHookRunner() -> HookRunner
    }

    static func perform(plan: BackupPlan, repository: Repository, sink: Sink) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: .backup,
            planID: plan.id,
            planName: plan.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = sink.makeHookRunner()
        var hookContext = HookRunner.Context(
            event: .beforeBackup,
            planName: plan.name,
            planID: plan.id.uuidString,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            outcome: "starting"
        )

        do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

            if plan.hooks.contains(where: { $0.event == .beforeBackup && $0.isRunnable }) {
                sink.setActivityPhase(.runningHooks, for: plan.id)
                let result = await hooks.runHooks(plan.hooks, event: .beforeBackup, context: hookContext)
                record.hookMessages.append(
                    contentsOf: result.outcomes.filter { !$0.succeeded }.map(\.summary)
                )
                if result.shouldAbort {
                    record.outcome = .failed
                    record.failureMessage =
                        "A before-backup hook failed and is set to cancel the backup."
                    sink.markPlanRun(plan.id, at: startedAt, succeeded: false)
                    await finish(record: &record, plan: plan, hooks: hooks, context: hookContext, sink: sink)
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
            sink.addStartPing(startEvent)

            sink.setActivityPhase(.backingUp, for: plan.id)
            let outcome = try await service.backup(
                context,
                plan: plan,
                onProgress: sink.progressReporter(planID: plan.id)
            )

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
            sink.markPlanRun(plan.id, at: startedAt, succeeded: true)

            // Retention runs only after a backup that actually produced a
            // snapshot, so a failed run can never trigger a forget against stale
            // data.
            if plan.retention.isSafeToRun, record.snapshotID != nil {
                sink.setActivityPhase(.applyingRetention, for: plan.id)
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

            // A cache must never delay, and never fail, the run that feeds it.
            await sink.refreshSnapshots(repositoryID: repository.id)
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage)
            sink.noteAuthFailure(error, repositoryID: repository.id)
            sink.markPlanRun(plan.id, at: startedAt, succeeded: false)
        }

        hookContext.snapshotID = record.snapshotID
        hookContext.filesNew = record.filesNew
        hookContext.filesChanged = record.filesChanged
        hookContext.bytesProcessed = record.bytesProcessed
        hookContext.dataAdded = record.dataAdded
        await finish(record: &record, plan: plan, hooks: hooks, context: hookContext, sink: sink)
    }

    /// Runs the after-backup hooks, then hands the finished run to the sink
    /// for storage and announcement.
    ///
    /// A cancelled run runs no hooks: the user asked for it to stop, and firing
    /// an "after failure" script at that point would be a surprise.
    private static func finish(
        record: inout RunRecord,
        plan: BackupPlan,
        hooks: HookRunner,
        context: HookRunner.Context,
        sink: Sink
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

        await sink.deliver(record: record, plan: plan)
    }
}

/// One repository-maintenance run's lifecycle (`check` or `prune`), extracted
/// for the same reasons as `BackupRunEngine` — the sequencing is testable
/// against a mock engine, the model remains the facade.
@MainActor
enum MaintenanceRunEngine {
    @MainActor
    protocol Sink: AnyObject {
        var cancellationMessage: String { get }
        func service() throws -> any ResticClient
        func context(for repository: Repository) async throws -> RepositoryContext
        /// Prune's live narration, hopped home by the sink itself (only it
        /// knows its concrete isolation); dropped if the run has already
        /// unwound, like the activity entry itself.
        func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void
        func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date)
        /// Not-yet-configured repositories record nothing and stamp nothing.
        func markPasswordMissing(repositoryID: UUID)
        func noteAuthFailure(_ error: Error, repositoryID: UUID)
        func deliver(record: RunRecord, repository: Repository) async
        func refreshSnapshots(repositoryID: UUID) async
        func makeHookRunner() -> HookRunner
    }

    static func perform(
        repository: Repository,
        task: MaintenanceTask,
        readDataPercentOverride: Int?,
        sink: Sink
    ) async {
        let startedAt = Date.now
        var record = RunRecord(
            kind: task == .prune ? .prune : .check,
            planName: repository.name,
            repositoryID: repository.id,
            startedAt: startedAt
        )
        let hooks = sink.makeHookRunner()
        let hookContext = HookRunner.Context(
            event: .beforeMaintenance,
            repositoryName: repository.name,
            repositoryID: repository.id.uuidString,
            maintenanceTask: task.rawValue,
            outcome: "starting"
        )

        do {
            let service = try sink.service()
            let context = try await sink.context(for: repository)

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
                    sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
                    await finish(record: &record, repository: repository, hooks: hooks, context: hookContext, sink: sink)
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
                record.detailText = try await service.prune(
                    context,
                    dryRun: false,
                    onRawLine: sink.lineReporter(repositoryID: repository.id)
                )
                record.outcome = .succeeded
            }
        } catch ResticError.passwordMissing {
            // Not finished being set up. Record nothing and stamp nothing: the
            // scheduler skips this repository until a password exists, and the
            // repository screen must not claim a check happened.
            sink.markPasswordMissing(repositoryID: repository.id)
            return
        } catch {
            record.setOutcome(from: error, cancellationMessage: sink.cancellationMessage)
            sink.noteAuthFailure(error, repositoryID: repository.id)
        }

        // Stamp the timestamp whatever happened. Leaving it unset on failure would
        // make the scheduler retry every minute against a repository that is very
        // likely still unreachable.
        sink.stampMaintenance(repositoryID: repository.id, task: task, at: startedAt)
        await finish(record: &record, repository: repository, hooks: hooks, context: hookContext, sink: sink)
    }

    /// Runs the after-maintenance hooks, then hands the finished run to the
    /// sink.
    ///
    /// A check that found errors counts as a failure here: that is the outcome
    /// a repository hook exists to report. A cancelled run fires no hooks.
    private static func finish(
        record: inout RunRecord,
        repository: Repository,
        hooks: HookRunner,
        context: HookRunner.Context,
        sink: Sink
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
            // Same rule as the backup engine: a failing hook is worth
            // surfacing, but never undoes what the run did — so a successful
            // check or prune whose hook failed reads as completed-with-errors,
            // which is what arms the problem dot and notifyOnFailure.
            if !record.hookMessages.isEmpty, record.outcome == .succeeded {
                record.outcome = .completedWithErrors
            }
            record.finishedAt = .now
        }

        await sink.deliver(record: record, repository: repository)
        await sink.refreshSnapshots(repositoryID: repository.id)
    }
}
