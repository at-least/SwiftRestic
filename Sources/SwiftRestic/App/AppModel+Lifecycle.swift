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
            let loaded = try await store.load()
            // Writing back what was just loaded is not a user edit, and it must
            // not become one: with `isLoaded` already true, the didSet would
            // schedule a save that committed every tolerant-decode substitution
            // before the banner naming them could be read — and burned a
            // rotation generation on every clean launch besides.
            suppressConfigurationSave = true
            configuration = loaded.configuration
            suppressConfigurationSave = false
            // A recovered load is not a clean one: the user is reading a copy,
            // and the next save replaces whatever was wrong with the live
            // file. Saying nothing would trade a file-system accident for a
            // silent one.
            if let recovered = loaded.recoveredFrom {
                post(Banner(
                    title: "Your configuration was restored from a backup copy",
                    message: "config.json could not be read; \(recovered) was loaded instead. Saving will replace both files.",
                    isError: true
                ))
            }
            if !loaded.decodeNotes.isEmpty {
                post(Banner(
                    title: "Some stored settings could not be read",
                    message: loaded.decodeNotes.prefix(3).joined(separator: " · ")
                        + (loaded.decodeNotes.count > 3 ? " · …" : ""),
                    isError: true
                ))
            }
        } catch {
            isConfigurationUnreadable = true
            post(Banner(
                title: "Could not read your configuration",
                message: error.localizedDescription
                    + " Your settings were not changed and nothing will be saved over the backup copies — fix the file and restart SwiftRestic.",
                isError: true
            ))
        }
        // Reset any activity left behind by a crash mid-backup.
        activity.removeAll()
        maintenance.removeAll()
        // Drag-restore staging from previous sessions is pure leftovers —
        // Finder finished with those drops long ago. Not awaited: a slow
        // temp directory must not hold the first screen behind the spinner.
        Task.detached { Self.sweepDragRestoreStaging() }
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
        // Slotted runs only: a start ping in flight is awaited below, never
        // aborted — its monitor must hear that the run started.
        tasks.cancelSlots()
        // A confirmed-destructive console command must not outlive the app
        // either — as a sheet it was cancelled on dismissal; quitting cancels.
        // Awaited, not merely cancelled: the console's unwind persists the
        // command history through `persistHistory`, and a command that lands
        // during the final flushSave below would race the process exit.
        console.cancelRunningCommand()
        await console.waitForCommand()
        await runner.terminateAll()

        // Wait for the cancelled runs to finish unwinding. Their `catch` blocks
        // append a run record and set `lastRunAt`, and those edits only reach disk
        // through a 400 ms debounced save that would never fire once the process
        // exits — so quitting mid-backup would silently lose the run. The drain
        // also covers the in-flight start pings: a monitor must not be left
        // thinking the backup was never attempted.
        await tasks.drain()

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
            resticVersion = (try? await service().version()) ?? ""
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
