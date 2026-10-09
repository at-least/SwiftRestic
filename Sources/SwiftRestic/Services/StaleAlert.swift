import Foundation

/// A scheduled plan gone quiet: no successful backup for longer than its
/// window, not yet named for this stretch.
struct StalePlanAlert: Equatable, Sendable {
    let planID: UUID
    /// The last backup the stretch counts from: the plan's last whole one
    /// (`BackupPlan.lastCompleteBackupAt`), else `PlanStatus.lastBackupAt`.
    /// Stored on the plan once named (`BackupPlan.staleAlertedFor`), so the
    /// plan's next whole backup — a newer moment — re-arms the alert.
    let lastBackupAt: Date
    let days: Int
    /// Whether the plan went on backing up its other folders through the
    /// stretch — its `lastSuccessAt` is newer than the moment counted from
    /// — so the alert speaks for a drive, not the plan.
    var isPartial = false
    /// The drives of the plan's folders that are away now, named as the
    /// skip names them, for a partial stretch; empty when none is away now
    /// or the stretch had no backup at all.
    var awayDrives: [String] = []
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
        let interval: TimeInterval = switch schedule.frequency {
        case .manual: 0
        case .hourly: TimeInterval(max(1, schedule.intervalHours)) * 3600
        case .daily: day
        case .weekly: 7 * day
        }
        return max(TimeInterval(thresholdDays) * day, interval + day)
    }

    /// The plans to name now. Only plans the scheduler would start by
    /// itself — switched on, not inside a timed pause, scheduled, set up —
    /// and not running: a paused or manual plan is quiet by the user's
    /// choice. `latestSnapshotTimes`: each plan's newest snapshot, for a
    /// plan whose history has no run of its own (the one derivation of a
    /// plan's last backup, `PlanStatus.lastBackupAt`); a plan with neither
    /// has no moment to count from and is not named. The stretch counts
    /// from the plan's last whole backup where it has stamped one: a run
    /// that backed up the other folders around an away drive advanced
    /// `lastSuccessAt` and not that, and the alert then speaks for the
    /// drive — `awayDrives` names the plan's drives away now.
    static func due(
        plans: [BackupPlan],
        latestSnapshotTimes: [UUID: Date],
        thresholdDays: Int,
        running: Set<UUID>,
        now: Date,
        awayDrives: (BackupPlan) -> [String] = { _ in [] }
    ) -> [StalePlanAlert] {
        guard thresholdDays > 0 else { return [] }
        return plans.compactMap { plan in
            guard plan.isScheduleActive(at: now), plan.schedule.frequency != .manual,
                  plan.isConfigurationComplete, !running.contains(plan.id),
                  let any = plan.lastSuccessAt ?? latestSnapshotTimes[plan.id]
            else { return nil }
            let last = plan.lastCompleteBackupAt ?? any
            guard plan.staleAlertedFor != last else { return nil }
            let quiet = now.timeIntervalSince(last)
            guard quiet > window(thresholdDays: thresholdDays, schedule: plan.schedule) else { return nil }
            let partial = any > last
            return StalePlanAlert(
                planID: plan.id, lastBackupAt: last, days: Int(quiet / 86400),
                isPartial: partial, awayDrives: partial ? awayDrives(plan) : []
            )
        }
    }

    /// The drives of a plan's folders that are not mounted now, each once,
    /// as the skip names them (`VolumePresence.volumeName`); a folder on
    /// the startup disk is on no drive that can be away.
    static func awayDrives(
        of plan: BackupPlan,
        isMounted: (String) -> Bool? = VolumePresence.isMounted(volumeOf:)
    ) -> [String] {
        var names: [String] = []
        for source in plan.sources {
            let path = (source as NSString).expandingTildeInPath
            guard isMounted(path) == false, let name = VolumePresence.volumeName(of: path), !names.contains(name)
            else { continue }
            names.append(name)
        }
        return names
    }

    /// The notification: the plan as every notification names it, then how
    /// long and since when. A partial stretch speaks for the drive in the
    /// skip's own words, and says the rest is fine — the plan is not quiet,
    /// one drive is; with no drive known to be away now, for the folders.
    static func notification(planTitle: String, alert: StalePlanAlert) -> (title: String, body: String) {
        let days = Format.plural(alert.days, "day")
        let last = Format.timestamp(alert.lastBackupAt)
        guard alert.isPartial else {
            return (planTitle, "No successful backup in \(days) — the last one was \(last).")
        }
        guard !alert.awayDrives.isEmpty else {
            return (planTitle, "Some folders have not been backed up in \(days) — the last backup that included every folder was \(last); the others are still backed up.")
        }
        let names = alert.awayDrives.map { "“\($0)”" }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        let (have, them) = names.count == 1 ? ("has", "it") : ("have", "them")
        return (planTitle, "\(list) \(have) not been backed up in \(days) — the last backup that included \(them) was \(last); the plan's other folders are still backed up.")
    }
}
