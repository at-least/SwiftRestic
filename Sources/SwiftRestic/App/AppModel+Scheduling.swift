import AppKit
import Foundation
import Network

extension AppModel {
    private static let schedulerTick: Duration = .seconds(60)

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

    /// Past `launchListingGrace`, a location still being read holds only its
    /// own work.
    private func waitForLaunchListings() async {
        let deadline = ContinuousClock.now + launchListingGrace
        while !repositoriesAwaitingLaunchListing.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Ticks never overlap, so Resume and a lapsed pause take effect on the
    /// next tick; starting an extra tick on Resume would break that.
    func runDuePlans() async {
        expireLapsedPauses(now: .now)
        // Without restic every run would fail for a cause the banner and
        // menu bar already state.
        if scheduleHold == nil, isResticAvailable { await startDueWork() }

        // After the starts, so a just-started plan is not named quiet. Not
        // behind the pause: nothing else says a held plan has gone quiet.
        alertQuietPlans(now: .now)
    }

    private func startDueWork() async {
        let awaitingDrive = await maintenanceStillAwaitingDrive()
        // Rechecked: a pause, quit or restic loss can land during the await.
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        // Upkeep first, so a backup (still due next tick) cannot starve a
        // prune. No stored password counts as busy, or upkeep fails every
        // tick.
        var busy = busyRepositoryIDs.union(repositoriesMissingPassword).union(awaitingDrive).union(repositoriesWaitingForNetwork)
            .union(repositoriesAwaitingLaunchListing)
        // A server out of reach holds upkeep only: a backup still runs and
        // skips with its own record.
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

    /// One whose drive is back leaves the set; its upkeep, unstamped and so
    /// still due, starts on this tick.
    private func maintenanceStillAwaitingDrive() async -> Set<UUID> {
        var back: Set<UUID> = []
        for id in maintenanceAwaitingDrive {
            guard let repository = repository(id: id) else { back.insert(id); continue }
            if await !isVolumeMissing(repository) { back.insert(id) }
        }
        // Only what was read: `markDriveAway` can add during the reads.
        maintenanceAwaitingDrive.subtract(back)
        return maintenanceAwaitingDrive
    }

    var scheduleHold: ScheduleHold? {
        Scheduler.hold(pause: configuration.settings.schedulePause, isOnMeteredNetwork: false, repositoryUsesNetwork: false)
    }

    func scheduleHold(repositoryID: UUID?, now: Date = .now) -> ScheduleHold? {
        let usesNetwork = repository(id: repositoryID).map { $0.usesNetwork(shares: configuration.settings.networkShares) } ?? false
        return Scheduler.hold(
            pause: configuration.settings.schedulePause,
            isOnMeteredNetwork: isOnMeteredNetwork,
            repositoryUsesNetwork: usesNetwork,
            now: now
        )
    }

    var overallScheduleHold: ScheduleHold? {
        if let hold = scheduleHold { return hold }
        return configuration.plans.lazy.compactMap { self.scheduleHold(repositoryID: $0.repositoryID) }.first
    }

    private var repositoriesWaitingForNetwork: Set<UUID> {
        Set(configuration.repositories.map(\.id).filter { scheduleHold(repositoryID: $0) == .onMeteredNetwork })
    }

    /// A plan skipped for an away drive runs when it mounts, not a whole
    /// interval later.
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

    /// Under a hold too: a listing is read-only, and nothing else would
    /// clear "not connected" while backups are paused.
    func refreshRepositories(onVolume volumePath: String) {
        guard !isShuttingDown, let volume = VolumePresence.volumeName(of: volumePath) else { return }
        for repository in configuration.repositories
            where repository.driveVolumeName == volume
        {
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
    }

    private var newestBackupRuns: [UUID: RunRecord] {
        var newest: [UUID: RunRecord] = [:]
        // configuration.runs is newest first.
        for run in configuration.runs where run.kind == .backup {
            if let planID = run.planID, newest[planID] == nil { newest[planID] = run }
        }
        return newest
    }

    /// After a fix (a password saved, the location found, a share's password
    /// saved). Not under a hold.
    func rerunFailedBackups(in repositoryID: UUID) {
        guard !isShuttingDown, isResticAvailable, scheduleHold(repositoryID: repositoryID) == nil else { return }
        let planIDs = Scheduler.rerunAfterFix(
            plans: plans(in: repositoryID),
            newestBackupOutcome: newestBackupRuns.mapValues(\.outcome),
            running: runningPlanIDs
        )
        runBackups(planIDs: planIDs, askedByUser: false)
    }

    /// Only for a backup that found the location full: otherwise every
    /// scheduled cleanup would retry every failure on its location.
    func rerunBackupsAfterCleanup(in repositoryID: UUID) {
        let cleanup = configuration.runs.first { $0.kind == .prune && $0.repositoryID == repositoryID }
        guard cleanup?.outcome == .succeeded else { return }
        let newest = newestBackupRuns
        let wasFull = plans(in: repositoryID).contains {
            newest[$0.id]?.outcome == .failed && newest[$0.id]?.repositoryFull == true
        }
        if wasFull { rerunFailedBackups(in: repositoryID) }
    }

    func runSkippedPlansAfterMount() async {
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        let planIDs = await Scheduler.catchUpAfterMount(
            plans: configuration.plans.filter { scheduleHold(repositoryID: $0.repositoryID) == nil },
            newestBackupOutcome: newestBackupRuns.mapValues(\.outcome),
            running: runningPlanIDs,
            // Off the main actor: a stalled share holds a stat for seconds.
            sourcesExist: { plan in
                let path = plan.path
                return await Task.detached { Self.sourceExists(path) }.value
            },
            repositoryReachable: { plan in
                guard let repository = self.configuration.repository(id: plan.repositoryID) else { return false }
                return await !self.isVolumeMissing(repository)
            }
        )
        // Rechecked: a pause or quit can land during the reads.
        guard !isShuttingDown, scheduleHold == nil, isResticAvailable else { return }
        runBackups(planIDs: planIDs, askedByUser: false)
    }

    /// UNVERIFIED (never tried on a real hotspot): that macOS flags one as
    /// expensive; the hold was checked only through the debug override.
    func startNetworkMonitor() {
        #if DEBUG
        // Gated on the throwaway-config override, so a stale variable in a
        // shell cannot hold a normal debug run's backups.
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
            guard snapshotListingOutcomes[repository.id]?.failureMessage != nil else { continue }
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
        await runSkippedPlansAfterMount()
    }

    /// Running backups finish: restic cannot suspend one, and a stopped one
    /// starts over.
    func pauseBackups(for length: PauseLength, now: Date = .now) {
        configuration.settings.schedulePause = SchedulePause(until: length.end(from: now))
    }

    func resumeBackups() {
        configuration.settings.schedulePause = nil
    }

    /// A lapsed pause already holds nothing; the write is what redraws the
    /// surfaces still showing it.
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
