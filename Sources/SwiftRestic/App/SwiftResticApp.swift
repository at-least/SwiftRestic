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
    func wireAppSurface(model: AppModel, router: AppRouter) {
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
        if identifier.hasPrefix(AppModel.quietPlanNotificationPrefix),
           let planID = UUID(uuidString: String(identifier.dropFirst(AppModel.quietPlanNotificationPrefix.count))) {
            if model.plan(id: planID) != nil { router.selection = .plan(planID) }
        } else if let runID = UUID(uuidString: identifier) {
            router.focusRun(runID)
        } else {
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
                // With no repository yet, through adding one
                // (`RootView.startNewPlan`).
                Button("New Backup Plan…") { ask(.newPlan) }
                    .keyboardShortcut("n", modifiers: .command)

                Button("Add Repository…") {
                    // Through the router's pending intent: the ask survives
                    // the window being closed, and a menu command that
                    // visibly does nothing is a dead key.
                    ask(.newRepository)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            // The menu's first item is the app's own help, as the HIG's Help
            // menu has it. With no Help Book, macOS's own item only said
            // "Help isn't available for SwiftRestic."; this one opens the
            // concepts in a window of their own — not a sheet, so they read
            // beside an open editor — and asks nothing of the main window.
            CommandGroup(replacing: .help) {
                Button("SwiftRestic Help") { openWindow(id: Self.helpWindowID) }
                    .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("restic Documentation") {
                    NSWorkspace.shared.open(AppLinks.documentation)
                }
                Button("restic Change Log") {
                    NSWorkspace.shared.open(AppLinks.changelog)
                }
            }
            RestoreCommands()
            CommandGroup(replacing: .importExport) {
                Button("Export Settings…") { ask(.exportSettings) }
                    .disabled(!model.canTransferSettings)
                Button("Import Settings…") { ask(.importSettings) }
                    .disabled(!model.canTransferSettings)
            }
            // View ▸ Show/Hide Sidebar (⌃⌘S): with the sidebar hidden, its
            // toolbar button had been the one way back (the HIG's Split
            // views: "Provide multiple ways to reveal hidden panes").
            SidebarCommands()
            appMenu
            viewMenu
            planMenu
            repositoryMenu
        }

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        // Help ▸ SwiftRestic Help: the restic vocabulary the app assumes.
        Window("SwiftRestic Help", id: Self.helpWindowID) {
            ConceptsView()
        }
        .defaultSize(width: 480, height: 600)
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

    /// Everything a plan page's cards and the sidebar row's menu offer,
    /// acting on the plan selected in the sidebar and greyed out when the
    /// selection is anything else — an enabled item over an action that does
    /// nothing is a menu that lies. Titles stay put, so Help-menu search and
    /// muscle memory find them; only the two state toggles change.
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

            Divider()

            Button("Edit Plan…") {
                if let id = p.planID { ask(.editPlan(id)) }
            }
            .disabled(!p.canEdit)
            // The Schedule card's pair, lengths and all.
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
            Button("Apply Retention Now") {
                if let id = p.planID { ask(.applyRetention(id)) }
            }
            .disabled(!p.canApplyRetention)

            Divider()

            Button("Remove Plan") {
                if let id = p.planID { ask(.confirm(.deletePlan(id))) }
            }
            .disabled(!p.canDelete)
        }
    }

    /// The SwiftRestic menu's backup items, under Settings: they act on
    /// every plan, not the sidebar's selection, so they stay out of the Plan
    /// menu. The tray's app-wide pause, here too: the menu bar item can be
    /// hidden. Direct calls, as the tray's: no editor holds a draft of these
    /// settings.
    private var appMenu: some Commands {
        CommandGroup(after: .appSettings) {
            let p = model.planCommands(for: router.selection)
            Divider()
            Button("Back Up All Plans Now") { model.backUpAllPlans() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!p.canBackUpAll)
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

    /// Acts on `commandRepositoryID(for:)`. The repository page keeps no
    /// maintenance buttons of its own: Check, Clean Up and the repairs are
    /// here, and the first two on the sidebar row's menu. Nothing
    /// destructive has a key.
    private var repositoryMenu: some Commands {
        CommandMenu("Repository") {
            let r = model.repositoryCommands(for: router.selection)
            Button("Find Files…") { ask(.showFind) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!r.canFind)
            Button("Refresh All Backups") {
                Task { await model.refreshAllSnapshots() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!r.canRefreshAll)
            Button("restic Console") { ask(.showConsole) }
                .disabled(!r.canOpenConsole)

            Divider()

            Button("Check Now…") {
                if let id = r.repositoryID { ask(.confirm(.check(id))) }
            }
            .disabled(!r.canMaintain)
            Button("Clean Up Now") {
                if let id = r.repositoryID { ask(.confirm(.prune(id))) }
            }
            .disabled(!r.canMaintain)
            // The repairs, rarely needed, apart from the routine upkeep. A
            // disabled Menu keeps its own row enabled (see `lengthsMenu`).
            if r.canMaintain, let id = r.repositoryID {
                Menu("Repair") {
                    Button("Unlock") { ask(.confirm(.unlock(id))) }
                    Button("Rebuild Search Index") { ask(.confirm(.rebuildIndex(id))) }
                }
            } else {
                Button("Repair") {}
                    .disabled(true)
            }

            Divider()

            Button("Edit Repository…") {
                if let id = r.repositoryID { ask(.editRepository(id)) }
            }
            .disabled(!r.canEdit)
            Button("Remove from SwiftRestic") {
                if let id = r.repositoryID { ask(.confirm(.removeRepository(id))) }
            }
            .disabled(!r.canRemove)
        }
    }
}
