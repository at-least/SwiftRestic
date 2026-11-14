import AppKit
import SwiftUI
import UserNotifications

/// Identifiers are read by `NotificationRoute`; a run's click takes the
/// tray's problem line's route (`TrayStatusItem.showRun`).
extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run { openNotification(identifier) }
    }
}

/// Quitting is the one moment the resident app is guaranteed: pending saves
/// are flushed and running restic terminated before the process goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var router: AppRouter?

    /// The tray (AppKit-owned, see TrayStatusItem) is created once, when the
    /// scene's `task` hands over the model and router.
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

    private func openNotification(_ identifier: String) {
        guard let model, let router, let tray else {
            notificationAwaitingWiring = identifier
            return
        }
        switch NotificationRoute.route(forIdentifier: identifier) {
        case let .plan(planID):
            if model.plan(id: planID) != nil { router.selection = .plan(planID) }
            tray.openMainWindow()
        case let .run(runID):
            tray.showRun(runID)
        case nil:
            return
        }
    }

    /// Before launch finishes, as UserNotifications asks: a click that
    /// launched the app is delivered to the delegate set by then. Without
    /// one the click only brings the app forward.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Tooltips show at once, without AppKit's resting pause: the user's
        // call. 50 ms, not 0: with 0, a pointer gliding onto a checkbox
        // raised no tooltip at all (0 of 5, macOS 26), where 50 ms raised
        // them in about 0.09 s. In the registration domain, so a value the
        // defaults domain holds still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 50])
        EditMenuTrim.install()
        if AppModel.supportsNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    private var tray: TrayStatusItem?
    /// A second ⌘Q re-enters `applicationShouldTerminate` mid-dialog; this
    /// keeps it from stacking a second alert.
    private var isConfirmingQuit = false
    /// `shutdown` takes seconds (cancelled restic children are awaited);
    /// a second ⌘Q meanwhile must not raise an alert whose Cancel would be a
    /// lie, nor run a second shutdown.
    private var isTerminating = false
    /// Set on a logout, restart or shutdown, and never reset. It can only
    /// keep the schedule question away, never hold a logout: after a logout
    /// another app cancelled, a later ⌘Q skips that question.
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
    /// Access or the login item changed, so every activation asks again —
    /// here rather than in Settings, so the plan editor catches up while no
    /// Settings window exists. An activation before the model arrives is
    /// covered by bootstrap's own reads.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await model?.refreshFullDiskAccess() }
        Task { await model?.refreshLoginItemStatus() }
        model?.refreshStaleListings()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if isConfirmingQuit { return .terminateCancel }
        if isTerminating {
            // A second ⌘Q during shutdown is the force-quit escape hatch:
            // without it, a hung restic child would make the app unquittable.
            return .terminateNow
        }

        // The app menu, ⌘Q and the tray call terminate: with no Apple event;
        // the Dock's, AppleScript's and loginwindow's quit arrives as a quit
        // Apple event. Its kAEQuitReason is not trusted to tell a logout from
        // the Dock (AppleEvents.h: a quit "may include" it), and a wrong
        // guess would put a question in front of a logout, so every quit
        // event counts as not chosen here.
        let userChoseQuit = NSAppleEventManager.shared().currentAppleEvent == nil && !sessionIsEnding

        // Restic work in flight gets one confirmation, on every quit path: a
        // backup app must not silently cancel its own work.
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
                // and the HIG keeps Cancel from being the default ("avoid
                // making any button the default button"). Escape still
                // reaches Cancel.
                alert.buttons[0].keyEquivalent = ""
                // Full Keyboard Access presses the focused button with Space:
                // focus starts on Cancel, not Quit Anyway.
                alert.window.initialFirstResponder = alert.buttons[1]
            } else {
                // Nothing in progress: the alert only informs, so Quit keeps
                // Return.
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
        // `Window`, not `WindowGroup`: a group is multi-instance, so opening
        // the window would add a second one instead of bringing it forward.
        Window("SwiftRestic", id: Self.mainWindowID) {
            // One minute clock for the whole window, so every relative time
            // in it moves on together.
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
            // Replaced, not emptied: ⌘N is macOS's reflex for "new thing".
            CommandGroup(replacing: .newItem) {
                let commands = model.repositoryCommands(for: router.selection)
                Button("Back Up a Folder…") { ask(.newPlan) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!commands.canNewPlan)

                Button("Add Backup Location…") {
                    ask(.newRepository)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!commands.canAddRepository)
            }
            // With no Help Book, macOS's own item only said "Help isn't
            // available for SwiftRestic." A window, not a sheet, so the help
            // reads beside an open editor.
            CommandGroup(replacing: .help) {
                Button("SwiftRestic Help") { openWindow(id: Self.helpWindowID) }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Find…") { ask(.showFind) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(!model.repositoryCommands(for: router.selection).canFind)
            }
            RestoreCommands()
            CommandGroup(replacing: .importExport) {}
            // The HIG's Split views: "Provide multiple ways to reveal hidden
            // panes".
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

        // Opened only from the damage it repairs (`RepairButton`):
        // without commandsRemoved the Window menu lists it.
        Window("restic Console", id: Self.consoleWindowID) {
            ResticConsoleView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 480)
        .commandsRemoved()
    }

    /// Also opens the window: an intent parked while no window exists would
    /// otherwise ambush a later open.
    private func ask(_ intent: AppRouter.Intent) {
        router.request(intent)
        openWindow(id: Self.mainWindowID)
    }

    /// Items acting on the selected plan grey out on any other selection
    /// rather than doing nothing. Titles stay put for Help-menu search; only
    /// the state toggles change. Pausing calls the model directly, as the
    /// tray does: no editor holds a draft of it.
    private var backupMenu: some Commands {
        CommandMenu("Backup") {
            let p = model.planCommands(for: router.selection)
            Button("Back Up Now") { ask(.runSelectedPlan) }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!p.canBackUp)
            // Routed, so under a sheet it can at worst be swallowed, never
            // stop a run nobody sees.
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

    /// What the toolbar switches, each a command too (the HIG's Toolbars:
    /// "Make every toolbar item available as a command in the menu bar"),
    /// greyed where the page has none.
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
            Toggle("Show Problems Only", isOn: Binding(
                get: { router.activityShowsProblemsOnly },
                set: { router.activityShowsProblemsOnly = $0 }
            ))
            .disabled(router.selection != .activity)
            Divider()
        }
    }

    /// `.disabled` on a Menu in the menu bar greys only its items, leaving
    /// the submenu's own row enabled, so a submenu that cannot act is a
    /// plain disabled item of the same title.
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

    /// Free Up Space is no command: it runs on its schedule, and a full
    /// location's fix and Activity's retry ask for it. Nothing destructive
    /// has a key.
    private var locationMenu: some Commands {
        CommandMenu("Location") {
            let r = model.repositoryCommands(for: router.selection)
            Button("Verify Backups") {
                if let id = r.repositoryID { ask(.verifyBackups(id)) }
            }
            .disabled(!r.canMaintain)

            Divider()

            Button("Edit Location…") {
                if let id = r.repositoryID { ask(.editRepository(id)) }
            }
            .disabled(!r.canEdit)
            Button("Remove Location…") {
                if let id = r.repositoryID { ask(.confirm(.deleteRepository(id))) }
            }
            .disabled(!r.canRemove)
        }
    }
}
