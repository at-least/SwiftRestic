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
/// slots the Mac sleeps through, writes none. A pause writes none either, so
/// the alert fires through it: paused is exactly how a plan gets forgotten.
enum StaleAlert {
    private static let day: TimeInterval = 86_400

    private static let thresholdDays = 7

    /// The threshold, or one schedule interval and a day when that is
    /// longer: a weekly plan is due again exactly seven days after its last
    /// success, and a bare seven-day threshold would name it before every
    /// run.
    static func window(schedule: Schedule) -> TimeInterval {
        max(TimeInterval(thresholdDays) * day, (schedule.interval ?? 0) + day)
    }

    static func overdueLine(since lastBackupAt: Date, now: Date) -> String {
        "Not backed up for \(Format.plural(wholeDays(since: lastBackupAt, now: now), "day"))"
    }

    /// A manual plan made no promise to keep, so it is never overdue.
    static func isOverdue(_ plan: BackupPlan, lastBackupAt: Date, now: Date) -> Bool {
        plan.isScheduled && now.timeIntervalSince(lastBackupAt) > window(schedule: plan.schedule)
    }

    private static func wholeDays(since moment: Date, now: Date) -> Int {
        Int(now.timeIntervalSince(moment) / day)
    }

    /// `latestSnapshotTimes`: each plan's newest snapshot, for a plan whose
    /// history has no run of its own (`PlanStatus.lastBackupAt`); a plan with
    /// neither has no moment to count from and is not named.
    static func due(
        plans: [BackupPlan],
        latestSnapshotTimes: [UUID: Date],
        running: Set<UUID>,
        now: Date
    ) -> [StalePlanAlert] {
        plans.compactMap { plan in
            guard plan.isConfigurationComplete, !running.contains(plan.id),
                  let last = PlanStatus.lastBackupAt(plan: plan, latestSnapshotTime: latestSnapshotTimes[plan.id]),
                  plan.staleAlertedFor != last,
                  isOverdue(plan, lastBackupAt: last, now: now)
            else { return nil }
            return StalePlanAlert(planID: plan.id, lastBackupAt: last, days: wholeDays(since: last, now: now))
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
