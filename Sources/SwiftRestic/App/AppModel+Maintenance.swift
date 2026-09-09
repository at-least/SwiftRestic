import Foundation

extension AppModel {
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
            post(Banner(
                title: "“\(repository.name)” is busy",
                message: "A backup or another maintenance job is already using this repository.",
                isError: false
            ))
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
        } catch ResticError.passwordMissing {
            // Not finished being set up. Record nothing and stamp nothing: the
            // scheduler skips this repository until a password exists, and the
            // repository screen must not claim a check happened.
            repositoriesMissingPassword.insert(repository.id)
            return
        } catch {
            record.record(error, cancellationMessage: cancellationMessage)
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
            post(Banner(
                title: "\(record.kind.rawValue.capitalized) failed on “\(repository.name)”",
                message: record.failureMessage ?? "",
                isError: true
            ))
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
                self.post(Banner(title: "Removed stale locks", message: repository.name, isError: false))
            } catch {
                self.post(Banner(title: "Unlock failed", message: error.localizedDescription, isError: true))
            }
        }
    }
}
