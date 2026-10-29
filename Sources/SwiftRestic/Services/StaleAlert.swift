import Foundation

/// A scheduled plan gone quiet: no successful backup for longer than its
/// window, not yet named for this stretch.
struct StalePlanAlert: Equatable, Sendable {
    let planID: UUID
    /// The last backup the stretch counts from (`PlanStatus.lastBackupAt`).
    /// Stored on the plan once named (`BackupPlan.staleAlertedFor`), so the
    /// plan's next backup — a newer moment — re-arms the alert.
    let lastBackupAt: Date
    let days: Int
}

/// The quiet-plan alert. Every other problem surface is driven by a run
/// record, and a plan whose drive is unplugged at every slot, or whose
/// slots the Mac sleeps through, writes none — so nothing would ever say
/// it. Checked on the scheduler's tick after the pause guard: Pause Backups
/// and the battery hold exempt everything, as they hold the runs.
enum StaleAlert {
    /// Settings' choices, in days; 0 is Off.
    static let choices = [0, 3, 7, 14]

    /// The threshold, or one schedule interval and a day when that is
    /// longer: a weekly plan is due again exactly seven days after its last
    /// success, and a bare seven-day threshold would name it before every
    /// run.
    static func window(thresholdDays: Int, schedule: Schedule) -> TimeInterval {
        let day: TimeInterval = 86400
        return max(TimeInterval(thresholdDays) * day, (schedule.interval ?? 0) + day)
    }

    /// The plans to name now. Only plans the scheduler would start by
    /// itself — switched on, not inside a timed pause, scheduled, set up —
    /// and not running: a paused or manual plan is quiet by the user's
    /// choice. `latestSnapshotTimes`: each plan's newest snapshot, for a
    /// plan whose history has no run of its own (the one derivation of a
    /// plan's last backup, `PlanStatus.lastBackupAt`); a plan with neither
    /// has no moment to count from and is not named.
    static func due(
        plans: [BackupPlan],
        latestSnapshotTimes: [UUID: Date],
        thresholdDays: Int,
        running: Set<UUID>,
        now: Date
    ) -> [StalePlanAlert] {
        guard thresholdDays > 0 else { return [] }
        return plans.compactMap { plan in
            guard plan.runsOnSchedule(at: now), !running.contains(plan.id),
                  let last = PlanStatus.lastBackupAt(plan: plan, latestSnapshotTime: latestSnapshotTimes[plan.id]),
                  plan.staleAlertedFor != last
            else { return nil }
            let quiet = now.timeIntervalSince(last)
            guard quiet > window(thresholdDays: thresholdDays, schedule: plan.schedule) else { return nil }
            return StalePlanAlert(planID: plan.id, lastBackupAt: last, days: Int(quiet / 86400))
        }
    }

    /// The notification: the plan as every notification names it, then how
    /// long and since when.
    static func notification(planTitle: String, alert: StalePlanAlert) -> (title: String, body: String) {
        let days = Format.plural(alert.days, "day")
        let last = Format.timestamp(alert.lastBackupAt)
        return (planTitle, "No successful backup in \(days) — the last one was \(last).")
    }
}
