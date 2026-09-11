import AppKit
import Carbon
import Foundation
import Observation

/// The tray, as a first-party AppKit status item.
///
/// Why not SwiftUI's `MenuBarExtra`: measured on this app's own builds, a
/// `.menu`-style label's image is pushed to the status item by exactly one
/// mechanism — a `TimelineView` in the label — and *any* `TimelineView` in
/// the label's structure, even in a branch that is not being rendered, pegs
/// the main thread at 100% forever in a SwiftUI-internal
/// requestUpdate → setImage loop. Remove the timeline and the icon freezes
/// on its launch frame; label-side `@State`, `onReceive` timers, observed
/// model writes and subview identity changes were each measured to never
/// reach the button. AppKit's own `NSStatusItem` has no such trade: the
/// image is set directly, the menu is rebuilt on open, and nothing spins.
///
/// Faces, lines and pulse math all stay in `MenuBarStatus`/`MenuBarLogo`,
/// the pure, tested core this controller merely renders.
@MainActor
final class TrayStatusItem: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private var pulseTimer: Timer?
    /// The per-plan rows' tag → plan mapping, rebuilt with the menu.
    private var planIDsByTag: [Int: UUID] = [:]
    private var nextPlanTag = 1

    init(model: AppModel) {
        self.model = model
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

    /// The observed inputs are exactly the ones `iconState` reads — reading
    /// more would re-fire this loop on every run-record append.
    private func refresh() {
        let state = MenuBarStatus.iconState(
            activity: model.activity,
            maintenance: model.maintenance,
            isRestoring: model.isRestoring,
            isConsoleRunning: model.console.isRunning,
            hasNoRepositories: model.configuration.repositories.isEmpty,
            runs: model.configuration.runs
        )
        statusItem.isVisible = model.configuration.settings.showMenuBarExtra
        applyFace(for: state)
        armPulse(for: state)

        withObservationTracking {
            _ = model.activity
            _ = model.maintenance
            _ = model.restoreActivity
            _ = model.console.isRunning
            _ = model.configuration.repositories.isEmpty
            _ = model.configuration.runs.isEmpty
            _ = model.configuration.settings.showMenuBarExtra
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Re-renders the face for the current state without touching the
    /// observation registration — the theme-changed path's entry point.
    private func reapplyFace() {
        applyFace(for: MenuBarStatus.iconState(
            activity: model.activity,
            maintenance: model.maintenance,
            isRestoring: model.isRestoring,
            isConsoleRunning: model.console.isRunning,
            hasNoRepositories: model.configuration.repositories.isEmpty,
            runs: model.configuration.runs
        ))
    }

    private func applyFace(for state: MenuBarStatus.IconState) {
        let button = statusItem.button
        switch MenuBarStatus.glyph(for: state) {
        case .logo:
            button?.image = MenuBarLogo.image()
        case .badgedLogo:
            // The baked badge variants are keyed on the *item's* appearance,
            // which follows the menu bar and can differ from the app's.
            let isDark = button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            button?.image = isDark ? MenuBarLogo.badgedDarkImage : MenuBarLogo.badgedLightImage
        case .animatedLogo:
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button?.image = MenuBarLogo.stillRunningImage
            } else {
                button?.image = MenuBarLogo.image(phase: MenuBarLogo.phase(at: .now))
            }
        }
        button?.setAccessibilityLabel(MenuBarStatus.accessibilityDescription(for: state))
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
        planIDsByTag.removeAll()
        nextPlanTag = 1

        let hasNoRepositories = model.configuration.repositories.isEmpty
        // The failure line leads, unless the `?` face summoned the menu and
        // an old failure from a since-removed repository would talk over the
        // setup question — the same yield MenuBarStatus defines.
        if let problem = MenuBarStatus.problemLine(
            runs: model.configuration.runs,
            hasNoRepositories: hasNoRepositories
        ) {
            menu.addItem(disabledItem(problem))
        }
        var lines = MenuBarStatus.runningLines(plans: model.configuration.plans, activity: model.activity)
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
            for plan in model.configuration.plans {
                let title = "Back Up “\(plan.name.isEmpty ? "Untitled Plan" : plan.name)” Now"
                let item = NSMenuItem(title: title, action: #selector(backUpNow(_:)), keyEquivalent: "")
                item.target = self
                item.isEnabled = !model.isRunning(planID: plan.id) && plan.isConfigurationComplete
                item.tag = nextPlanTag
                planIDsByTag[nextPlanTag] = plan.id
                nextPlanTag += 1
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

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

    // MARK: - Actions

    @objc private func backUpNow(_ sender: NSMenuItem) {
        guard let planID = planIDsByTag[sender.tag] else { return }
        model.runBackup(planID: planID)
    }

    /// Brings the window back, or recreates it after it was closed — the
    /// tray is the only way in once the window is gone. Three bridges in
    /// order of reliability: the `openWindow` action the main window's root
    /// view parked on the model (captured once, still callable after the
    /// view it came from is gone), an existing window made key, and the
    /// reopen Apple event — the path a Dock click takes, which SwiftUI's
    /// own delegate answers by rebuilding the `Window` scene.
    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = model.openMainWindowAction {
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
            // must finish before that storage can go away.
            withExtendedLifetime(event) {
                AESendMessage(&desc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addRepository() {
        // The intent travels through the model *before* the window opens, so
        // nothing depends on how many run-loop turns the window takes to
        // appear — the same rule the File command follows.
        model.pendingNewRepository = true
        openMainWindow()
    }

    /// Goes through the app delegate, which flushes pending saves and stops
    /// any running restic first — never a bare exit.
    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
