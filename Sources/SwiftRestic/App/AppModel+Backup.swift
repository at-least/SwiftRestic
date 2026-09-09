import Foundation

extension AppModel {
    // MARK: - Running a backup

    func runBackup(planID: UUID) {
        guard planTasks[planID] == nil else { return }
        guard let plan = plan(id: planID) else { return }
        guard plan.isConfigurationComplete, let repositoryID = plan.repositoryID,
              let repository = repository(id: repositoryID)
        else {
            post(Banner(
                title: "Plan is incomplete",
                message: "Choose a repository and at least one folder to back up.",
                isError: true
            ))
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
        } catch {
            record.setOutcome(from: error, cancellationMessage: cancellationMessage)
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
        announceInApp(record: record)
        notify(about: record)
        await broadcast(record: record, plan: plan)
    }

    /// The in-app counterpart to `notify`: a finished backup lands in the
    /// banner queue so "did it work?" is answered in the pane the user is
    /// looking at, without a trip to Activity. Successes ride the queue's own
    /// auto-dismiss — success that outlives its moment reads as stale — while
    /// warnings and failures stay until dismissed, like every other problem
    /// the queue holds.
    private func announceInApp(record: RunRecord) {
        switch record.outcome {
        case .cancelled:
            // The user asked for this stop — or confirmed the quit that caused
            // it — and a banner nagging about it adds nothing.
            return
        case .succeeded:
            post(Banner(
                title: "“\(record.planName)” backed up",
                message: "Backed up \(Format.bytes(record.dataAdded)) of new data in \(Format.duration(record.duration)).",
                isError: false
            ))
        case .completedWithErrors:
            // restic's partial success: a snapshot exists, so this is not a
            // failure — but the unreadable items are exactly what the banner
            // queue exists to keep visible.
            let count = max(record.itemErrorCount, record.itemErrors.count)
            let message = record.itemErrors.first.map {
                "\($0) — \(Format.plural(count, "unreadable item")) in total."
            } ?? record.failureMessage ?? "Finished, but restic reported problems."
            post(Banner(title: "“\(record.planName)” finished with warnings", message: message, isError: true))
        case .failed:
            post(Banner(
                title: "Backup of “\(record.planName)” failed",
                message: record.failureMessage ?? "",
                isError: true
            ))
        }
    }

    private func markPlanRun(_ planID: UUID, at date: Date, succeeded: Bool) {
        guard let index = configuration.plans.firstIndex(where: { $0.id == planID }) else { return }
        configuration.plans[index].lastRunAt = date
        if succeeded { configuration.plans[index].lastSuccessAt = date }
    }
}
