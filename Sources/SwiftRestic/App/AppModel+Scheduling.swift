import AppKit
import Foundation
import Network

extension AppModel {
    static let schedulerTick: Duration = .seconds(60)

    func startScheduler() {
        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            await self?.waitForLaunchListings()
            while !Task.isCancelled {
                await self?.runDuePlans()
                try? await Task.sleep(for: Self.schedulerTick)
            }
        }
    }

    /// The first tick waits, within `launchListingGrace`, so a launch with every
    /// location readable starts its due work at once. Past it, a location
    /// still being read holds only its own work, until a later tick.
    private func waitForLaunchListings() async {
        let deadline = ContinuousClock.now + launchListingGrace
        while !repositoriesAwaitingLaunchListing.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One scheduler tick, awaited by the loop above so ticks never overlap
    /// (the debounced save's flush follows the same rule). Resuming, and a
    /// pause running out, take effect here, by the next tick: an extra tick
    /// started on Resume would break that rule.
    func runDuePlans() async {
        // First, so a lapsed pause stops being shown and stops holding in the
        // same tick.
        expireLapsedPauses(now: .now)
        // A pause stops what is scheduled, backups and upkeep alike; work
        // already running is not touched, and Back Up Now never comes through
        // here. Without restic every run would fail at its first restic call
        // for a cause the window's banner and the menu bar already state.
        if scheduleHold == nil, isResticAvailable { await startDueWork() }

        // After the starts: a plan this tick just started is running, so it
        // is not named for the stretch its run is about to end. Not behind
        // the pause: nothing else says a held plan has gone quiet.
        alertQuietPlans(now: .now)
    }

    private func startDueWork() async {
        let awaitingDrive = await maintenanceStillAwaitingDrive()
        // The drive reads are awaited: a pause, a quit or restic going away
        // can land meanwhile, and holds what the tick starts as before.
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        // Upkeep is considered first: a due prune should not be starved by a
        // backup, which will simply still be due on the next tick. A
        // repository with no stored password has nothing runnable; treat it
        // as busy so upkeep is skipped rather than failing on every tick.
        var busy = busyRepositoryIDs.union(repositoriesMissingPassword).union(awaitingDrive).union(repositoriesWaitingForNetwork)
            .union(repositoriesAwaitingLaunchListing)
        // A server out of reach holds its upkeep only: a backup due to it
        // still runs, and skips in seconds with its own record.
        for due in Scheduler.dueMaintenance(
            in: configuration.repositories,
            plans: configuration.plans,
            busyRepositoryIDs: busy.union(maintenanceAwaitingServer)
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
    private func maintenanceStillAwaitingDrive() async -> Set<UUID> {
        var back: Set<UUID> = []
        for id in maintenanceAwaitingDrive {
            guard let repository = repository(id: id) else { back.insert(id); continue }
            if await !isDriveAway(repository) { back.insert(id) }
        }
        // Only what was read leaves: a repository `markDriveAway` added
        // during the reads stays.
        maintenanceAwaitingDrive.subtract(back)
        return maintenanceAwaitingDrive
    }

    /// Pause Backups, the one hold on every run. Stops the scheduler's tick.
    var scheduleHold: ScheduleHold? {
        scheduleHold(now: .now)
    }

    func scheduleHold(now: Date) -> ScheduleHold? {
        Scheduler.hold(pause: configuration.settings.schedulePause, isOnMeteredNetwork: false, repositoryUsesNetwork: false, now: now)
    }

    /// What holds this repository's scheduled runs: `scheduleHold`, or a
    /// metered network if it would use it. A disk on this Mac never waits for
    /// a network.
    func scheduleHold(repositoryID: UUID?, now: Date = .now) -> ScheduleHold? {
        let usesNetwork = repository(id: repositoryID).map { $0.usesNetwork(shares: configuration.settings.networkShares) } ?? false
        return Scheduler.hold(
            pause: configuration.settings.schedulePause,
            isOnMeteredNetwork: isOnMeteredNetwork,
            repositoryUsesNetwork: usesNetwork,
            now: now
        )
    }

    /// The tray's and Settings' words: the pause, or the metered network while
    /// it holds any plan back.
    var overallScheduleHold: ScheduleHold? {
        if let hold = scheduleHold { return hold }
        return configuration.plans.lazy.compactMap { self.scheduleHold(repositoryID: $0.repositoryID) }.first
    }

    private var repositoriesWaitingForNetwork: Set<UUID> {
        Set(configuration.repositories.map(\.id).filter { scheduleHold(repositoryID: $0) == .onMeteredNetwork })
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
                Task { [weak self] in await self?.runSkippedPlansAfterMount() }
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
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
    }

    func runSkippedPlansAfterMount() async {
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        var newest: [UUID: RunRecord.Outcome] = [:]
        // Newest first.
        for run in configuration.runs where run.kind == .backup {
            if let planID = run.planID, newest[planID] == nil { newest[planID] = run.outcome }
        }
        let planIDs = await Scheduler.catchUpAfterMount(
            plans: configuration.plans.filter { scheduleHold(repositoryID: $0.repositoryID) == nil },
            newestBackupOutcome: newest,
            running: runningPlanIDs,
            // Off the main actor, as every presence read: a stalled share
            // holds a stat for seconds.
            sourcesExist: { plan in
                let path = plan.path
                return await Task.detached { Self.sourceExists(path) }.value
            },
            repositoryReachable: { plan in
                guard let repository = self.configuration.repository(id: plan.repositoryID) else { return false }
                return await !self.isDriveAway(repository)
            }
        )
        // As at the start: the reads are awaited, and a pause or a quit can
        // land meanwhile.
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        // Two plans on one drive come back together: one at a time.
        runBackups(planIDs: planIDs, askedByUser: false)
    }

    /// Follows the network for the metered-network hold: macOS's own
    /// "expensive" (cellular and the like) and "constrained" (Low Data Mode)
    /// flags on the current path. UNVERIFIED (never tried on a real hotspot):
    /// that macOS flags one as expensive; the hold itself was checked through
    /// the debug override below.
    func startNetworkMonitor() {
        #if DEBUG
        // Live checks cannot switch networks. Gated on the throwaway-config
        // override, like the password seam, so a stale variable in a
        // developer's shell cannot hold a normal debug run's backups.
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
                if let previous, previous != signature, isUp { await self.networkPathChanged() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.newlix.SwiftRestic.network"))
        networkMonitor = monitor
    }

    func networkPathChanged() async {
        guard !isShuttingDown else { return }
        maintenanceAwaitingServer.removeAll()
        for repository in configuration.repositories where repository.kind != .local {
            guard case .failed = snapshotListingOutcomes[repository.id] else { continue }
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
        await runSkippedPlansAfterMount()
    }

    /// Pause Backups: holds every scheduled backup, check and prune for
    /// `length`. Backups already running finish: restic cannot suspend a
    /// backup, and a stopped one starts over.
    func pauseBackups(for length: PauseLength, now: Date = .now) {
        configuration.settings.schedulePause = SchedulePause(until: length.end(from: now))
    }

    func resumeBackups() {
        configuration.settings.schedulePause = nil
    }

    /// Clears a pause date that has passed. Nothing depends on it, since a
    /// lapsed date already holds nothing, but the write is what redraws every
    /// surface still showing the pause.
    func expireLapsedPauses(now: Date) {
        if let pause = configuration.settings.schedulePause, !pause.isActive(at: now) {
            configuration.settings.schedulePause = nil
        }
    }

    var nextScheduledRun: (plan: BackupPlan, date: Date)? {
        Scheduler.nextScheduledRun(
            in: configuration.plans,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id)),
            heldUntil: scheduleHold?.resumesAt
        )
    }
}
