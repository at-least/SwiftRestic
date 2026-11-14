import Foundation
import Observation

/// What `followPlans` compares across a configuration write.
private struct PlanFootprint {
    let hasPlan: Bool
    let hasScheduledPlan: Bool
    let volumes: Set<String>

    init(of configuration: AppConfiguration) {
        hasPlan = !configuration.plans.isEmpty
        hasScheduledPlan = configuration.plans.contains(where: \.isScheduled)
        volumes = configuration.volumesInUse
    }
}

struct QuitConfirmation: Equatable {
    var message: String
    var interruptsWork: Bool
}

extension AppModel {
    /// One full sentence per kind of work in flight; empty when idle.
    var quitInterruptions: [String] {
        var reasons: [String] = []
        let backups = activity.count
        if backups > 0 {
            reasons.append(backups == 1 ? "A backup is running." : "\(backups) backups are running.")
        }
        for task in MaintenanceTask.allCases {
            let running = maintenance.values.filter { $0.task == task }.count
            if running > 0 { reasons.append("\(task.runningClause(count: running)).") }
        }
        if isRestoring { reasons.append("A restore is running.") }
        if console.isRunning { reasons.append("A console command is running.") }
        return reasons
    }

    /// The scheduler lives in this process, so a slot missed after quit
    /// runs only when the user opens the app again. `nil` when the app
    /// starts at login (the missed slot runs at the next login).
    ///
    /// Passes the hold, like every display of what will fire: a timed hold
    /// moves the date to its end; an open-ended one sets no date, so a due
    /// run is "waiting", not "due now".
    ///
    /// A backup in flight is not the run missed: the quit's cancel stamps
    /// its slot as run (`markPlanRun`, at the run's start).
    func quitScheduleNotice(now: Date = .now) -> String? {
        guard !startsAtLogin else { return nil }
        let hold = scheduleHold(repositoryID: nil, now: now)
        let plansAfterQuit = configuration.plans.map { plan in
            guard let run = activity[plan.id] else { return plan }
            var plan = plan
            plan.lastRunAt = max(plan.lastRunAt ?? .distantPast, run.startedAt)
            return plan
        }
        guard let next = Scheduler.nextScheduledRun(
            in: plansAfterQuit,
            now: now,
            existingRepositoryIDs: Set(configuration.repositories.map(\.id)),
            heldUntil: hold?.resumesAt
        ) else { return nil }
        // Inside the window `Format.relative` says "just now", which
        // cannot follow "is next due".
        let when = if next.date.timeIntervalSince(now) >= Format.justNowWindow {
            "is next due \(Format.relative(next.date))"
        } else if hold != nil {
            "is waiting to run"
        } else {
            "is due now"
        }
        let held = hold.map { "\($0.summary(now: now)). " } ?? ""
        // The tray headline's spelling of the same run.
        let name = RunRecordPresentation.planWithRepository(
            next.plan, plans: configuration.plans, repositories: configuration.repositories
        )
        return "\(held)\(name) \(when). Scheduled backups run only while SwiftRestic is open, "
            + "and it isn’t set to start at login — nothing will run until you open it again."
    }

    /// Work in flight asks on every path. The schedule is mentioned only
    /// when the user chose to quit (app menu, ⌘Q, tray): a logout, restart
    /// or shutdown must never wait on a schedule question, and those arrive
    /// the way the Dock's and AppleScript's quits do.
    func quitConfirmation(userChoseQuit: Bool, now: Date = .now) -> QuitConfirmation? {
        let interruptions = quitInterruptions
        var lines = interruptions
        if !interruptions.isEmpty {
            lines.append("Quitting stops the work in progress; Activity records the interruption.")
        }
        if userChoseQuit, let notice = quitScheduleNotice(now: now) {
            lines.append(notice)
        }
        guard !lines.isEmpty else { return nil }
        return QuitConfirmation(
            message: lines.joined(separator: "\n"),
            interruptsWork: !interruptions.isEmpty
        )
    }

    func bootstrap() async {
        guard !isLoaded, !isBootstrapping else { return }
        isBootstrapping = true
        let launchDate = Date.now
        // False when tolerant decoding substituted anything: one damaged
        // run drops the whole `runs` array to its default.
        var historyIsWhole = false
        // False for a backup copy, which can predate a repository added
        // since, and when anything was substituted: a repository whose `id`
        // did not read decodes with a fresh one.
        var repositoriesAreWhole = false

        do {
            let loaded = try await store.load()
            historyIsWhole = loaded.decodeNotes.isEmpty
            repositoriesAreWhole = loaded.decodeNotes.isEmpty && loaded.recoveredFrom == nil
            // Not a user edit: a save here would commit every tolerant-decode
            // substitution before the banner naming them is read, and burn a
            // rotation generation on every launch.
            var read = loaded.configuration
            for index in read.repositories.indices {
                read.repositories[index].extraEnvironment = repositoryEnvironment[read.repositories[index].id] ?? [:]
            }
            suppressConfigurationSave = true
            configuration = read
            suppressConfigurationSave = false
            // The next save replaces the live file with this copy; that must
            // not happen silently.
            if let recovered = loaded.recoveredFrom {
                post(Banner(
                    title: "Your configuration was restored from a backup copy",
                    message: "config.json couldn’t be read; \(recovered) was loaded instead. Saving will replace both files.",
                    level: .error
                ))
            }
            if !loaded.decodeNotes.isEmpty {
                post(Banner(
                    title: "Some stored settings couldn’t be read",
                    message: loaded.decodeNotes.prefix(3).joined(separator: " · ")
                        + (loaded.decodeNotes.count > 3 ? " · …" : ""),
                    level: .error
                ))
            }
        } catch {
            isConfigurationUnreadable = true
            post(Banner(
                title: "Couldn’t read your configuration",
                message: error.localizedDescription
                    + " Your settings were not changed and nothing will be saved over the backup copies — fix the file and restart SwiftRestic.",
                level: .error
            ))
        }
        isLoaded = true
        // Not awaited: a slow temp directory must not hold the first screen
        // behind the spinner.
        let staging = stagingDirectory
        tasks.addBackground(Task.detached { Self.sweepDragRestoreStaging(in: staging) })
        // Only from a history that read whole: otherwise it reads as empty
        // and would sweep every log while the records still sit in
        // config.json. Only files older than this launch: a run finishing
        // mid-sweep has written its log, not yet its record.
        if historyIsWhole {
            let logs = runLogs
            let recorded = Set(configuration.runs.map(\.id))
            tasks.addBackground(Task.detached(priority: .utility) {
                logs.sweep(keeping: recorded, olderThan: launchDate)
            })
        }
        // Only from a repository list that read whole: otherwise it can miss
        // a live repository, whose index and plans would read as orphans.
        if repositoriesAreWhole {
            let configured = Set(configuration.repositories.map(\.id))
            tasks.addBackground(Task { [indexCoordinator] in
                await indexCoordinator.sweepOrphanFiles(configured: configured)
            })
            // Before the refresh and the scheduler, which would see them.
            deletePlansWithoutRepository()
        }
        await refreshLoginItemStatus()
        await checkRestic()
        // The loading state covers configuration and the binary probe, which
        // decide the first screen; the listings below can take minutes
        // against a slow remote.
        isBootstrapping = false
        if !configuration.plans.isEmpty { requestNotificationPermission() }
        // An unreadable configuration's empty plan list would unregister an
        // app that still has schedules on disk.
        if !isConfigurationUnreadable {
            Task { await self.reconcileLoginItem() }
        }
        Task { await self.refreshFullDiskAccess() }

        startNetworkMonitor()
        startMountWatcher()
        repositoriesAwaitingLaunchListing = Set(configuration.repositories.map(\.id))
        #if DEBUG
        // A capture must photograph a deterministic state: the scheduler can
        // fire a due plan mid-capture.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE"] == nil {
            startScheduler()
        }
        #else
        startScheduler()
        #endif
        await readLocationsAtLaunch()
    }

    private func deletePlansWithoutRepository() {
        let configured = Set(configuration.repositories.map(\.id))
        for plan in configuration.plans where plan.repositoryID.map(configured.contains) != true {
            deletePlan(id: plan.id)
        }
    }

    func shutdown() async {
        // Quitting and the debug-capture path can both drive shutdown.
        guard !isShuttingDown else { return }
        isShuttingDown = true
        schedulerTask?.cancel()
        networkMonitor?.cancel()
        stopMountWatcher()
        // Slotted runs only: a start ping in flight is awaited below, never
        // aborted — its monitor must hear that the run started.
        tasks.cancelSlots()
        // Awaited, not merely cancelled: a command that may change the
        // backups schedules its refresh on the way out, and that must not
        // race the teardown below.
        console.cancelRunningCommand()
        await console.waitForCommand()
        // Before `terminateAll`: a backfill walk killed by it would read as
        // a failed snapshot and move on to the next snapshot's walk.
        await indexCoordinator.shutdown()
        await runner.terminateAll()

        // The cancelled runs' unwinds append their records, which reach disk
        // only through the flush below. The drain also awaits start pings: a
        // monitor must not think the backup was never attempted.
        await tasks.drain()

        saveTask?.cancel()
        await flushSave()
    }

    func checkRestic() async {
        let binary = ResticBinary(url: resticExecutable)
        // Checked before it becomes `binary`: a scheduler tick would run it.
        do {
            let output = try await ResticService(runner: runner, binary: binary.url).version()
            resticState = output.hasPrefix("restic ") ? .ready(binary, version: output) : .damaged
        } catch {
            resticState = .damaged
        }
    }

    var binary: ResticBinary? {
        guard case let .ready(binary, _) = resticState else { return nil }
        return binary
    }

    var isResticAvailable: Bool { binary != nil }

    var resticVersion: String {
        guard case let .ready(_, version) = resticState else { return "" }
        return version
    }

    var isResticDamaged: Bool {
        if case .damaged = resticState { return true }
        return false
    }

    func followPlans(from old: AppConfiguration) {
        guard isLoaded, !isBootstrapping, !isShuttingDown else { return }
        let before = PlanFootprint(of: old)
        let now = PlanFootprint(of: configuration)
        if now.hasPlan, !before.hasPlan { requestNotificationPermission() }
        if now.hasScheduledPlan != before.hasScheduledPlan {
            Task { await reconcileLoginItem() }
        }
        if !before.volumes.isSubset(of: now.volumes) {
            Task { await forgetNetworkShares(unusedSince: before.volumes) }
        }
    }

    /// The `SMAppService` calls are synchronous XPC round-trips, so each
    /// runs detached: a wedged daemon stalls a background task, not the
    /// main actor.
    func reconcileLoginItem() async {
        await loginItemChanges.run { [weak self] in
            await self?.performReconcileLoginItem()
        }
    }

    private func performReconcileLoginItem() async {
        let applyLoginItem = loginItemApplier
        loginItemState = await readLoginItemState()
        guard let enabled = LoginItem.change(
            hasScheduledPlan: configuration.plans.contains(where: \.isScheduled),
            state: loginItemState,
            isInstallable: installableLocationProbe()
        ) else { return }
        do {
            try await Task.detached { try applyLoginItem(enabled) }.value
        } catch {
            post(Banner(
                title: "Couldn’t change the login item",
                message: error.localizedDescription,
                level: .error
            ))
        }
        loginItemState = await readLoginItemState()
        if enabled, loginItemState == .needsApproval {
            post(Banner(
                title: "Approval needed",
                message: LoginItem.approvalNeeded,
                level: .notice
            ))
        }
    }

    func refreshLoginItemStatus() async {
        await loginItemChanges.run { [weak self] in
            guard let self else { return }
            loginItemState = await readLoginItemState()
        }
    }

    private func readLoginItemState() async -> LoginItemState {
        let read = loginItemStateReader
        return await Task.detached { read() }.value
    }
}
