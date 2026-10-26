import AppKit
import Foundation
import Network

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

    /// One scheduler tick, awaited by the loop above so ticks never overlap
    /// (the debounced save's flush follows the same rule). Resuming, and a
    /// pause running out, take effect here, within a minute: an extra tick
    /// started on Resume would break that rule.
    func runDuePlans() async {
        // First, so a lapsed pause stops being shown and stops holding in the
        // same tick.
        expireLapsedPauses(now: .now)
        let onBattery = await Self.sampleOnBattery()
        if isOnBattery != onBattery { isOnBattery = onBattery }
        // Pause Backups and the battery hold everything scheduled — backups
        // and upkeep alike. Work already running is not touched, and Back Up
        // Now never comes through here.
        guard scheduleHold == nil else { return }

        // Without restic every run would fail at its first restic call — a
        // Failed record, a banner and a notification per slot, backups and
        // upkeep alike — for a cause the window's banner and the menu bar
        // already state.
        if isResticAvailable { startDueWork() }

        // After the guard: a hold exempts every plan from the quiet-plan
        // alert, as it holds their runs. After the starts: a plan this tick
        // just started is running, so it is not named for the stretch its
        // run is about to end — a pause lapsing, or a Mac back from a long
        // sleep, would otherwise hear of the very plan starting. A missing
        // restic starts nothing, so the alert still names what it leaves
        // unprotected.
        alertQuietPlans(now: .now)
    }

    private func startDueWork() {
        // Upkeep is considered first: a due prune should not be starved by a
        // backup, which will simply still be due on the next tick. A
        // repository with no stored password has nothing runnable; treat it
        // as busy so upkeep is skipped rather than failing on every tick.
        var busy = busyRepositoryIDs.union(repositoriesMissingPassword).union(upkeepStillAwaitingDrive())
        // A server out of reach holds its upkeep only: a backup due to it
        // still runs, and skips in seconds with its own record.
        for due in Scheduler.dueMaintenance(
            in: configuration.repositories,
            busyRepositoryIDs: busy.union(upkeepAwaitingServer)
        ) {
            runMaintenance(repositoryID: due.repository.id, task: due.task, askedByUser: false)
            busy.insert(due.repository.id)
        }

        for plan in Scheduler.duePlans(
            in: configuration.plans,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id)),
            busyPlanIDs: runningPlanIDs,
            busyRepositoryIDs: busy
        ) {
            runBackup(planID: plan.id, askedByUser: false)
        }
    }

    /// The repositories whose upkeep waits for its drive (`markDriveAway`)
    /// while the drive is still away; one whose drive is back — mounted by
    /// the user, a backup's hook or reconnect, a read — leaves the set, and
    /// its task, unstamped and so still due, starts on this tick.
    private func upkeepStillAwaitingDrive() -> Set<UUID> {
        upkeepAwaitingDrive = upkeepAwaitingDrive.filter { id in
            repository(id: id)?.isDriveAway ?? false
        }
        return upkeepAwaitingDrive
    }

    /// The battery check is a synchronous IOKit round-trip to powerd — quick,
    /// but still IPC; it runs detached so the tick decides on the main actor
    /// without paying it there.
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
    /// answer the tray, a repository's page, Settings and the plan page show.
    var scheduleHold: ScheduleHold? {
        Scheduler.hold(
            pause: configuration.settings.schedulePause,
            pauseOnBattery: configuration.settings.pauseOnBattery,
            isOnBattery: isOnBattery,
            pauseOnMeteredNetwork: configuration.settings.pauseOnMeteredNetwork,
            isOnMeteredNetwork: isOnMeteredNetwork,
            now: .now
        )
    }

    /// Watches for volumes mounting: a plan skipped because its drive was
    /// away runs again when the drive comes back, not a whole interval
    /// later.
    func startMountWatcher() {
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let volume = (notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
            MainActor.assumeIsolated {
                if let volume { self?.refreshRepositories(onVolume: volume) }
                self?.runSkippedPlansAfterMount()
            }
        }
    }

    func stopMountWatcher() {
        if let mountObserver { NSWorkspace.shared.notificationCenter.removeObserver(mountObserver) }
        mountObserver = nil
    }

    /// A volume back re-reads the listings of the local repositories on it,
    /// whose refresh had answered "not connected" — under a hold too: a
    /// listing read is read-only, and nothing else would clear the words
    /// while backups are paused.
    func refreshRepositories(onVolume volumePath: String) {
        guard !isShuttingDown, let volume = VolumePresence.volumeName(of: volumePath) else { return }
        for repository in configuration.repositories
            where repository.driveVolumeName == volume
        {
            tasks.addBackground(Task { [weak self] in
                await self?.refreshSnapshots(repositoryID: repository.id)
            })
        }
    }

    /// The mount's catch-up (`Scheduler.catchUpAfterMount`): only while
    /// nothing holds the schedule and restic is there, as for the tick.
    func runSkippedPlansAfterMount(now: Date = .now) {
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        var newest: [UUID: RunRecord.Outcome] = [:]
        var planIDs: [UUID] = []
        // Newest first.
        for run in configuration.runs where run.kind == .backup {
            if let planID = run.planID, newest[planID] == nil { newest[planID] = run.outcome }
        }
        for planID in Scheduler.catchUpAfterMount(
            plans: configuration.plans,
            newestBackupOutcome: newest,
            running: runningPlanIDs,
            sourcesExist: { Self.sourceExists($0.path) },
            repositoryReachable: { plan in
                guard let repository = configuration.repository(id: plan.repositoryID) else { return false }
                return !repository.isDriveAway
            },
            now: now
        ) {
            planIDs.append(planID)
        }
        // Two plans on one drive come back together: one at a time.
        runBackups(planIDs: planIDs, askedByUser: false)
    }

    /// Follows the network for the metered-network hold: macOS's own
    /// "expensive" (cellular and the like) and "constrained" flags on the
    /// current path, watched whether or not the setting is on, so the hold
    /// is right the moment it is switched on.
    func startNetworkMonitor() {
        #if DEBUG
        // Live checks cannot switch networks. Gated on the throwaway-config
        // override, like the power-source seam.
        let environment = ProcessInfo.processInfo.environment
        if environment["SWIFTRESTIC_CONFIG_DIR"] != nil, let network = environment["SWIFTRESTIC_NETWORK"] {
            isOnMeteredNetwork = network == "metered"
            return
        }
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            let isUp = path.status == .satisfied
            let signature = "\(isUp) " + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                if self.isOnMeteredNetwork != metered { self.isOnMeteredNetwork = metered }
                // The first path is where the app starts, not a change.
                let previous = self.networkSignature
                self.networkSignature = signature
                if let previous, previous != signature, isUp { self.networkPathChanged() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.newlix.SwiftRestic.network"))
        networkMonitor = monitor
    }

    /// The network changed and is up — another Wi-Fi, a cable, a VPN, back
    /// online — so a server out of reach may answer now: upkeep waiting for
    /// one may run, network repositories whose listing failed are read
    /// again (each probing its server first), and plans whose newest backup
    /// was skipped run again, as a mount brings back a drive's.
    func networkPathChanged() {
        guard !isShuttingDown else { return }
        upkeepAwaitingServer.removeAll()
        for repository in configuration.repositories where repository.kind != .local {
            guard case .failed = snapshotListingOutcomes[repository.id] else { continue }
            tasks.addBackground(Task { [weak self] in
                await self?.refreshSnapshots(repositoryID: repository.id)
            })
        }
        runSkippedPlansAfterMount()
    }

    /// Pause Backups: holds every scheduled backup, check and prune for
    /// `length`. Backups already running finish — restic cannot suspend a
    /// backup, and a stopped one starts over — unless the user chose Pause
    /// and Stop, which stops them and leaves their slots due for when the
    /// pause ends. Maintenance, restores and console work are never stopped.
    /// Pause and Stop drops the plans waiting for their turn too
    /// (`runBackups`).
    func pauseBackups(for length: PauseLength, stoppingRunningBackups: Bool = false, now: Date = .now) {
        configuration.settings.schedulePause = SchedulePause(until: length.end(from: now))
        guard stoppingRunningBackups else { return }
        backupQueue.removeAll()
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
    /// every surface still showing the pause.
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
