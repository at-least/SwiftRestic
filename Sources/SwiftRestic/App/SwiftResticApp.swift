import AppKit
import SwiftUI

/// The app stays resident behind its menu bar item, so quitting is the only
/// moment we are guaranteed to get — pending saves must be flushed and any
/// running restic terminated before the process goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var router: AppRouter?

    /// The tray is AppKit-owned (see TrayStatusItem for why); it is created
    /// once, when the model and router first reach the delegate together —
    /// the scene's `task` hands both over as a pair.
    func wireAppSurface(model: AppModel, router: AppRouter) {
        guard tray == nil else { return }
        self.model = model
        self.router = router
        tray = TrayStatusItem(model: model, router: router)
    }

    private var tray: TrayStatusItem?
    /// Set while the quit confirmation's modal loop is up. The modal run loop
    /// keeps the app alive, so a second ⌘Q re-enters `applicationShouldTerminate`
    /// mid-dialog; answering it again would stack a second alert on the first.
    private var isConfirmingQuit = false
    /// Set once quit is accepted and `shutdown` is unwinding — that takes
    /// seconds (cancelled restic children are awaited), and during it a second
    /// ⌘Q must not raise a second alert whose Cancel would be a lie, nor run
    /// a second shutdown against tasks already being awaited.
    private var isTerminating = false
    /// Set when macOS announces a logout, restart or shutdown, and never
    /// reset. A second guard behind the Apple-event test in
    /// `applicationShouldTerminate`: it can only keep the schedule question
    /// away, never hold a logout. After a logout another app cancelled, a
    /// later ⌘Q skips that question — a missed warning, not a blocked logout.
    private var sessionIsEnding = false
    private var powerOffObserver: NSObjectProtocol?

    /// Closing the window must not quit: scheduled backups need the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsEnding = true }
        }
        #if DEBUG
        // Capture runs can pin the appearance so the same pane is captured in
        // light and dark without flipping the whole system.
        if let name = ProcessInfo.processInfo.environment["SWIFTRESTIC_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        scheduleDebugCapture()
        #endif
    }

    /// Coming back from System Settings is the only sign that Full Disk
    /// Access was granted or taken away, or that the login item was approved
    /// or removed under Login Items, so every activation asks again — here
    /// rather than in Settings, so the Next runs card and the plan editor catch
    /// up while no Settings window exists. Two tasks, so neither answer
    /// waits on the other's round trip. The model arrives with the scene's
    /// task; an activation before that is covered by bootstrap's own reads.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model?.refreshFullDiskAccess() }
        Task { await model?.refreshLoginItemStatus() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if isConfirmingQuit { return .terminateCancel }
        if isTerminating {
            // Shutdown is already unwinding, and it awaits cancelled restic
            // children. A second ⌘Q is the user's force-quit escape hatch —
            // without it, a hung child would make the app unquittable.
            return .terminateNow
        }

        // Whether the user chose this quit here — the app menu, ⌘Q, the
        // tray. Those call terminate: directly and arrive with no Apple
        // event; the Dock's, AppleScript's and loginwindow's quit arrives as
        // a quit Apple event, current while this runs (probed: design-probes/
        // 08-start-at-login, quitprobe and swiftuiquit). The event's reason
        // is not trusted to tell a logout from the Dock: AppleEvents.h says
        // only that a quit "may include" kAEQuitReason, and a wrong guess
        // would put a question in front of a logout. So every quit event
        // counts as not chosen here.
        let userChoseQuit = NSAppleEventManager.shared().currentAppleEvent == nil && !sessionIsEnding

        // A backup app that silently cancels its own work on quit is breaking
        // its promise, so restic work in flight gets one confirmation, on
        // every path. A quit the user chose also names the scheduled run it
        // will miss while the app will not start at login. The words come
        // from the model, where they are testable.
        if let confirmation = model.quitConfirmation(userChoseQuit: userChoseQuit) {
            isConfirmingQuit = true
            // The tray's Quit can be chosen while another app is in front;
            // the question must come forward with it, not sit behind.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit SwiftRestic?"
            alert.informativeText = confirmation.message
            if confirmation.interruptsWork {
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Quit Anyway")
                alert.addButton(withTitle: "Cancel")
                alert.buttons[0].hasDestructiveAction = true
                // The safe answer owns Return: quitting must be a deliberate
                // click, never the key a reflex hits while typing elsewhere.
                // Escape keeps its built-in route to the "Cancel" button.
                alert.buttons[1].keyEquivalent = "\r"
            } else {
                // Nothing is in progress and the user just asked to quit:
                // the alert informs, so Quit keeps NSAlert's Return and
                // Cancel its Escape.
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
            }
            let confirmed = alert.runModal() == .alertFirstButtonReturn
            isConfirmingQuit = false
            guard confirmed else { return .terminateCancel }
        }
        isTerminating = true

        Task { @MainActor in
            #if DEBUG
            Self.debugLog("terminate: shutting down")
            #endif
            await model.shutdown()
            #if DEBUG
            Self.debugLog("terminate: shutdown finished")
            #endif
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// The menus used to reach RootView through posted `Notification.Name`s;
// those asks are typed intents on `AppRouter` now (`router.request(_:)`), so
// the stringly seam is gone entirely.


@main
struct SwiftResticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var router = AppRouter()
    @Environment(\.openWindow) private var openWindow

    private static let mainWindowID = "main"

    var body: some Scene {
        // `Window`, not `WindowGroup`: a group is multi-instance, so the menu
        // bar's "Open SwiftRestic" would add a second identical window every time
        // instead of bringing the existing one forward.
        Window("SwiftRestic", id: Self.mainWindowID) {
            // One minute clock for the whole window (MinuteClock.swift), so
            // every relative time in it moves on, and moves on together.
            TimelineView(.everyMinute) { context in
                RootView()
                    .environment(\.now, context.date)
            }
            .environment(model)
            .environment(router)
            .frame(minWidth: 940, minHeight: 600)
            .task {
                appDelegate.wireAppSurface(model: model, router: router)
                await model.bootstrap()
            }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // ⌘N is macOS's reflex for "new thing" — an emptied group here
            // meant adding a repository was always a mouse trip to the sidebar
            // footer. RootView owns the sheets and refuses these, with a beep,
            // while a sheet is already up. Every command that targets the
            // window also opens it: an intent parked while no window exists
            // would otherwise ambush a later open — the old notification seam
            // dropped asks nobody was listening for; these asks open their
            // listener.
            CommandGroup(replacing: .newItem) {
                Button("New Backup Plan…") {
                    router.request(.newPlan)
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.configuration.repositories.isEmpty)

                Button("Add Repository…") {
                    // Through the router's pending intent, not a live action:
                    // the ask has to survive the window being closed. The
                    // command also opens the window, like the tray's identical
                    // button — a menu command that visibly does nothing is a
                    // dead key, and the root view clears expired asks on
                    // appear.
                    router.request(.newRepository)
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("SwiftRestic Concepts…") {
                    router.request(.showConcepts)
                    openWindow(id: Self.mainWindowID)
                }
                Divider()
                Button("restic Documentation") {
                    NSWorkspace.shared.open(AppLinks.documentation)
                }
                Button("restic Change Log") {
                    NSWorkspace.shared.open(AppLinks.changelog)
                }
            }
            planMenu
            repositoryMenu
        }

        Settings {
            SettingsView()
                .environment(model)
        }

    }

    /// An ask for the root view, which also opens the window: an intent
    /// parked while no window exists would otherwise ambush a later open.
    /// RootView refuses it — with a beep — while any sheet is up, where a
    /// Pause Schedule would be undone by the plan editor's save
    /// (`BackupPlan.merging(draft:)` keeps the draft's `isEnabled`).
    private func ask(_ intent: AppRouter.Intent) {
        router.request(intent)
        openWindow(id: Self.mainWindowID)
    }

    /// Arq's Backup Plan menu: everything a plan's toolbar and sidebar menu
    /// offer, acting on the plan selected in the sidebar and greyed out when
    /// the selection is anything else — an enabled item over an action that
    /// does nothing is a menu that lies. Titles stay put, so Help-menu search
    /// and muscle memory find them; only the two state toggles change.
    private var planMenu: some Commands {
        CommandMenu("Plan") {
            let p = model.planCommands(for: router.selection)
            Button("Back Up Now") { ask(.runSelectedPlan) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!p.canBackUp)
            // The Mac's Stop key. Routed like the rest, so under a sheet it
            // can at worst be swallowed, never stop a run nobody sees.
            Button(p.stopTitle) {
                if let id = p.planID { ask(.stopPlan(id)) }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!p.canStop)
            Button("Back Up All Plans Now") {
                for plan in model.configuration.plans where plan.isConfigurationComplete {
                    model.runBackup(planID: plan.id)
                }
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!p.canBackUpAll)

            Divider()

            // The tray's app-wide pause, here too: with the menu bar item
            // hidden it was the only way in. Direct calls, as the tray's:
            // no editor holds a draft of these settings.
            if p.backupsPaused {
                Button("Resume Backups") { model.resumeBackups() }
            } else {
                lengthsMenu("Pause Backups", isEnabled: p.canPauseBackups) { length in
                    model.pauseBackups(for: length)
                }
            }
            // Never the default: a stopped backup starts over.
            lengthsMenu("Pause and Stop Running Backups", isEnabled: p.canPauseAndStopBackups) { length in
                model.pauseBackups(for: length, stoppingRunningBackups: true)
            }

            Divider()

            Button("Edit Plan…") {
                if let id = p.planID { ask(.editPlan(id)) }
            }
            .disabled(!p.canEdit)
            // The plan toolbar's pair, lengths and all.
            if p.isScheduleActive {
                lengthsMenu(p.scheduleTitle, isEnabled: p.canToggleSchedule) { length in
                    if let id = p.planID { ask(.pauseSchedule(id, length)) }
                }
            } else {
                Button(p.scheduleTitle) {
                    if let id = p.planID { ask(.resumeSchedule(id)) }
                }
                .disabled(!p.canToggleSchedule)
            }
            Button("Apply Retention Now…") {
                if let id = p.planID { ask(.applyRetention(id)) }
            }
            .disabled(!p.canApplyRetention)

            Divider()

            Button("Delete Plan…") {
                if let id = p.planID { ask(.confirm(.deletePlan(id))) }
            }
            .disabled(!p.canDelete)
        }
    }

    /// A submenu of the three pause lengths. `.disabled` on a Menu in the
    /// menu bar greys only its items: the submenu's own row stays enabled
    /// (measured via Accessibility — "Pause Schedule" read enabled over
    /// three greyed lengths with a non-plan pane, the since-removed
    /// Overview, selected), an item that opens onto
    /// nothing it can do. So a submenu that cannot act is a plain disabled
    /// item of the same title.
    @ViewBuilder
    private func lengthsMenu(
        _ title: String,
        isEnabled: Bool,
        action: @escaping @MainActor (PauseLength) -> Void
    ) -> some View {
        if isEnabled {
            Menu(title) {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) { action(length) }
                }
            }
        } else {
            Button(title) {}
                .disabled(true)
        }
    }

    /// The repository selected in the sidebar — or the one a selected
    /// Restore record or plan uses. The repository page keeps no maintenance
    /// buttons of its own: Check, Prune and the repairs are here, and the
    /// first two on the sidebar row's menu. Nothing destructive has a key.
    private var repositoryMenu: some Commands {
        CommandMenu("Repository") {
            let r = model.repositoryCommands(for: router.selection)
            Button("Find Files in Snapshots…") { ask(.showFind) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!r.canFind)
            Button("Refresh All Snapshots") {
                Task { await model.refreshAllSnapshots() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!r.canRefreshAll)
            // Not selection-bound: the console pane picks its own
            // repository, so it needs only one to exist and restic to run.
            Button("restic Console…") { ask(.showConsole) }
                .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)

            Divider()

            Button("Check…") {
                if let id = r.repositoryID { ask(.confirm(.check(id))) }
            }
            .disabled(!r.canMaintain)
            Button("Prune Now…") {
                if let id = r.repositoryID { ask(.confirm(.prune(id))) }
            }
            .disabled(!r.canMaintain)
            Button("Remove Stale Locks…") {
                if let id = r.repositoryID { ask(.confirm(.unlock(id))) }
            }
            .disabled(!r.canMaintain)
            Button("Rebuild Search Index…") {
                if let id = r.repositoryID { ask(.confirm(.rebuildIndex(id))) }
            }
            .disabled(!r.canMaintain)

            Divider()

            Button("Edit Repository…") {
                if let id = r.repositoryID { ask(.editRepository(id)) }
            }
            .disabled(!r.canEdit)
            Button("Remove from SwiftRestic…") {
                if let id = r.repositoryID { ask(.confirm(.removeRepository(id))) }
            }
            .disabled(!r.canRemove)
        }
    }
}
