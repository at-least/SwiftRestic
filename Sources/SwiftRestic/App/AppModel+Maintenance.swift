import Foundation

extension AppModel {
    /// `prune` takes an exclusive lock and `backup` a shared one, so anything
    /// already touching a repository — a plan or an upkeep job — makes the whole
    /// repository off limits, not just that one plan.
    var busyRepositoryIDs: Set<UUID> {
        var ids = Set(maintenance.keys)
        for run in activity.values { ids.insert(run.repositoryID) }
        return ids
    }

    /// Repositories restic holds exclusively right now — a check or prune,
    /// or a plan's retention step — with the sentence a disabled Back Up Now
    /// gives. A backup's shared lock would fail at once against them (exit
    /// 11), so the verb waits instead of writing a failed run.
    var lockedRepositories: [UUID: String] {
        var reasons: [UUID: String] = [:]
        for (repositoryID, work) in maintenance {
            let name = repository(id: repositoryID).map { "“\(label(of: $0))”" } ?? "The repository"
            reasons[repositoryID] = "\(name) is running a \(work.task.displayName.lowercased()) — backups wait until it finishes."
        }
        // A backup holds the exclusive lock only in its forget step. Not by
        // phase: Stop turns the phase to `.cancelling` while the restic
        // child, still holding the lock, dies.
        for (planID, run) in activity where run.isInRetentionStep {
            guard reasons[run.repositoryID] == nil else { continue }
            let name = repository(id: run.repositoryID).map { "“\(label(of: $0))”" } ?? "The repository"
            // The live label, as the sidebar shows it; the run's own copy
            // only once Remove Plan has taken the plan.
            let planName = plan(id: planID).map { label(of: $0) } ?? run.planName
            reasons[run.repositoryID] = "\(name) is applying retention for “\(planName)” — backups wait until it finishes."
        }
        return reasons
    }

    func fix(for run: RunRecord) -> RunFix? {
        let repository = repository(id: run.repositoryID)
        return RunRecordPresentation.fix(
            for: run,
            repositoryExists: repository != nil,
            repositoryBusy: run.repositoryID.map { busyRepositoryIDs.contains($0) } ?? false,
            planExists: plan(id: run.planID) != nil,
            repositoryVolume: repository?.driveVolumeName
        )
    }

    func backupLockReason(for plan: BackupPlan) -> String? {
        plan.repositoryID.flatMap { lockedRepositories[$0] }
    }

    /// `readDataPercent` lets the UI run a deeper check than the
    /// repository's own policy asks for.
    func runMaintenance(
        repositoryID: UUID,
        task: MaintenanceTask,
        readDataPercent: Int? = nil,
        askedByUser: Bool = true
    ) {
        guard !isShuttingDown else { return }
        guard !tasks.isOccupied(.maintenance(repositoryID)) else { return }
        guard let repository = repository(id: repositoryID) else { return }
        guard !busyRepositoryIDs.contains(repositoryID) else {
            postBusyBanner(for: repository)
            return
        }

        installMaintenanceActivity(repositoryID: repositoryID, task: task, askedByUser: askedByUser)
        tasks.install(Task { [weak self] in
            if let self {
                await MaintenanceRunEngine.perform(
                    repository: repository,
                    task: task,
                    readDataPercentOverride: readDataPercent,
                    sink: self
                )
            }
            self?.unwindMaintenanceRun(repositoryID)
        }, in: .maintenance(repositoryID))
    }

    /// The maintenance mirror of `installPlanActivity`: a fresh activity
    /// carries a new run token, so a line still in flight from the previous
    /// job drops instead of writing into this one.
    func installMaintenanceActivity(repositoryID: UUID, task: MaintenanceTask, askedByUser: Bool = true) {
        maintenanceRunTokens[repositoryID] = UUID()
        maintenance[repositoryID] = MaintenanceActivity(task: task, askedByUser: askedByUser)
        reconcileSleepAssertion()
    }

    /// Every piece of per-run bookkeeping leaves together,
    /// `unwindPlanRun(_:)`'s rule, so the copies cannot drift. Call only
    /// from the job's own task: `clear` while a cancelled
    /// run is still unwinding would remove its slot, and quit's
    /// `tasks.drain()` would no longer wait for its record.
    func unwindMaintenanceRun(_ repositoryID: UUID) {
        tasks.clear(.maintenance(repositoryID))
        // The token retires with the strip, so a late hop from this job
        // drops.
        maintenanceRunTokens[repositoryID] = nil
        maintenance[repositoryID] = nil
        reconcileSleepAssertion()
    }

    func cancelMaintenance(repositoryID: UUID) {
        tasks.cancel(.maintenance(repositoryID))
    }

    func stampMaintenance(repositoryID: UUID, task: MaintenanceTask, at date: Date) {
        updateRepository(repositoryID) { repository in
            switch task {
            case .check: repository.maintenance.lastCheckAt = date
            case .prune: repository.maintenance.lastPruneAt = date
            }
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
                self.post(Banner(title: "Unlocked “\(label(of: repository))”", message: "", isError: false))
            } catch {
                self.noteAuthFailure(error, repositoryID: repositoryID)
                // The queue is global: name the repository whose locks
                // stayed, as the success banner names the one it cleaned.
                self.post(
                    Banner(
                        title: "Could not unlock “\(label(of: repository))”",
                        message: error.localizedDescription,
                        isError: true
                    )
                )
            }
        })
    }
}

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

    func markServerAway(repositoryID: UUID) {
        maintenanceAwaitingServer.insert(repositoryID)
    }

    func advanceCheckDataSlice(repositoryID: UUID) {
        guard let slices = repository(id: repositoryID)?.maintenance.checkDataSlices, slices > 0 else { return }
        updateRepository(repositoryID) { repository in
            repository.maintenance.nextCheckDataSlice = repository.maintenance.nextCheckDataSlice % slices + 1
        }
    }

    func markDriveAway(repositoryID: UUID) {
        maintenanceAwaitingDrive.insert(repositoryID)
    }

    /// A failure — a check that found errors is one where hooks are
    /// concerned — posts no banner: the repository page's Last check or Last cleanup and
    /// Activity's badge say it.
    func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
        switch record.outcome {
        case .skipped:
            // The drive away: Check or Clean Up Now is answered, as Back Up
            // Now is; a scheduled one waits in silence, Next check saying
            // for what.
            guard maintenance[repository.id]?.askedByUser == true else { break }
            post(Banner(
                title: "\(record.kind.displayName) of “\(label(of: repository))” skipped",
                message: record.detailText ?? "",
                isError: false,
                symbolName: RunRecord.Outcome.skipped.symbolName
            ))
        case .succeeded, .completedWithErrors, .failed, .cancelled:
            break
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
