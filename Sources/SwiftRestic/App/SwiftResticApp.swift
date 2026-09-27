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
    /// rather than in Settings, so the Overview and the plan editor catch
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

// The Backup and Help menus used to reach RootView through posted
// `Notification.Name`s; those asks are typed intents on `AppRouter` now
// (`router.request(_:)`), so the stringly seam is gone entirely.


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
            RootView()
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
            // footer. RootView owns the sheets and ignores these while a sheet
            // is already up. Every command that targets the window also opens
            // it: an intent parked while no window exists would otherwise
            // ambush a later open — the old notification seam dropped asks
            // nobody was listening for; these asks open their listener.
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
            CommandMenu("Backup") {
                Button("Back Up All Plans Now") {
                    for plan in model.configuration.plans where plan.isConfigurationComplete {
                        model.runBackup(planID: plan.id)
                    }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])

                Button("Back Up Selected Plan") {
                    router.request(.runSelectedPlan)
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("b", modifiers: .command)
                // The consuming handler in RootView no-ops when the selection
                // is not a runnable plan; an enabled menu item over a disabled
                // action is a menu that lies.
                .disabled(!model.canRunPlan(at: router.selection))

                Button("Find Files in Snapshots…") {
                    router.request(.showFind)
                    openWindow(id: Self.mainWindowID)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Refresh All Snapshots") {
                    Task { await model.refreshAllSnapshots() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

    }
}
