import Foundation

/// Decides which plans are due to run.
///
/// Deliberately pure: the wall-clock timer lives in `AppModel`, so this logic can
/// be tested by handing it a fixed `now`.
enum Scheduler {
    /// Plans that should start now, most overdue first.
    ///
    /// - Parameters:
    ///   - existingRepositoryIDs: repositories currently in the configuration. A
    ///     plan whose repository has vanished can never run — starting it would
    ///     only raise "Plan is incomplete" once a minute, forever — so it is
    ///     filtered here instead of being reported as overdue.
    ///   - busyPlanIDs: plans already running.
    ///   - busyRepositoryIDs: repositories with a backup or maintenance job in
    ///     flight. A plan targeting one is held back rather than dropped — it is
    ///     still overdue on the next tick, so nothing is silently skipped, and it
    ///     cannot collide with a `prune` holding an exclusive lock.
    static func duePlans(
        in plans: [BackupPlan],
        now: Date = .now,
        existingRepositoryIDs: Set<UUID>,
        busyPlanIDs: Set<UUID> = [],
        busyRepositoryIDs: Set<UUID> = []
    ) -> [BackupPlan] {
        plans
            .filter { plan in
                guard plan.isEnabled, plan.isConfigurationComplete else { return false }
                guard let repositoryID = plan.repositoryID,
                      existingRepositoryIDs.contains(repositoryID)
                else { return false }
                guard !busyPlanIDs.contains(plan.id) else { return false }
                if busyRepositoryIDs.contains(repositoryID) { return false }
                guard plan.schedule.frequency != .manual else { return false }
                guard let due = plan.schedule.nextRunDate(after: plan.lastRunAt, now: now) else { return false }
                return due <= now
            }
            .sorted { lhs, rhs in
                let lhsDue = lhs.schedule.nextRunDate(after: lhs.lastRunAt, now: now) ?? now
                let rhsDue = rhs.schedule.nextRunDate(after: rhs.lastRunAt, now: now) ?? now
                return lhsDue < rhsDue
            }
    }

    /// Repository upkeep that has fallen due.
    ///
    /// At most one task per repository per tick: `prune` wins when both are due,
    /// because it rewrites pack files and a `check` immediately afterwards
    /// validates what it left behind.
    static func dueMaintenance(
        in repositories: [Repository],
        now: Date = .now,
        busyRepositoryIDs: Set<UUID> = []
    ) -> [(repository: Repository, task: MaintenanceTask)] {
        repositories.compactMap { repository in
            guard !busyRepositoryIDs.contains(repository.id) else { return nil }
            guard repository.isConfigurationComplete else { return nil }
            for task in MaintenanceTask.allCases {
                guard let due = repository.maintenance.nextDate(
                    for: task,
                    addedAt: repository.createdAt
                ) else { continue }
                if due <= now { return (repository, task) }
            }
            return nil
        }
    }

    /// The soonest upcoming run across all enabled plans, for the menu bar.
    /// A plan whose repository no longer exists is never listed: counting down
    /// to a run that can never start is a lie.
    static func nextScheduledRun(
        in plans: [BackupPlan],
        now: Date = .now,
        existingRepositoryIDs: Set<UUID>
    ) -> (plan: BackupPlan, date: Date)? {
        plans
            .filter { $0.isEnabled && $0.isConfigurationComplete }
            .compactMap { plan -> (BackupPlan, Date)? in
                guard let repositoryID = plan.repositoryID,
                      existingRepositoryIDs.contains(repositoryID)
                else { return nil }
                guard let date = plan.schedule.nextRunDate(after: plan.lastRunAt, now: now) else { return nil }
                return (plan, max(date, now))
            }
            .min { $0.1 < $1.1 }
            .map { (plan: $0.0, date: $0.1) }
    }
}
