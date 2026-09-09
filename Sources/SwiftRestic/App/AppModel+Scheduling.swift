import Foundation

extension AppModel {
    // MARK: - Scheduling

    func startScheduler() {
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
}
