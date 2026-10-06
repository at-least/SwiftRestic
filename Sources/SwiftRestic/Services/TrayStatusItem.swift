import AppKit
import Carbon
import Foundation
import Observation

/// The tray, as a first-party AppKit status item.
///
/// Not SwiftUI's `MenuBarExtra`: a `.menu`-style label updates its image only
/// through a `TimelineView`, and any `TimelineView` in its structure — even
/// one in a branch that is not rendered — pegs the main thread at 100%
/// forever in a SwiftUI-internal requestUpdate → setImage loop, while
/// label-side state, timers, observed writes and identity changes never
/// reach the button. `NSStatusItem` has no such trade: the image is set
/// directly, the menu is rebuilt on open, nothing spins.
///
/// Faces, lines and pulse math all stay in `MenuBarStatus`/`MenuBarLogo`,
/// the pure, tested core this controller merely renders.
@MainActor
final class TrayStatusItem: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let router: AppRouter
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?

    init(model: AppModel, router: AppRouter) {
        self.model = model
        self.router = router
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "SwiftResticTray"
        super.init()
        let menu = NSMenu()
        // The status lines are `isEnabled = false` with no action, and the
        // plan rows carry their own running/complete state — AppKit's
        // auto-enabling would re-enable all of them and lie.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        // The badged faces are non-template bitmaps keyed on the bar's
        // appearance, and the observation loop below watches model state
        // only — an appearance flip with no model change would leave
        // black-ink art on a dark bar until something else happened.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Face only, not `refresh()`: a full refresh here would install a
            // second observation registration beside the live one, and each
            // theme flip would stack another.
            Task { @MainActor in self?.reapplyFace() }
        }
        refresh()
    }

    // MARK: - Faces

    /// The model state `iconState` reads, so `refresh` and `reapplyFace` keep
    /// the same six arguments by construction.
    private func currentState() -> MenuBarStatus.IconState {
        MenuBarStatus.iconState(
            activity: model.activity,
            maintenance: model.maintenance,
            isRestoring: model.isRestoring,
            isConsoleRunning: model.console.isRunning,
            hasNoRepositories: model.configuration.repositories.isEmpty,
            runs: model.configuration.runs
        )
    }

    /// The observed inputs are exactly the ones `iconState` and the hold
    /// read — reading more would re-fire this loop on every run-record
    /// append. The hold's pause and battery setting live in the
    /// configuration, observed here as a whole; the battery reading is
    /// written only when it changes; a pause running out is cleared by the
    /// scheduler's tick, and that write is what brings the face back.
    private func refresh() {
        let state = currentState()
        statusItem.isVisible = model.configuration.settings.showMenuBarExtra
        applyFace(for: state, hold: model.scheduleHold)
        armPulse(for: state)

        withObservationTracking {
            _ = model.activity
            _ = model.maintenance
            _ = model.restoreActivity
            _ = model.console.isRunning
            _ = model.configuration.repositories.isEmpty
            _ = model.configuration.runs.isEmpty
            _ = model.configuration.settings.showMenuBarExtra
            _ = model.isOnBattery
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-renders the face for the current state without touching the
    /// observation registration — the theme-changed path's entry point.
    private func reapplyFace() {
        applyFace(for: currentState(), hold: model.scheduleHold)
    }

    private func applyFace(for state: MenuBarStatus.IconState, hold: ScheduleHold?) {
        let button = statusItem.button
        switch MenuBarStatus.glyph(for: state) {
        case .logo:
            button?.image = MenuBarLogo.image()
        case .badgedLogo:
            // The baked badge variants are keyed on the *item's* appearance,
            // which follows the menu bar and can differ from the app's.
            if let button {
                button.image = MenuBarLogo.badgedImage(for: button.effectiveAppearance)
            }
        case .animatedLogo:
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button?.image = MenuBarLogo.stillRunningImage
            } else {
                button?.image = MenuBarLogo.image(phase: MenuBarLogo.phase(at: .now))
            }
        }
        // The held face: the same glyph, dimmed — AppKit's own "off but
        // still functional" look for a status item — so a problem badge
        // stays readable under it. The words go to VoiceOver.
        button?.appearsDisabled = MenuBarStatus.appearsHeld(state: state, hold: hold)
        button?.setAccessibilityLabel(MenuBarStatus.accessibilityDescription(for: state, hold: hold))
    }

    /// The pulse timer lives only while the running face is up, and checks
    /// nothing itself — `refresh` creates and destroys it with the state.
    private func armPulse(for state: MenuBarStatus.IconState) {
        let shouldPulse = state == .running && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldPulse, pulseTimer == nil {
            let timer = Timer(timeInterval: MenuBarLogo.frameInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let button = self.statusItem.button else { return }
                    let phase = MenuBarLogo.phase(at: .now)
                    button.image = MenuBarLogo.image(phase: phase)
                }
            }
            timer.tolerance = MenuBarLogo.frameInterval / 6
            // `.common`, not the default mode: the pulse must keep stepping
            // while the menu itself is open in the tracking run-loop mode.
            RunLoop.main.add(timer, forMode: .common)
            pulseTimer = timer
        } else if !shouldPulse, let pulseTimer {
            pulseTimer.invalidate()
            self.pulseTimer = nil
        }
    }

    // MARK: - Menu

    /// Rebuilt on every open, so the lines are always the current state —
    /// no background menu maintenance at all.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hasNoRepositories = model.configuration.repositories.isEmpty
        let hold = model.scheduleHold
        // While backups are held, that nothing is being backed up is the
        // news, so the hold leads — above the problem line.
        if let hold {
            menu.addItem(disabledItem(hold.summary()))
        }
        // The failure line leads, unless the `?` face summoned the menu and
        // an old failure from a since-removed repository would talk over the
        // setup question — the same yield MenuBarStatus defines. The subject
        // names the repository, so a failure from one repository cannot read
        // as another's.
        if let problem = MenuBarStatus.problemLine(
            runs: model.configuration.runs,
            hasNoRepositories: hasNoRepositories,
            plans: model.configuration.plans,
            repositories: model.configuration.repositories
        ) {
            menu.addItem(disabledItem(problem))
        }
        var lines = MenuBarStatus.runningLines(
            plans: model.configuration.plans,
            repositories: model.configuration.repositories,
            activity: model.activity,
            progress: model.planProgress
        )
            + MenuBarStatus.maintenanceLines(
                repositories: model.configuration.repositories,
                maintenance: model.maintenance
            )
        if let restore = MenuBarStatus.restoreLine(progress: model.restoreActivity) {
            lines.append(restore)
        }
        if let console = MenuBarStatus.consoleLine(isRunning: model.console.isRunning) {
            lines.append(console)
        }
        if let headline = MenuBarStatus.headline(
            activity: model.activity,
            maintenance: model.maintenance,
            isRestoring: model.isRestoring,
            isConsoleRunning: model.console.isRunning,
            hasNoRepositories: hasNoRepositories,
            hold: hold,
            repositories: model.configuration.repositories,
            nextRun: model.nextScheduledRun
        ) {
            menu.addItem(disabledItem(headline))
        } else {
            for line in lines {
                menu.addItem(disabledItem(line.text))
            }
        }

        menu.addItem(.separator())

        if hasNoRepositories {
            // The icon's `unconfigured` face sent the user here; the menu it
            // opens must answer, not just say "nothing scheduled".
            let add = NSMenuItem(
                title: "Add a Repository…",
                action: #selector(addRepository),
                keyEquivalent: ""
            )
            add.target = self
            menu.addItem(add)
        } else {
            // One submenu per repository, in configuration order, so the
            // tray names each plan's repository. App-wide items stay
            // outside: they act on every repository at once.
            for group in MenuBarStatus.planGroups(
                plans: model.configuration.plans,
                repositories: model.configuration.repositories,
                activity: model.activity,
                isResticAvailable: model.isResticAvailable,
                lockedRepositories: model.lockedRepositories
            ) {
                let submenu = NSMenu(title: group.title)
                submenu.autoenablesItems = false
                for row in group.rows {
                    let action: Selector? = switch row.action {
                    case .backUp: #selector(backUpNow(_:))
                    case .stop: #selector(stopBackup(_:))
                    case .none: nil
                    }
                    let item = NSMenuItem(title: row.title, action: action, keyEquivalent: "")
                    item.target = self
                    // Explicit, not auto-enabled: see `autoenablesItems`
                    // above.
                    item.isEnabled = row.isEnabled
                    item.toolTip = row.disabledReason
                    item.representedObject = row.planID.uuidString
                    submenu.addItem(item)
                }
                let item = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                // Enabled even with every row disabled, like the pause
                // submenu: the rows carry their own state.
                item.isEnabled = true
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if case .paused = hold {
            let resume = NSMenuItem(title: "Resume Backups", action: #selector(resumeBackups), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
            menu.addItem(.separator())
        } else if !hasNoRepositories {
            // A battery-only hold still offers the pause: the user may want
            // one that outlasts plugging in.
            menu.addItem(pauseMenuItem(title: "Pause Backups", stopsRunningBackups: false))
            // Only while a backup runs, and never the default: a stopped
            // backup starts over — restic cannot resume one.
            if !model.activity.isEmpty {
                menu.addItem(pauseMenuItem(title: "Pause and Stop Running Backups", stopsRunningBackups: true))
            }
            menu.addItem(.separator())
        }

        let open = NSMenuItem(
            title: "Open SwiftRestic",
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(
            title: "Quit SwiftRestic",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A pause submenu: one item per length, each carrying its length.
    private func pauseMenuItem(title: String, stopsRunningBackups: Bool) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for length in PauseLength.allCases {
            let item = NSMenuItem(
                title: length.menuTitle,
                action: stopsRunningBackups ? #selector(pauseAndStopBackups(_:)) : #selector(pauseBackups(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isEnabled = true
            item.representedObject = length.rawValue
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        return item
    }

    // MARK: - Actions

    @objc private func backUpNow(_ sender: NSMenuItem) {
        guard let planID = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        model.runBackup(planID: planID)
    }

    /// A plain Stop: recorded as cancelled and stamped, like the plan page's.
    @objc private func stopBackup(_ sender: NSMenuItem) {
        guard let planID = (sender.representedObject as? String).flatMap(UUID.init(uuidString:)) else { return }
        model.cancelBackup(planID: planID)
    }

    @objc private func pauseBackups(_ sender: NSMenuItem) {
        guard let length = (sender.representedObject as? String).flatMap(PauseLength.init(rawValue:)) else { return }
        model.pauseBackups(for: length)
    }

    @objc private func pauseAndStopBackups(_ sender: NSMenuItem) {
        guard let length = (sender.representedObject as? String).flatMap(PauseLength.init(rawValue:)) else { return }
        model.pauseBackups(for: length, stoppingRunningBackups: true)
    }

    @objc private func resumeBackups() {
        model.resumeBackups()
    }

    /// Brings the window back, or recreates it after it was closed — the
    /// tray is the only way in once the window is gone. Three bridges in
    /// order of reliability: the `openWindow` action the main window's root
    /// view parked on the router, an existing window made key, and the
    /// reopen Apple event — the path a Dock click takes, which SwiftUI's
    /// own delegate answers by rebuilding the `Window` scene.
    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = router.openMainWindowAction {
            open(id: "main")
            return
        }
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let aeDesc = event.aeDesc {
            var desc = aeDesc.pointee
            // The copied descriptor's storage belongs to `event`; the send
            // must finish before that storage can go away. No reply is
            // requested, so nothing reads the send's status.
            _ = withExtendedLifetime(event) {
                AESendMessage(&desc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addRepository() {
        // The intent travels through the router *before* the window opens, so
        // nothing depends on how many run-loop turns the window takes to
        // appear — the same rule the File command follows.
        router.request(.newRepository)
        openMainWindow()
    }

    /// Goes through the app delegate, which flushes pending saves and stops
    /// any running restic first — never a bare exit.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
