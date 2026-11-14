import Foundation

extension AppModel {
    /// `prune` takes an exclusive lock and `backup` a shared one, so any run
    /// makes the whole repository off limits, not just its plan.
    var busyRepositoryIDs: Set<UUID> {
        var ids = Set(maintenance.keys)
        for run in activity.values { ids.insert(run.repositoryID) }
        return ids
    }

    /// Held exclusively: a backup's shared lock would fail at once (exit 11),
    /// so Back Up Now waits instead of writing a failed run.
    var lockedRepositories: [UUID: String] {
        var reasons: [UUID: String] = [:]
        for (repositoryID, work) in maintenance {
            let name = repositoryLabel(id: repositoryID).map { "“\($0)”" } ?? "The location"
            reasons[repositoryID] = "\(name) \(work.task.locationClause) — backups wait until it finishes."
        }
        // Not by phase: Stop turns it to `.cancelling` while the restic
        // child, still holding the lock, dies.
        for (planID, run) in activity where run.isInRetentionStep {
            guard reasons[run.repositoryID] == nil else { continue }
            let name = repositoryLabel(id: run.repositoryID).map { "“\($0)”" } ?? "The location"
            let planName = plan(id: planID).map { label(of: $0) } ?? run.planName
            reasons[run.repositoryID] = "\(name) is removing old backups of “\(planName)”. Backups wait until it finishes."
        }
        return reasons
    }

    func fix(for run: RunRecord) -> RunFix? {
        let repository = repository(id: run.repositoryID)
        return RunRecordPresentation.fix(
            for: run,
            repositoryExists: repository != nil,
            planExists: plan(id: run.planID) != nil,
            repositoryVolume: repository?.driveVolumeName,
            repositoryIsLocal: repository?.kind == .local
        )
    }

    func backupLockReason(for plan: BackupPlan) -> String? {
        plan.repositoryID.flatMap { lockedRepositories[$0] }
    }

    func runMaintenance(
        repositoryID: UUID,
        task: MaintenanceTask,
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
                    sink: self
                )
            }
            self?.unwindMaintenanceRun(repositoryID)
            if task == .prune { self?.rerunBackupsAfterFreeingSpace(in: repositoryID) }
        }, in: .maintenance(repositoryID))
    }

    /// A new run token, so a line still in flight from the previous job
    /// drops.
    private func installMaintenanceActivity(repositoryID: UUID, task: MaintenanceTask, askedByUser: Bool) {
        rotateRunToken(for: .maintenance(repositoryID))
        maintenance[repositoryID] = MaintenanceActivity(task: task, askedByUser: askedByUser)
        reconcileSleepAssertion()
    }

    /// Call only from the job's own task: `clear` while a cancelled run is
    /// still unwinding would remove its slot, and quit's `tasks.drain()`
    /// would no longer wait for its record.
    private func unwindMaintenanceRun(_ repositoryID: UUID) {
        tasks.clear(.maintenance(repositoryID))
        retireRunToken(for: .maintenance(repositoryID))
        maintenance[repositoryID] = nil
        reconcileSleepAssertion()
        startQueuedBackups()
    }

    private func postBusyBanner(for repository: Repository) {
        post(Banner(
            title: "“\(label(of: repository))” is busy",
            message: "A backup or other work is already using this location.",
            level: .notice
        ))
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
}

extension AppModel: MaintenanceRunEngine.Sink {
    func markPasswordMissing(repositoryID: UUID) {
        repositoriesMissingPassword.insert(repositoryID)
    }

    func markServerAway(repositoryID: UUID) {
        maintenanceAwaitingServer.insert(repositoryID)
    }

    func advanceCheckDataSlice(repositoryID: UUID) {
        updateRepository(repositoryID) { repository in
            repository.maintenance.nextCheckDataSlice = repository.maintenance.nextCheckDataSlice % MaintenancePolicy.rotatingSlices + 1
        }
    }

    func markDriveAway(repositoryID: UUID) {
        maintenanceAwaitingDrive.insert(repositoryID)
    }

    /// A failure posts no banner: the repository page and Activity's badge
    /// say it.
    func deliver(record: RunRecord, repository: Repository, transcript: RunTranscript.Contents) async {
        var record = record
        await seal(&record, transcript: transcript)
        append(record: record)
        switch record.outcome {
        case .skipped:
            // Answered only when asked for; a scheduled one waits silently.
            guard let activity = maintenance[repository.id], activity.askedByUser else { break }
            post(Banner(
                title: activity.task.skippedTitle(location: label(of: repository)),
                message: record.detailText ?? "",
                level: .notice
            ))
        case .succeeded, .completedWithErrors, .failed, .cancelled:
            break
        }
    }

    /// A new task, not inheriting the caller's cancellation, which would
    /// kill the refresh mid-call. On the background lane so a quit drains it
    /// instead of orphaning restic children past `terminateAll`.
    func scheduleSnapshotRefresh(repositoryID: UUID) {
        guard !isShuttingDown else { return }
        tasks.addBackground(Task { [weak self] in
            await self?.refreshSnapshots(repositoryID: repositoryID)
        })
    }

}
