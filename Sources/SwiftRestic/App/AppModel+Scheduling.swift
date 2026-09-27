import Foundation

extension AppModel {
    // MARK: - Scheduling

    func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runDuePlans()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// One scheduler tick. Awaited by the loop above, so ticks never
    /// overlap — the same no-overlap rule the debounce's flush follows.
    /// Resuming, and a pause running out, take effect here, within a minute:
    /// an extra tick started on Resume would break that rule.
    private func runDuePlans() async {
        // First, so a pause that ran out stops being shown and stops holding
        // in the same tick.
        expireLapsedPauses(now: .now)
        let onBattery = await Self.sampleOnBattery()
        if isOnBattery != onBattery { isOnBattery = onBattery }
        // Pause Backups and the battery hold everything scheduled — backups
        // and upkeep alike. Work already running is not touched, and Back Up
        // Now never comes through here.
        guard scheduleHold == nil else { return }

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

    /// The battery check is a synchronous IOKit round-trip to powerd —
    /// quick, but it is still IPC; it runs detached so the tick decides on
    /// the main actor without paying it there.
    private nonisolated static func sampleOnBattery() async -> Bool {
        #if DEBUG
        // Live checks cannot unplug the Mac. Gated on the throwaway-config
        // override, like the password seam, so a stale variable in a
        // developer's shell cannot hold a normal debug run's backups.
        let environment = ProcessInfo.processInfo.environment
        if environment["SWIFTRESTIC_CONFIG_DIR"] != nil {
            switch environment["SWIFTRESTIC_POWER_SOURCE"] {
            case "battery": return true
            case "ac": return false
            default: break
            }
        }
        #endif
        return await Task.detached(priority: .utility) { PowerState.isOnBattery }.value
    }

    /// What holds every scheduled run back right now, if anything — the one
    /// answer the tray, the Overview, Settings and the plan page show.
    var scheduleHold: ScheduleHold? {
        Scheduler.hold(
            pause: configuration.settings.schedulePause,
            pauseOnBattery: configuration.settings.pauseOnBattery,
            isOnBattery: isOnBattery,
            now: .now
        )
    }

    /// Pause Backups: holds every scheduled backup, check and prune for
    /// `length`. Backups already running finish — restic cannot suspend a
    /// backup, and a stopped one starts over — unless the user chose Pause
    /// and Stop, which stops them and keeps their slots due for when the
    /// pause ends. Maintenance, restores and console work are never stopped.
    func pauseBackups(for length: PauseLength, stoppingRunningBackups: Bool = false, now: Date = .now) {
        configuration.settings.schedulePause = SchedulePause(until: length.end(from: now))
        guard stoppingRunningBackups else { return }
        // A run the user already stopped keeps that Stop's meaning.
        for (planID, run) in activity where run.phase != .cancelling {
            pauseStoppedPlanIDs.insert(planID)
            cancelBackup(planID: planID)
        }
    }

    func resumeBackups() {
        configuration.settings.schedulePause = nil
    }

    /// Clears the pause dates that have passed. Nothing depends on it — a
    /// lapsed date already holds nothing — but the write is what redraws
    /// every surface still showing the pause. Writes only what lapsed.
    func expireLapsedPauses(now: Date) {
        if let pause = configuration.settings.schedulePause, !pause.isActive(at: now) {
            configuration.settings.schedulePause = nil
        }
        for index in configuration.plans.indices {
            if let until = configuration.plans[index].pausedUntil, until <= now {
                configuration.plans[index].pausedUntil = nil
            }
        }
    }

    /// The soonest run the scheduler will actually start: a timed hold moves
    /// every date to its end.
    var nextScheduledRun: (plan: BackupPlan, date: Date)? {
        Scheduler.nextScheduledRun(
            in: configuration.plans,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id)),
            heldUntil: scheduleHold?.resumesAt
        )
    }
}
