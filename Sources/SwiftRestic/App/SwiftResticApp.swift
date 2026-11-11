import AppKit
import SwiftUI
import UserNotifications

/// A notification's identifier is its run's ID (`AppModel.notify`): the
/// click lands Activity on that run, the tray's problem line's route.
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run { openNotification(identifier) }
    }
}

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
    fileprivate func wireAppSurface(model: AppModel, router: AppRouter) {
        guard tray == nil else { return }
        self.model = model
        self.router = router
        tray = TrayStatusItem(model: model, router: router)
        if let identifier = notificationAwaitingWiring {
            notificationAwaitingWiring = nil
            openNotification(identifier)
        }
    }

    /// A notification clicked while the app was quit relaunches it, and its
    /// response can arrive before the window's task wires the router: it
    /// waits here for `wireAppSurface`.
    private var notificationAwaitingWiring: String?

    /// A quiet plan's notification opens the plan — while it still exists;
    /// a run's, the run.
    private func openNotification(_ identifier: String) {
        guard let model, let router else {
            notificationAwaitingWiring = identifier
            return
        }
        switch NotificationRoute.route(forIdentifier: identifier) {
        case let .plan(planID):
            if model.plan(id: planID) != nil { router.selection = .plan(planID) }
        case let .run(runID):
            router.focusRun(runID)
        case nil:
            return
        }
        tray?.openMainWindow()
    }

    /// Before launch finishes, as UserNotifications asks: a click that
    /// launched the app is delivered to the delegate set by then. Without
    /// one the click only brings the app forward.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tooltips show at once, without AppKit's resting pause (the user's
        // call, 2026-10-23): the editor's language checkboxes list their
        // patterns in theirs. 50 ms, not 0: with 0, a pointer gliding onto a
        // checkbox raised no tooltip at all (0 of 5, macOS 26), where 50 ms
        // raised them in about 0.09 s. In the registration domain, so a
        // value the defaults domain holds still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 50])
        EditMenuTrim.install()
        if AppModel.supportsNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
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
    /// rather than in Settings, so the plan editor catches
    /// up while no Settings window exists. Separate tasks, so no answer
    /// waits on another's round trip. The model arrives with the scene's
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
        // a quit Apple event, current while this runs. The event's reason
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
                // No button owns Return: quitting must be a deliberate click,
                // never the key a reflex hits while typing elsewhere, and the
                // HIG keeps Cancel from being the default ("avoid making any
                // button the default button"). Escape keeps its built-in
                // route to the "Cancel" button.
                alert.buttons[0].keyEquivalent = ""
                // Full Keyboard Access presses the focused button with Space:
                // focus starts on Cancel, not Quit Anyway.
                alert.window.initialFirstResponder = alert.buttons[1]
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

@main
struct SwiftResticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var router = AppRouter()
    @Environment(\.openWindow) private var openWindow

    private static let mainWindowID = "main"
    static let helpWindowID = "help"
    static let consoleWindowID = "console"

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
            // ⌘N is macOS's reflex for "new thing" — an emptied group would
            // make adding a repository a mouse trip to the sidebar footer.
            CommandGroup(replacing: .newItem) {
                // The folder panel, then the first-run sheet
                // (`RootView.startBackUpAFolder`).
                let commands = model.repositoryCommands(for: router.selection)
                Button("Back Up a Folder…") { ask(.newPlan) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!commands.canNewPlan)

                Button("Add Backup Location…") {
                    // Through the router's pending intent: the ask survives
                    // the window being closed, and a menu command that
                    // visibly does nothing is a dead key.
                    ask(.newRepository)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!commands.canAddRepository)
            }
            // The menu's first item is the app's own help, as the HIG's Help
            // menu has it. With no Help Book, macOS's own item only said
            // "Help isn't available for SwiftRestic."; this one opens the
            // concepts in a window of their own — not a sheet, so they read
            // beside an open editor — and asks nothing of the main window.
            CommandGroup(replacing: .help) {
                Button("SwiftRestic Help") { openWindow(id: Self.helpWindowID) }
                    .keyboardShortcut("?", modifiers: .command)
            }
            // A plan's page searches its own files, and every other page all
            // backups; both are the toolbar field's (`AppRouter.Intent.showFind`).
            CommandGroup(after: .textEditing) {
                Button("Find…") { ask(.showFind) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.repositoryCommands(for: router.selection).canFind)
            }
            RestoreCommands()
            CommandGroup(replacing: .importExport) {}
            // View ▸ Show/Hide Sidebar (⌃⌘S): with the sidebar hidden, its
            // toolbar button had been the one way back (the HIG's Split
            // views: "Provide multiple ways to reveal hidden panes").
            SidebarCommands()
            viewMenu
            backupMenu
            locationMenu
        }

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        Window("SwiftRestic Help", id: Self.helpWindowID) {
            ConceptsView()
        }
        .defaultSize(width: 480, height: 600)

        Window("restic Console", id: Self.consoleWindowID) {
            ResticConsoleView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 480)
    }

    /// An ask for the root view, which also opens the window: an intent
    /// parked while no window exists would otherwise ambush a later open.
    /// RootView refuses it, with a beep, while any sheet is up.
    private func ask(_ intent: AppRouter.Intent) {
        router.request(intent)
        openWindow(id: Self.mainWindowID)
    }

    /// Backups: the selected plan's, then pausing every plan's. Items
    /// acting on the selection grey out when it is anything else — an enabled
    /// item over an action that does nothing is a menu that lies. Titles stay
    /// put, so Help-menu search and muscle memory find them; only the state
    /// toggles change. Direct calls for every plan's, as the tray's: no editor
    /// holds a draft of them.
    private var backupMenu: some Commands {
        CommandMenu("Backup") {
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

            Divider()

            if p.backupsPaused {
                Button("Resume Backups") { model.resumeBackups() }
            } else {
                lengthsMenu("Pause Backups", isEnabled: p.canPauseBackups) { length in
                    model.pauseBackups(for: length)
                }
            }

            Divider()

            Button("Edit Plan…") {
                if let id = p.planID { ask(.editPlan(id)) }
            }
            .disabled(!p.canEdit)

            Divider()

            Button("Remove Plan…") {
                if let id = p.planID { ask(.confirm(.deletePlan(id))) }
            }
            .disabled(!p.canDelete)
        }
    }

    /// The View menu's own items, after the sidebar's: what the toolbar
    /// switches, each a command too (the HIG's Toolbars: "Make every
    /// toolbar item available as a command in the menu bar") — a page's
    /// Overview | Backups | Files with ⌘1–⌘3, Finder's keys for its views,
    /// a Files tab's Show Deleted Items and Activity's problems filter.
    /// Greyed where the page has none: Files on a group's page, every tab on
    /// a page with no tabs.
    private var viewMenu: some Commands {
        CommandGroup(after: .sidebar) {
            let page = router.selection
            Divider()
            ForEach(Array(PageTab.allCases.enumerated()), id: \.element) { index, tab in
                let offered = page?.pageTabs.contains(tab) == true
                Toggle(tab.menuTitle, isOn: Binding(
                    get: { offered && page.map { router.tab(of: $0) == tab } == true },
                    set: { isOn in
                        if isOn, offered, let page { router.setTab(tab, of: page) }
                    }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!offered)
            }
            Divider()
            // A plan's Files tab only, where the tree it changes is.
            // A show/hide pair, not a checkmark: the HIG's View menu items
            // name the state they change to ("Show Toolbar"/"Hide Toolbar").
            Button(router.filesShowsDeletedItems ? "Hide Deleted Items" : "Show Deleted Items") {
                router.filesShowsDeletedItems.toggle()
            }
            .disabled(!(page.map { $0.pageTabs.contains(.files) && router.tab(of: $0) == .files } ?? false))
            Toggle("Show Problems Only", isOn: Binding(
                get: { router.activityShowsProblemsOnly },
                set: { router.activityShowsProblemsOnly = $0 }
            ))
            .disabled(router.selection != .activity)
            Divider()
            Button("Refresh All Backups") {
                Task { await model.refreshAllSnapshots() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.repositoryCommands(for: page).canRefreshAll)
            Divider()
        }
    }

    /// A submenu of the pause lengths. `.disabled` on a Menu in the menu
    /// bar greys only its items: the submenu's own row stays enabled — an
    /// item that opens onto nothing it can do — so a submenu that cannot
    /// act is a plain disabled item of the same title.
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

    /// Acts on `commandRepositoryID(for:)`. Verify Backups also starts from
    /// the repository page's Maintenance header and the sidebar row's menu.
    /// Clean Up is no command: retention's own cleanup runs on its schedule,
    /// and a full location's fix and Activity's retry ask for one. Nothing
    /// destructive has a key.
    private var locationMenu: some Commands {
        CommandMenu("Location") {
            let r = model.repositoryCommands(for: router.selection)
            Button("Verify Backups") {
                if let id = r.repositoryID {
                    router.request(.verifyBackups(id))
                    openWindow(id: Self.mainWindowID)
                }
            }
            .disabled(!r.canMaintain)

            Divider()

            Button("Edit Backup Location…") {
                if let id = r.repositoryID { ask(.editRepository(id)) }
            }
            .disabled(!r.canEdit)
            Button("Remove from SwiftRestic…") {
                if let id = r.repositoryID { ask(.confirm(.deleteRepository(id))) }
            }
            .disabled(!r.canRemove)

            Divider()

            Button("restic Console") { openWindow(id: Self.consoleWindowID) }
                .disabled(!r.canOpenConsole)
        }
    }
}
