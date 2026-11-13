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
    /// Why quitting right now would interrupt restic work in flight — one
    /// full clause per kind of work, empty when the process is idle. The
    /// quit confirmation words itself from here, so the rule and its
    /// phrasing stay testable at the model level.
    var quitInterruptions: [String] {
        var reasons: [String] = []
        let backups = activity.count
        if backups > 0 {
            reasons.append(backups == 1 ? "A backup is running." : "\(backups) backups are running.")
        }
        for task in MaintenanceTask.allCases {
            let running = maintenance.values.filter { $0.task == task }.count
            if running == 1 { reasons.append("\(task.runningClause).") }
            if running > 1 { reasons.append("\(running) \(task.displayName.lowercased())s are running.") }
        }
        if isRestoring { reasons.append("A restore is running.") }
        if console.isRunning { reasons.append("A console command is running.") }
        return reasons
    }

    /// The run a quit would miss, when nothing brings the app back by
    /// itself: the scheduler lives in this process, and a slot missed while
    /// it is gone runs only once the user opens it again. `nil` once the app
    /// starts at login — a missed slot is due at once then, at the next
    /// login — or when nothing is scheduled.
    ///
    /// Passes the hold, like every display of what will actually fire, and
    /// names it first, as the tray's line does: a timed hold moves the date
    /// to its end; an open-ended one sets no date, so a slot still ahead
    /// keeps its own and a due run is waiting, not due now. The hold is
    /// read at `now`, so the date and the hold agree.
    ///
    /// A backup in flight is not the run missed: the quit cancels it, and
    /// the cancel stamps its slot as run (`markPlanRun`, at the run's
    /// start), so the plan's next slot is.
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
        // cannot follow "is next due"; a run that close is due now, and the
        // next tick starts it.
        let when = if next.date.timeIntervalSince(now) >= Format.justNowWindow {
            "is next due \(Format.relative(next.date))"
        } else if hold != nil {
            "is waiting to run"
        } else {
            "is due now"
        }
        let held = hold.map { "\($0.summary(now: now)). " } ?? ""
        // The plan with its repository, the tray headline's spelling of the
        // same run.
        let name = RunRecordPresentation.planWithRepository(
            next.plan, plans: configuration.plans, repositories: configuration.repositories
        )
        return "\(held)\(name) \(when). Scheduled backups run only while SwiftRestic is open, "
            + "and it isn’t set to start at login — nothing will run until you open it again."
    }

    /// The quit alert's words, or `nil` when quitting needs no question.
    /// Work in flight asks on every path. The schedule is mentioned only
    /// when the user chose to quit — the app menu, ⌘Q, the tray: a logout,
    /// restart or shutdown must never wait on a schedule question, and
    /// those arrive the way the Dock's and AppleScript's quits do, so none
    /// of them gets it.
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
        // Whether the history in memory is the one on disk: not when no
        // generation read, and not when tolerant decoding substituted
        // anything — one damaged run drops the whole `runs` array to its
        // default.
        var historyIsWhole = false
        // Whether the repository list in memory is exactly the live file's:
        // not from a backup copy, which can predate a repository added
        // since, and with nothing substituted — a repository whose `id` did
        // not read decodes with a fresh one.
        var repositoriesAreWhole = false

        do {
            let loaded = try await store.load()
            historyIsWhole = loaded.decodeNotes.isEmpty
            repositoriesAreWhole = loaded.decodeNotes.isEmpty && loaded.recoveredFrom == nil
            // Writing back what was just loaded is not a user edit, and it must
            // not become one: the didSet would schedule a save that committed
            // every tolerant-decode substitution before the banner naming them
            // could be read — and burned a rotation generation on every clean
            // launch besides.
            var read = loaded.configuration
            for index in read.repositories.indices {
                read.repositories[index].extraEnvironment = repositoryEnvironment[read.repositories[index].id] ?? [:]
            }
            suppressConfigurationSave = true
            configuration = read
            suppressConfigurationSave = false
            // A recovered load is not a clean one: the user is reading a
            // copy, and the next save replaces whatever was wrong with the
            // live file. Saying nothing would trade a file-system accident
            // for a silent one.
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
        // Drag-restore staging and preview copies from previous sessions
        // are pure leftovers — Finder finished with those drops long ago. Not awaited: a slow
        // temp directory must not hold the first screen behind the spinner.
        let staging = stagingDirectory
        tasks.addBackground(Task.detached { Self.sweepDragRestoreStaging(in: staging) })
        // Logs whose records are gone — a crash between a log's write and
        // the save that would have kept its record, a trim the quit never
        // drained. Only from a history that read whole: an unreadable
        // configuration, or a `runs` array tolerant decoding dropped, reads
        // as an empty history that would sweep every log while the records
        // still sit in config.json for the user to fix. Only files older
        // than this launch: a run finishing mid-sweep has written its log,
        // not yet its record. On the background lane, so quitting waits for
        // it.
        if historyIsWhole {
            let logs = runLogs
            let recorded = Set(configuration.runs.map(\.id))
            tasks.addBackground(Task.detached(priority: .utility) {
                logs.sweep(keeping: recorded, olderThan: launchDate)
            })
        }
        // Index files whose repository is gone — a removal whose drop never
        // ran, a repository deleted from config.json by hand. Only from a
        // repository list that read whole: an unreadable configuration reads
        // as no repositories at all, and a recovered or substituted one can
        // miss a live repository, whose index would then read as an orphan.
        // On the background lane, so quitting waits for it.
        if repositoriesAreWhole {
            let configured = Set(configuration.repositories.map(\.id))
            tasks.addBackground(Task { [indexCoordinator] in
                await indexCoordinator.sweepOrphanFiles(configured: configured)
            })
            // Plans whose repository is gone — a removal whose plan
            // deletion never ran, or a repository deleted from config.json
            // by hand — are deleted, under the same gate and for the same
            // reason: a recovered or substituted list can miss a live
            // repository, whose plans would then read as orphans. Before
            // the refresh and the scheduler, which would otherwise see
            // them; the configuration's own save writes the deletion back.
            deletePlansWithoutRepository()
        }
        await refreshLoginItemStatus()
        await checkRestic()
        // The loading state covers configuration plus the binary probe: both
        // decide what the first real screen looks like (panes, or the
        // damaged-install banner). The snapshot refresh below can take
        // minutes against a slow remote — that must never hold the UI
        // hostage behind a spinner.
        isBootstrapping = false
        if !configuration.plans.isEmpty { requestNotificationPermission() }
        // Not from an unreadable configuration, whose empty plan list would
        // unregister an app that still has schedules on disk.
        if !isConfigurationUnreadable {
            Task { await self.reconcileLoginItem() }
        }
        // Not awaited either: the first TCC-checked open is a round trip to
        // tccd, and nothing on the first screen waits for the answer.
        Task { await self.refreshFullDiskAccess() }

        startNetworkMonitor()
        startMountWatcher()
        repositoriesAwaitingLaunchListing = Set(configuration.repositories.map(\.id))
        #if DEBUG
        // A capture run must photograph a deterministic state: a live scheduler
        // can fire a due plan mid-capture and put a progress row on screen.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE"] == nil {
            startScheduler()
        }
        #else
        startScheduler()
        #endif
        await readLocationsAtLaunch()
    }

    /// A plan belongs to its repository, and one pointing nowhere could
    /// never run again.
    private func deletePlansWithoutRepository() {
        let configured = Set(configuration.repositories.map(\.id))
        for plan in configuration.plans where plan.repositoryID.map(configured.contains) != true {
            deletePlan(id: plan.id)
        }
    }

    func shutdown() async {
        // Quitting and the debug-capture path can both drive shutdown; a
        // second concurrent pass would cancel and re-await tasks that are
        // already unwinding.
        guard !isShuttingDown else { return }
        isShuttingDown = true
        schedulerTask?.cancel()
        networkMonitor?.cancel()
        stopMountWatcher()
        // Slotted runs only: a start ping in flight is awaited below, never
        // aborted — its monitor must hear that the run started.
        tasks.cancelSlots()
        // A confirmed-destructive console command must not outlive the app:
        // quitting cancels it. Awaited, not merely cancelled: a command that
        // may change the backups schedules its refresh on the way out, and
        // that must not race the sweep below.
        console.cancelRunningCommand()
        await console.waitForCommand()
        // The index backfill before the sweep below: cancelled, its walk
        // stops as cancelled and its task ends. Killed first by
        // `terminateAll` instead, the walk would read as a failed snapshot
        // — counted against it, and followed by the next snapshot's walk.
        await indexCoordinator.shutdown()
        await runner.terminateAll()

        // Wait for the cancelled runs to finish unwinding. Their `catch` blocks
        // append a run record and set `lastRunAt`, and those edits only reach disk
        // through the debounced save, which would never fire once the process
        // exits — so quitting mid-backup would silently lose the run. The drain
        // also covers the in-flight start pings: a monitor must not be left
        // thinking the backup was never attempted.
        await tasks.drain()

        saveTask?.cancel()
        await flushSave()
    }

    func checkRestic() async {
        let binary = ResticBinary(url: resticExecutable)
        // Asked before it becomes `binary`: in between, a scheduler tick
        // would run it unchecked.
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

    /// What follows from the plans, kept in step as the configuration
    /// changes (the `configuration` didSet): the notification permission
    /// once the first plan arrives, the login item while any plan has a
    /// schedule, and a network share forgotten once nothing is on it. Not
    /// while bootstrap loads what is already on disk, nor while quitting.
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

    /// `LoginItem.change`, applied to what the daemon answers now. The
    /// `SMAppService` calls are synchronous XPC round-trips to the
    /// background-task-management daemon, so each runs detached — a wedged
    /// daemon stalls a background task, not the main actor.
    func reconcileLoginItem() async {
        await loginItemChanges.run { [weak self] in
            await self?.performReconcileLoginItem()
        }
    }

    private func performReconcileLoginItem() async {
        let readLoginItemState = loginItemStateReader
        let applyLoginItem = loginItemApplier
        loginItemState = await Task.detached { readLoginItemState() }.value
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
        loginItemState = await Task.detached { readLoginItemState() }.value
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
            let readLoginItemState = loginItemStateReader
            loginItemState = await Task.detached { readLoginItemState() }.value
        }
    }
}
