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

        maintenance[repositoryID] = MaintenanceActivity(task: task)
        tasks.install(Task { [weak self] in
            if let self {
                await MaintenanceRunEngine.perform(
                    repository: repository,
                    task: task,
                    readDataPercentOverride: readDataPercentOverride,
                    sink: self
                )
            }
            self?.tasks.clear(.maintenance(repositoryID))
            self?.maintenance[repositoryID] = nil
        }, in: .maintenance(repositoryID))
    }

    /// Convenience for the menu, which always passes an explicit depth.
    func runMaintenance(id repositoryID: UUID, task: MaintenanceTask, readDataPercent: Int? = nil) {
        runMaintenance(repositoryID: repositoryID, task: task, readDataPercentOverride: readDataPercent)
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
        Task { [weak self] in
            guard let self, let repository = self.repository(id: repositoryID) else { return }
            do {
                let service = try self.service()
                try await service.unlock(self.context(for: repository))
                self.post(Banner(title: "Removed stale locks", message: repository.name, isError: false))
            } catch {
                self.noteAuthFailure(error, repositoryID: repositoryID)
                self.post(Banner(title: "Unlock failed", message: error.localizedDescription, isError: true))
            }
        }
    }
}

// MARK: - The maintenance engine's view of the model

extension AppModel: MaintenanceRunEngine.Sink {
    func lineReporter(repositoryID: UUID) -> @Sendable (String) -> Void {
        { [weak self] line in
            Task { @MainActor in
                guard let self, self.maintenance[repositoryID] != nil else { return }
                self.maintenance[repositoryID]?.lastOutput = line
            }
        }
    }

    func markPasswordMissing(repositoryID: UUID) {
        repositoriesMissingPassword.insert(repositoryID)
    }

    /// Stores a finished maintenance run, announces a failure — a check that
    /// found errors is a failure where hooks are concerned — and notifies
    /// the external channels.
    func deliver(record: RunRecord, repository: Repository) async {
        append(record: record)
        if record.outcome == .failed {
            post(Banner(
                title: "\(record.kind.rawValue.capitalized) failed on “\(repository.name)”",
                message: record.failureMessage ?? "",
                isError: true
            ))
        }
        await broadcast(record: record, plan: nil)
    }

}
