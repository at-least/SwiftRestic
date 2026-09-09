import Foundation

extension AppModel {
    // MARK: - Lifecycle

    /// Why quitting right now would interrupt restic work in flight — one
    /// full clause per kind of work, empty when the process is idle. The quit
    /// confirmation is worded from here so the rule and its phrasing stay
    /// testable at the model level instead of living inside the alert.
    var quitInterruptions: [String] {
        var reasons: [String] = []
        let backups = activity.count
        if backups > 0 {
            reasons.append(backups == 1 ? "A backup is running" : "\(backups) backups are running")
        }
        if !maintenance.isEmpty { reasons.append("Repository maintenance is running") }
        if isRestoring { reasons.append("A restore is running") }
        if console.isRunning { reasons.append("A restic console command is running") }
        return reasons
    }

    func bootstrap() async {
        guard !isLoaded else { return }
        isLoaded = true
        isBootstrapping = true

        do {
            configuration = try await store.load()
        } catch {
            post(Banner(
                title: "Could not read your configuration",
                message: error.localizedDescription,
                isError: true
            ))
        }
        // Reset any activity left behind by a crash mid-backup.
        activity.removeAll()
        maintenance.removeAll()
        startsAtLogin = LoginItem.isEnabled
        await resolveBinary()
        // The loading state covers configuration plus the binary probe: both
        // decide what the first real screen looks like (panes, or the
        // restic-is-missing banner). The snapshot refresh below can take
        // minutes against a slow remote — that must never hold the UI
        // hostage behind a spinner.
        isBootstrapping = false
        // Not awaited: `requestAuthorization` suspends until the user answers the
        // system prompt, and nothing below may wait on that — the scheduler has to
        // start whether or not notifications are ever allowed.
        Task { await self.requestNotificationPermission() }

        // Read the repositories before arming the scheduler. `snapshots`/`stats`
        // hold a shared repository lock while `forget` needs an exclusive one, so
        // starting the scheduler first makes the app race itself on launch: a due
        // plan's retention step fails against our own refresh.
        await refreshAllSnapshots()
        #if DEBUG
        // A capture run must photograph a deterministic state: a live scheduler
        // can fire a due plan mid-capture and put a progress card on screen.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE"] == nil {
            startScheduler()
        }
        #else
        startScheduler()
        #endif
    }

    func shutdown() async {
        // Quitting and the debug-capture path can both drive shutdown; a
        // second concurrent pass would cancel and re-await tasks that are
        // already unwinding.
        guard !isShuttingDown else { return }
        isShuttingDown = true
        schedulerTask?.cancel()
        let pending = Array(planTasks.values) + Array(maintenanceTasks.values)
        for task in pending { task.cancel() }
        restoreTask?.cancel()
        // A confirmed-destructive console command must not outlive the app
        // either — as a sheet it was cancelled on dismissal; quitting cancels.
        console.cancelRunningCommand()
        await runner.terminateAll()

        // Wait for the cancelled runs to finish unwinding. Their `catch` blocks
        // append a run record and set `lastRunAt`, and those edits only reach disk
        // through a 400 ms debounced save that would never fire once the process
        // exits — so quitting mid-backup would silently lose the run.
        for task in pending { await task.value }
        if let restoreTask { await restoreTask.value }
        // A start ping that never lands would leave a monitor thinking the backup
        // was never attempted rather than that it was interrupted.
        for ping in pendingPings { await ping.value }
        pendingPings.removeAll()

        saveTask?.cancel()
        await flushSave()
    }

    /// Finds the restic binary and reads its version, or records why it could not.
    func resolveBinary() async {
        do {
            let located = try ResticBinary.locate(
                userOverride: configuration.settings.resticPathOverride
            )
            binary = located
            binaryProblem = nil
            let service = ResticService(runner: runner, binary: located.url)
            resticVersion = (try? await service.version()) ?? ""
        } catch {
            binary = nil
            resticVersion = ""
            binaryProblem = error.localizedDescription
        }
    }

    var isResticAvailable: Bool { binary != nil }

    /// Registers or removes the login item, reporting whatever macOS says.
    func setStartsAtLogin(_ enabled: Bool) {
        if enabled, !LoginItem.isInInstallableLocation {
            post(Banner(
                title: "Cannot start at login from here",
                message: LoginItem.notInstalledMessage,
                isError: true
            ))
            startsAtLogin = LoginItem.isEnabled
            return
        }
        do {
            try LoginItem.setEnabled(enabled)
            startsAtLogin = LoginItem.isEnabled
            if enabled, LoginItem.needsApproval {
                post(Banner(
                    title: "Approval needed",
                    message: LoginItem.statusDescription,
                    isError: false
                ))
            }
        } catch {
            startsAtLogin = LoginItem.isEnabled
            post(Banner(
                title: "Could not change the login item",
                message: error.localizedDescription,
                isError: true
            ))
        }
    }

    func refreshLoginItemStatus() { startsAtLogin = LoginItem.isEnabled }

    var resticPath: String { binary?.url.path ?? "" }
}
