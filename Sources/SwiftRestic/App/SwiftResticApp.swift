import AppKit
import SwiftUI

/// The app stays resident behind its menu bar item, so quitting is the only
/// moment we are guaranteed to get — pending saves must be flushed and any
/// running restic terminated before the process goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// Set while the quit confirmation's modal loop is up. The modal run loop
    /// keeps the app alive, so a second ⌘Q re-enters `applicationShouldTerminate`
    /// mid-dialog; answering it again would stack a second alert on the first.
    private var isConfirmingQuit = false
    /// Set once quit is accepted and `shutdown` is unwinding — that takes
    /// seconds (cancelled restic children are awaited), and during it a second
    /// ⌘Q must not raise a second alert whose Cancel would be a lie, nor run
    /// a second shutdown against tasks already being awaited.
    private var isTerminating = false

    /// Closing the window must not quit: scheduled backups need the app alive.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Capture runs can pin the appearance so the same pane is captured in
        // light and dark without flipping the whole system.
        if let name = ProcessInfo.processInfo.environment["SWIFTRESTIC_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
        }
        scheduleDebugCapture()
        #endif
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

        // A backup app that silently cancels its own work on quit is breaking
        // its promise, so restic work in flight gets one confirmation. The
        // clauses come from the model, where they are testable.
        let interruptions = model.quitInterruptions
        if !interruptions.isEmpty {
            isConfirmingQuit = true
            let alert = NSAlert()
            alert.messageText = "Quit SwiftRestic?"
            alert.informativeText = interruptions.joined(separator: "\n")
                + "\nQuitting stops the work in progress; the run history records the interruption."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            // The safe answer owns Return: quitting must be a deliberate
            // click, never the key a reflex hits while typing elsewhere.
            // Escape keeps its built-in route to the "Cancel" button.
            alert.buttons[1].keyEquivalent = "\r"
            let confirmed = alert.runModal() == .alertFirstButtonReturn
            isConfirmingQuit = false
            guard confirmed else { return .terminateCancel }
        }
        isTerminating = true

        Task { @MainActor in
            #if DEBUG
            debugLog("terminate: shutting down")
            #endif
            await model.shutdown()
            #if DEBUG
            debugLog("terminate: shutdown finished")
            #endif
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension Notification.Name {
    /// Posted by the Backup menu. The sheet's state lives in `RootView`, which a
    /// menu command has no direct way to reach.
    static let swiftResticShowFind = Notification.Name("SwiftRestic.showFind")
    /// Posted by the Help menu; same arrangement as `swiftResticShowFind`.
    static let swiftResticShowConcepts = Notification.Name("SwiftRestic.showConcepts")
    /// Posted by the Backup menu; RootView knows which plan is selected.
    static let swiftResticRunSelected = Notification.Name("SwiftRestic.runSelected")
    /// Posted by the File menu; the new-item sheets are RootView's to present.
    static let swiftResticNewPlan = Notification.Name("SwiftRestic.newPlan")
    static let swiftResticNewRepository = Notification.Name("SwiftRestic.newRepository")
}

#if DEBUG
extension AppDelegate {
    /// Debug-only: write a PNG of the main window, then quit.
    ///
    /// `cacheDisplay` draws the live view hierarchy from inside this process, so
    /// unlike `screencapture` it needs no Screen Recording permission — which is
    /// what makes it usable from a terminal session or CI.
    func scheduleDebugCapture() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SWIFTRESTIC_CAPTURE"], !path.isEmpty else { return }
        let delay = Double(environment["SWIFTRESTIC_CAPTURE_DELAY"] ?? "") ?? 6

        if environmentFlag("SWIFTRESTIC_CAPTURE_VERBOSE") {
            Task { @MainActor in
                var last = ""
                while true {
                    let now = NSApp.windows.map { "\(type(of: $0))[\($0.title)] \($0.frame.size) visible=\($0.isVisible)" }
                        .joined(separator: " | ")
                    if now != last {
                        debugLog("windows @\(Int(Date.timeIntervalSinceReferenceDate)): \(now)")
                        last = now
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        Task { @MainActor in
            // A launch that is never activated (SSH, `&` from a script) does not
            // get its `Window` scene created at all — SwiftUI defers it until
            // the app is activated. The capture needs that window to exist, so
            // activate on purpose.
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .seconds(delay))
            captureMainWindow(to: URL(fileURLWithPath: path))
            // `NSApp.terminate` never reaches `applicationShouldTerminate` from
            // this unactivated, sheet-bearing debug launch, so shut the model
            // down directly and exit: this path exists only for captures.
            debugLog("captured; shutting down")
            await model?.shutdown()
            debugLog("shutdown finished; exiting")
            exit(0)
        }
    }

    func debugLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func environmentFlag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name].map { !$0.isEmpty } ?? false
    }

    private func captureMainWindow(to url: URL) {
        // Known artifact, verified live 2026-09: a sheet's tab picker (the
        // Repository/Hooks segmented control) can render as a black pill with
        // an invisible label in these captures. The vibrant control draws
        // fine in a real window; `cacheDisplay` is what drops it. Check the
        // running app before treating it as a product defect.
        // A presented sheet is its own window, and is what should be captured
        // rather than the dimmed window behind it. `keyWindow` is nil when the
        // app was launched without being activated, so check for a sheet first.
        if environmentFlag("SWIFTRESTIC_CAPTURE_VERBOSE") {
            for window in NSApp.windows {
                debugLog(
                    "capture: \(type(of: window)) title=\"\(window.title)\" frame=\(window.frame) sheet=\(window.isSheet) visible=\(window.isVisible) key=\(window.isKeyWindow)"
                )
            }
        }
        // Sheets that are real content, not the tiny helper windows AppKit
        // creates for tooltips and popovers.
        let candidate = NSApp.windows.first(where: {
            $0.isSheet && $0.isVisible && $0.frame.width > 200 && $0.frame.height > 200
        })
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        guard let window = candidate,
              // The frame view, not the content view: the toolbar lives in the
              // title bar and would otherwise be missing from the capture.
              let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
#endif

@main
struct SwiftResticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    private static let mainWindowID = "main"

    var body: some Scene {
        // `Window`, not `WindowGroup`: a group is multi-instance, so the menu
        // bar's "Open SwiftRestic" would add a second identical window every time
        // instead of bringing the existing one forward.
        Window("SwiftRestic", id: Self.mainWindowID) {
            RootView()
                .environment(model)
                .frame(minWidth: 940, minHeight: 600)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // ⌘N is macOS's reflex for "new thing" — an emptied group here
            // meant adding a repository was always a mouse trip to the sidebar
            // footer. RootView owns the sheets and ignores these while a sheet
            // is already up.
            CommandGroup(replacing: .newItem) {
                Button("New Backup Plan…") {
                    NotificationCenter.default.post(name: .swiftResticNewPlan, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.configuration.repositories.isEmpty)

                Button("Add Repository…") {
                    NotificationCenter.default.post(name: .swiftResticNewRepository, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .help) {
                Button("SwiftRestic Concepts…") {
                    NotificationCenter.default.post(name: .swiftResticShowConcepts, object: nil)
                }
                Divider()
                Button("restic Documentation") {
                    NSWorkspace.shared.open(URL(string: "https://restic.readthedocs.io")!)
                }
                Button("restic Change Log") {
                    NSWorkspace.shared.open(URL(string: "https://restic.readthedocs.io/en/stable/changelog.html")!)
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
                    NotificationCenter.default.post(name: .swiftResticRunSelected, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                // The handler in RootView no-ops when the selection is not a
                // runnable plan; an enabled menu item over a disabled action
                // is a menu that lies.
                .disabled(!model.canRunSelectedPlan)

                Button("Find Files in Snapshots…") {
                    NotificationCenter.default.post(name: .swiftResticShowFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Refresh Snapshots") {
                    Task { await model.refreshAllSnapshots() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(
            get: { model.configuration.settings.showMenuBarExtra },
            set: { newValue in
                // Must not write unconditionally. `configuration` publishes on
                // every assignment, SwiftUI re-evaluates the scene, writes the
                // same value back, and the main thread spins forever — which
                // also starves every continuation hopping to the main actor.
                guard model.configuration.settings.showMenuBarExtra != newValue else { return }
                model.configuration.settings.showMenuBarExtra = newValue
            }
        )) {
            MenuBarContentView(mainWindowID: Self.mainWindowID)
                .environment(model)
        } label: {
            Image(systemName: model.activity.isEmpty ? "clock.arrow.circlepath" : "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.menu)
    }
}
