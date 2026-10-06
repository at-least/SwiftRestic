import Foundation

extension AppModel {
    // MARK: - Maintenance

    /// Repositories that must not be given more work right now.
    ///
    /// `prune` takes an exclusive lock and `backup` a shared one, so anything
    /// already touching a repository — a plan or an upkeep job — makes the whole
    /// repository off limits, not just that one plan.
    var busyRepositoryIDs: Set<UUID> {
        var ids = Set(maintenance.keys)
        for planID in activity.keys {
            if let repositoryID = plan(id: planID)?.repositoryID { ids.insert(repositoryID) }
        }
        return ids
    }

    /// Repositories restic holds exclusively right now — a check or prune,
    /// or a plan's retention step — with the sentence a disabled Back Up Now
    /// gives. A backup's shared lock would fail at once against them (exit
    /// 11), so the verb waits instead of writing a failed run.
    var lockedRepositories: [UUID: String] {
        var reasons: [UUID: String] = [:]
        for (repositoryID, work) in maintenance {
            let name = repository(id: repositoryID)?.name ?? "The repository"
            reasons[repositoryID] = "\(name) is running a \(work.task.displayName.lowercased()) — backups wait until it finishes."
        }
        for (planID, run) in activity where run.phase == .applyingRetention {
            guard let plan = plan(id: planID), let repositoryID = plan.repositoryID, reasons[repositoryID] == nil else { continue }
            let name = repository(id: repositoryID)?.name ?? "The repository"
            reasons[repositoryID] = "\(name) is applying retention for “\(plan.displayName)” — backups wait until it finishes."
        }
        return reasons
    }

    /// The fix a failed run offers here and now (`RunRecordPresentation.fix`).
    func fix(for run: RunRecord) -> RunFix? {
        RunRecordPresentation.fix(
            for: run,
            repositoryExists: repository(id: run.repositoryID) != nil,
            repositoryBusy: run.repositoryID.map { busyRepositoryIDs.contains($0) } ?? false
        )
    }

    /// Why `plan`'s Back Up Now waits, or nil when it may start.
    func backupLockReason(for plan: BackupPlan) -> String? {
        plan.repositoryID.flatMap { lockedRepositories[$0] }
    }

    /// Starts a `check` or `prune`. `readDataPercent` lets the UI run a
    /// deeper check than the repository's own policy asks for.
    func runMaintenance(
        repositoryID: UUID,
        task: MaintenanceTask,
        readDataPercent: Int? = nil
    ) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.maintenance(repositoryID)) else { return }
        guard let repository = repository(id: repositoryID) else { return }
        guard !busyRepositoryIDs.contains(repositoryID) else {
            post(Banner(
                title: "“\(repository.name)” is busy",
                message: "A backup or another maintenance job is already using this repository.",
                isError: false
            ))
            return
        }

        installMaintenanceActivity(repositoryID: repositoryID, task: task)
        tasks.install(Task { [weak self] in
            if let self {
                await MaintenanceRunEngine.perform(
                    repository: repository,
                    task: task,
                    readDataPercentOverride: readDataPercent,
                    sink: self
                )
            }
            self?.tasks.clear(.maintenance(repositoryID))
            // Retire the token with the strip, so a late hop from this job
            // drops — `unwindPlanRun(_:)`'s rule.
            self?.maintenanceRunTokens[repositoryID] = nil
            self?.maintenance[repositoryID] = nil
        }, in: .maintenance(repositoryID))
    }

    /// The maintenance mirror of `installPlanActivity`: a fresh activity
    /// carries a new run token, so a line still in flight from the previous
    /// job drops instead of writing into this one.
    func installMaintenanceActivity(repositoryID: UUID, task: MaintenanceTask) {
        maintenanceRunTokens[repositoryID] = UUID()
        maintenance[repositoryID] = MaintenanceActivity(task: task)
    }

    func cancelMaintenance(repositoryID: UUID) {
        tasks.cancel(.maintenance(repositoryID))
    }

    func waitForMaintenance(repositoryID: UUID) async {
        await tasks.task(in: .maintenance(repositoryID))?.value
    }

    func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
        guard let index = configuration.repositories.firstIndex(where: { $0.id == repositoryID })
        else { return }
        switch task {
        case .check: configuration.repositories[index].maintenance.lastCheckAt = date
        case .prune: configuration.repositories[index].maintenance.lastPruneAt = date
        }
    }

    func unlockRepository(id repositoryID: UUID) {
        // Registered with the census rather than left as a bare task: an
        // in-flight unlock is one of the sends quitting should drain, and an
        // unregistered one dies silently under `terminateAll` with neither
        // banner nor record.
        tasks.addBackground(Task { [weak self] in
            guard let self, let repository = self.repository(id: repositoryID) else { return }
            do {
                let service = try self.service()
                try await service.unlock(self.context(for: repository))
                self.post(Banner(title: "Removed stale locks", message: repository.name, isError: false))
            } catch {
                self.noteAuthFailure(error, repositoryID: repositoryID)
                // The queue is global: name the repository whose locks
                // stayed, as the success banner names the one it cleaned.
                self.post(
                    Banner(
                        title: "Unlock failed",
                        message: "Could not remove “\(repository.name)”'s stale locks: \(error.localizedDescription)",
                        isError: true
                    )
                )
            }
        })
    }
}

// MARK: - The maintenance engine's view of the model

extension AppModel: MaintenanceRunEngine.Sink {
    func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void {
        let token = maintenanceRunTokens[repositoryID]
        return { [weak self] line in
            Task { @MainActor in
                // The token, not the activity's existence, is the guard: a
                // line from job N must drop once job N+1 has installed its
                // own activity.
                guard let self, self.maintenanceRunTokens[repositoryID] == token else { return }
                self.maintenance[repositoryID]?.lastOutput = line
            }
        }
    }

    func markPasswordMissing(repositoryID: UUID) {
        repositoriesMissingPassword.insert(repositoryID)
    }

    /// Stores a finished maintenance run with its log, announces a failure
    /// — a check that found errors is a failure where hooks are concerned —
    /// and notifies the external channels.
    func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
        if record.outcome == .failed {
            post(Banner(
                title: "\(record.kind.displayName) failed on “\(repository.name)”",
                message: record.failureMessage ?? "",
                isError: true
            ))
        }
        await broadcast(record: record, plan: nil)
    }

    /// The maintenance engine's closing refresh, handed over uncancelled: the
    /// engine's own task is cancelled when the run was, and an inherited
    /// cancel would kill the refresh mid-call. Registered on the registry's
    /// background lane so a quit drains it rather than orphaning its restic
    /// children past `terminateAll`.
    func scheduleSnapshotRefresh(repositoryID: UUID) {
        guard !isShuttingDown else { return }
        tasks.addBackground(Task { [weak self] in
            await self?.refreshSnapshots(repositoryID: repositoryID)
        })
    }

}
