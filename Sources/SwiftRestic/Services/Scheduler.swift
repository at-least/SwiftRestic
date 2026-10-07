import Foundation

/// What is holding every scheduled run back, app-wide: the user's Pause
/// Backups, or the battery while "Pause scheduled backups on battery power"
/// is on. One value, so the tray, a repository's page, Settings and the plan page
/// say the same thing the scheduler does.
enum ScheduleHold: Equatable, Sendable {
    /// Pause Backups; `until` is `nil` for Until I Resume.
    case paused(until: Date?)
    case onBattery
    /// The network macOS reports as expensive or constrained, while the
    /// setting asks to wait for another.
    case onMeteredNetwork

    /// When the hold lifts by itself, if it does — the date every held run
    /// moves to. The battery's end cannot be known ahead.
    var resumesAt: Date? {
        switch self {
        case let .paused(until): until
        case .onBattery, .onMeteredNetwork: nil
        }
    }

    func summary(now: Date = .now, calendar: Calendar = .current) -> String {
        switch self {
        case let .paused(until?):
            "Backups paused until \(Format.pauseEnd(until, now: now, calendar: calendar))"
        case .paused(until: nil):
            "Backups paused until you resume"
        case .onBattery:
            "Backups wait for power — this Mac is on battery"
        case .onMeteredNetwork:
            "Backups wait — this Mac's network is metered"
        }
    }
}

/// Decides which plans are due to run.
///
/// Pure: the wall-clock timer lives in `AppModel`, so tests hand it a fixed
/// `now`.
enum Scheduler {
    /// The plans a newly mounted volume brings back: each the scheduler
    /// would start by itself whose newest backup was skipped — its folders
    /// or its repository's drive were missing — and whose folders and
    /// repository are all here now. They run at once
    /// instead of waiting a whole interval for the next slot. (The app-wide
    /// hold is the caller's guard, as for the tick.)
    static func catchUpAfterMount(
        plans: [BackupPlan],
        newestBackupOutcome: [UUID: RunRecord.Outcome],
        running: Set<UUID>,
        sourcesExist: (BackupPlan) -> Bool,
        repositoryReachable: (BackupPlan) -> Bool,
        now: Date
    ) -> [UUID] {
        plans
            .filter {
                $0.isScheduleActive(at: now) && $0.schedule.frequency != .manual && $0.isConfigurationComplete
                    && !running.contains($0.id) && newestBackupOutcome[$0.id] == .skipped && sourcesExist($0)
                    && repositoryReachable($0)
            }
            .map(\.id)
    }

    /// The app-wide hold in force at `now`: a live pause wins, then the
    /// battery, then a metered network — each only while its setting asks
    /// for it. A pause whose end has
    /// passed holds nothing, even before the tick clears it.
    static func hold(
        pause: SchedulePause?,
        pauseOnBattery: Bool,
        isOnBattery: Bool,
        pauseOnMeteredNetwork: Bool = false,
        isOnMeteredNetwork: Bool = false,
        now: Date = .now
    ) -> ScheduleHold? {
        if let pause, pause.isActive(at: now) { return .paused(until: pause.until) }
        if pauseOnBattery, isOnBattery { return .onBattery }
        if pauseOnMeteredNetwork, isOnMeteredNetwork { return .onMeteredNetwork }
        return nil
    }

    /// Plans that should start now, most overdue first. A plan inside its
    /// own timed pause waits, and the slot it missed stays due for when the
    /// pause ends. (The app-wide hold is the tick's own early return.)
    ///
    /// - Parameters:
    ///   - existingRepositoryIDs: repositories in the configuration. A plan
    ///     whose repository has vanished can never run — starting it would
    ///     raise "Plan is incomplete" every tick, forever — so it is filtered
    ///     here instead of being reported as overdue.
    ///   - busyPlanIDs: plans already running.
    ///   - busyRepositoryIDs: repositories with a backup or maintenance job in
    ///     flight. A plan targeting one is held back rather than dropped — it
    ///     is still overdue on the next tick, so nothing is silently skipped,
    ///     and it cannot collide with a `prune` holding an exclusive lock.
    ///
    /// At most one plan per repository, the most overdue: plans due in the
    /// same tick would otherwise start together, and each backup ends with
    /// its retention `forget`, whose exclusive lock the other run then
    /// loses ("Retention skipped"). The rest are held back as a busy
    /// repository's plans are, and start on a tick after the first has run.
    static func duePlans(
        in plans: [BackupPlan],
        now: Date = .now,
        existingRepositoryIDs: Set<UUID>,
        busyPlanIDs: Set<UUID> = [],
        busyRepositoryIDs: Set<UUID> = []
    ) -> [BackupPlan] {
        var startingRepositoryIDs = Set<UUID>()
        return plans
            .filter { plan in
                guard plan.isScheduleActive(at: now), plan.isConfigurationComplete else { return false }
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
            // The first filter kept only plans with a repository.
            .filter { startingRepositoryIDs.insert($0.repositoryID!).inserted }
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

    /// A repository page's Last check or Last prune: the newest such run
    /// of the repository, how long ago it started and — when it did not
    /// succeed — how it ended ("3 days ago · failed"), since the stamp the
    /// scheduler keeps is written for every attempt. The stamp's moment
    /// alone when the history holds no run as new as it.
    static func lastMaintenanceText(
        _ task: MaintenanceTask,
        of repository: Repository,
        runs: [RunRecord],
        now: Date = .now
    ) -> String {
        let stamp = task == .check ? repository.maintenance.lastCheckAt : repository.maintenance.lastPruneAt
        guard let newest = newestMaintenanceRun(task, of: repository, runs: runs) else { return Format.ago(stamp, now: now) }
        let ago = Format.ago(newest.startedAt, now: now)
        switch newest.outcome {
        case .succeeded: return ago
        case .completedWithErrors: return "\(ago) · errors found"
        case .failed, .cancelled, .skipped: return "\(ago) · \(newest.outcome.displayName.lowercased())"
        }
    }

    /// The record of the newest check or prune, when it is the attempt the
    /// stamp marks — the run `lastMaintenanceText` words; nil when the
    /// history no longer holds it.
    static func newestMaintenanceRun(_ task: MaintenanceTask, of repository: Repository, runs: [RunRecord]) -> RunRecord? {
        let kind: RunRecord.Kind = task == .check ? .check : .prune
        let stamp = task == .check ? repository.maintenance.lastCheckAt : repository.maintenance.lastPruneAt
        let newest = runs
            .filter { $0.kind == kind && $0.repositoryID == repository.id }
            .max { $0.startedAt < $1.startedAt }
        guard let newest, newest.startedAt >= stamp ?? .distantPast else { return nil }
        return newest
    }

    /// A repository page's Next check or Next prune, as the scheduler will
    /// start it: the app-wide hold holds upkeep too, so a timed hold moves
    /// the date to its end and a due task under an open-ended one (Until I
    /// Resume, the battery) reads "Waiting", as a due plan's Next backup
    /// value does — never
    /// "Due now".
    static func nextMaintenanceText(
        _ task: MaintenanceTask,
        of repository: Repository,
        hold: ScheduleHold?,
        now: Date = .now
    ) -> String {
        guard let due = repository.maintenance.nextDate(for: task, addedAt: repository.createdAt) else {
            return "Off"
        }
        let date = max(due, hold?.resumesAt ?? .distantPast)
        guard date > now else { return hold == nil ? "Due now" : "Waiting" }
        return Format.timestamp(date)
    }

    /// Every enabled, complete plan's next run date, in plan order — the one
    /// enumeration the scheduler's pick and the plan page's Next backup
    /// value both derive from, so no surface can announce a run the
    /// scheduler will never fire. Dates are raw: the surfaces label a past
    /// one "Due now" — "Waiting" under a hold, "Running now" while its
    /// backup is in flight; only `nextScheduledRun` clamps to `now`.
    ///
    /// A pause with an end moves a date to that end, where the scheduler
    /// will pick the run up: the plan's own timed pause, and `heldUntil`,
    /// the app-wide hold's end. The later of the two wins. The enumeration
    /// stays ungated by default — a paused schedule is still a schedule, and
    /// only the displays of what will actually fire pass the hold.
    static func upcomingRuns(
        in plans: [BackupPlan],
        now: Date = .now,
        existingRepositoryIDs: Set<UUID>,
        heldUntil: Date? = nil
    ) -> [(plan: BackupPlan, date: Date)] {
        plans
            .filter { $0.isEnabled && $0.isConfigurationComplete }
            .compactMap { plan -> (BackupPlan, Date)? in
                guard let repositoryID = plan.repositoryID,
                      existingRepositoryIDs.contains(repositoryID)
                else { return nil }
                guard let date = plan.schedule.nextRunDate(after: plan.lastRunAt, now: now) else { return nil }
                // The clamp matches the scheduler's first firing within one
                // 60 s tick.
                return (plan, max(date, plan.activePauseEnd(at: now) ?? .distantPast, heldUntil ?? .distantPast))
            }
    }

    /// The soonest upcoming run across all enabled plans, for the menu bar.
    /// A plan whose repository no longer exists is never listed: counting down
    /// to a run that can never start is a lie.
    static func nextScheduledRun(
        in plans: [BackupPlan],
        now: Date = .now,
        existingRepositoryIDs: Set<UUID>,
        heldUntil: Date? = nil
    ) -> (plan: BackupPlan, date: Date)? {
        upcomingRuns(in: plans, now: now, existingRepositoryIDs: existingRepositoryIDs, heldUntil: heldUntil)
            .map { (plan: $0.plan, date: max($0.date, now)) }
            .min { $0.1 < $1.1 }
    }
}
