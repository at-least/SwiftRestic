import Foundation

/// What is holding every scheduled run back, app-wide: the user's Pause
/// Backups, or the battery while "Pause scheduled backups on battery power"
/// is on. One value, so the tray, the Overview, Settings and the plan page
/// say the same thing the scheduler does.
enum ScheduleHold: Equatable, Sendable {
    /// Pause Backups; `until` is `nil` for Until I Resume.
    case paused(until: Date?)
    case onBattery

    /// When the hold lifts by itself, if it does — the date every held run
    /// moves to. The battery's end cannot be known ahead.
    var resumesAt: Date? {
        switch self {
        case let .paused(until): until
        case .onBattery: nil
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
        }
    }
}

/// Decides which plans are due to run.
///
/// Deliberately pure: the wall-clock timer lives in `AppModel`, so this logic can
/// be tested by handing it a fixed `now`.
enum Scheduler {
    /// The app-wide hold in force at `now`: a live pause wins, then the
    /// battery — only while the setting asks for it. A pause whose end has
    /// passed holds nothing, even before the tick clears it.
    static func hold(
        pause: SchedulePause?,
        pauseOnBattery: Bool,
        isOnBattery: Bool,
        now: Date = .now
    ) -> ScheduleHold? {
        if let pause, pause.isActive(at: now) { return .paused(until: pause.until) }
        if pauseOnBattery, isOnBattery { return .onBattery }
        return nil
    }

    /// Plans that should start now, most overdue first. A plan inside its
    /// own timed pause waits, and the slot it missed stays due for when the
    /// pause ends. (The app-wide hold is the tick's own early return.)
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

    /// A repository page's Next check or Next prune, as the scheduler will
    /// start it: the app-wide hold holds upkeep too, so a timed hold moves
    /// the date to its end and a due task under an open-ended one (Until I
    /// Resume, the battery) reads "Waiting" — the Overview's word — never
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
    /// enumeration the scheduler's pick and the dashboard's "Next runs" card
    /// both derive from, so the card cannot announce a run the scheduler
    /// will never fire (an incomplete plan used to sit on the card as due
    /// forever). Dates are raw: the card labels a past one "Due now"; only
    /// `nextScheduledRun` clamps to `now`.
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
                // The clamp probe (design-probes/06-global-pause/clamp) matched
                // this to the scheduler's first firing within one 60 s tick.
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
