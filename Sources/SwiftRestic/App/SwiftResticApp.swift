import AppKit
import ScreenCaptureKit
import SwiftUI

/// The app stays resident behind its menu bar item, so quitting is the only
/// moment we are guaranteed to get — pending saves must be flushed and any
/// running restic terminated before the process goes away.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            // The tray is AppKit-owned (see TrayStatusItem for why); it is
            // created once, when the model first reaches the delegate.
            guard oldValue == nil, let model else { return }
            tray = TrayStatusItem(model: model)
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
}

#if DEBUG
extension AppDelegate {
    /// Debug-only: write PNG(s) of the main window, then quit.
    ///
    /// The preferred backend is ScreenCaptureKit, which renders Tahoe's glass
    /// materials correctly but needs a one-time Screen Recording grant;
    /// `cacheDisplay` is the permission-free fallback and draws those
    /// materials black on macOS 26. Which backend produced a given shot is
    /// logged, so a black capture is never silent. The fallback keeps the
    /// sweep usable from a terminal session or CI.
    func scheduleDebugCapture() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SWIFTRESTIC_CAPTURE"], !path.isEmpty else { return }
        let delay = Double(environment["SWIFTRESTIC_CAPTURE_DELAY"] ?? "") ?? 6
        let capturesAllPanes = environment["SWIFTRESTIC_CAPTURE_PANE"] == "all"

        if environmentFlag("SWIFTRESTIC_CAPTURE_VERBOSE") {
            Task { @MainActor in
                var last = ""
                while true {
                    let now = NSApp.windows.map { "\(type(of: $0))[\($0.title)] \($0.frame.size) visible=\($0.isVisible)" }
                        .joined(separator: " | ")
                    if now != last {
                        Self.debugLog("windows @\(Int(Date.timeIntervalSinceReferenceDate)): \(now)")
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
            if capturesAllPanes {
                await captureAllPanes(into: URL(fileURLWithPath: path), settlingFor: .seconds(delay))
            } else {
                await captureMainWindow(to: URL(fileURLWithPath: path))
            }
            // `NSApp.terminate` never reaches `applicationShouldTerminate` from
            // this unactivated, sheet-bearing debug launch, so shut the model
            // down directly and exit: this path exists only for captures.
            Self.debugLog("captured; shutting down")
            await model?.shutdown()
            Self.debugLog("shutdown finished; exiting")
            exit(0)
        }
    }

    /// `SWIFTRESTIC_CAPTURE_PANE=all`: photographs every sidebar pane into the
    /// `SWIFTRESTIC_CAPTURE` directory as `pane-<name>.png`, quitting when the
    /// sweep is done. `SWIFTRESTIC_CAPTURE_DELAY` is the settle time per pane
    /// (and the initial wait for launch/bootstrap).
    ///
    /// The per-pane sweep exists because whole-window regressions show up on
    /// panes nobody was just then looking at — the macOS 26 displaced
    /// title-bar material floated over every pane but was only ever checked
    /// where a change had been made.
    private func captureAllPanes(into directory: URL, settlingFor settle: Duration) async {
        guard let model else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var stops: [(name: String, select: () async -> Void)] = [
            ("overview", { model.sidebarSelection = .overview }),
        ]
        if let plan = model.configuration.plans.first {
            stops.append(("plan", { model.sidebarSelection = .plan(plan.id) }))
        }
        if let repository = model.configuration.repositories.first {
            stops.append(("repository", { model.sidebarSelection = .repository(repository.id) }))
            // The restore pane needs record rows, which only exist after a
            // listing; the same first-expand rule the sidebar uses.
            if model.snapshots(for: repository.id).isEmpty {
                await model.refreshSnapshots(repositoryID: repository.id)
            }
            if let latest = model.snapshots(for: repository.id).first {
                stops.append(("restore", { model.sidebarSelection = .restoreSnapshot(repository.id, latest.id) }))
            }
        }
        stops.append(("console", { model.sidebarSelection = .console }))
        stops.append(("activity", { model.sidebarSelection = .activity }))

        for stop in stops {
            await stop.select()
            try? await Task.sleep(for: settle)
            await wakeDisplayForCapture()
            await captureMainWindow(to: directory.appendingPathComponent("pane-\(stop.name).png"))
            Self.debugLog("captured pane-\(stop.name).png")
        }
    }

    /// `cacheDisplay` needs the window server to resolve Tahoe's glass
    /// materials, which an asleep display interrupts; `caffeinate -u` asserts
    /// user activity, which wakes the display, before each shot. Debug-only
    /// and best-effort — a failed wake still produces a capture, just
    /// possibly a black one. Async: blocking the main actor here would stall
    /// the very render the shot needs.
    private func wakeDisplayForCapture() async {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        task.arguments = ["-u", "-t", "2"]
        try? task.run()
        try? await Task.sleep(for: .seconds(1))
    }

    /// Nonisolated: writes one line to stderr, and the capture paths below
    /// log from the nonisolated ScreenCaptureKit domain.
    nonisolated static func debugLog(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func environmentFlag(_ name: String) -> Bool {
        ProcessInfo.processInfo.environment[name].map { !$0.isEmpty } ?? false
    }

    private func captureMainWindow(to url: URL) async {
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
                Self.debugLog(
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
        guard let window = candidate else { return }
        guard let data = await bestEffortPNG(of: window) else { return }
        try? data.write(to: url)
    }

    /// ScreenCaptureKit renders Tahoe's glass materials correctly;
    /// `cacheDisplay` draws them black on macOS 26 (the whole detail column
    /// photographs as black). SC is therefore preferred, but it needs Screen
    /// Recording authorisation — which a fresh checkout, an SSH session or a
    /// CI runner does not have, and a prompt nobody answers must not hang the
    /// sweep. The SC task is therefore polled on a real leash: once the leash
    /// runs out the task is cancelled and left behind, and the permission-free
    /// fallback photographs the pane — logged, so a black shot names its
    /// backend.
    private func bestEffortPNG(of window: NSWindow) async -> Data? {
        let windowID = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor

        if #available(macOS 14.0, *) {
            // A lock-guarded box carries the SC result out: the SC task may
            // ignore cancellation once a system prompt is up, so the leash
            // abandons it rather than waiting, and cacheDisplay photographs
            // the pane while the orphan settles.
            let box = CaptureResultBox()
            let scCapture = Task.detached(priority: .userInitiated) {
                let data = try? await Self.screenCaptureKitPNG(windowID: windowID, scale: scale)
                box.store(data)
            }
            var settled = false
            var waited = 0.0
            while waited < 6 {
                try? await Task.sleep(for: .seconds(0.5))
                waited += 0.5
                guard let data = box.load() else { continue }
                settled = true
                if let data, !data.isEmpty {
                    Self.debugLog("capture backend: ScreenCaptureKit")
                    return data
                }
                Self.debugLog("capture backend: ScreenCaptureKit failed — cacheDisplay fallback")
                break
            }
            if !settled {
                scCapture.cancel()
                Self.debugLog("capture backend: ScreenCaptureKit timed out — cacheDisplay fallback")
            }
        }

        // The frame view, not the content view: the toolbar lives in the
        // title bar and would otherwise be missing from the capture.
        guard let view = window.contentView?.superview ?? window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        Self.debugLog("capture backend: cacheDisplay")
        return representation.representation(using: .png, properties: [:])
    }

    /// Lock-guarded slot for the ScreenCaptureKit task's result: `nil` means
    /// "not settled yet", a stored `nil` means "settled and failed".
    private final class CaptureResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data??

        func store(_ data: Data?) {
            lock.lock(); defer { lock.unlock() }
            value = .some(data)
        }

        func load() -> Data?? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    /// Sendable confinement for the ScreenCaptureKit snapshot: older SDKs
    /// (macOS 15, what CI compiles against) do not annotate
    /// `SCShareableContent` as Sendable, so the async class method's result
    /// cannot cross back into the caller's isolation unboxed. The content
    /// is an immutable snapshot of the window list, so boxing it right where
    /// it is fetched — before the only send — is honest.
    private final class ShareableContentBox: @unchecked Sendable {
        let content: SCShareableContent
        init(_ content: SCShareableContent) { self.content = content }
    }

    /// Nonisolated like its only caller: the fetch and the boxing stay in
    /// the same domain as the class method, so the non-Sendable snapshot
    /// never crosses isolation — which older SDKs (macOS 15) reject as a
    /// compile error. Only the Sendable box travels back.
    private nonisolated static func shareableContentBox() async throws -> ShareableContentBox {
        ShareableContentBox(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
    }

    /// Own-window capture through ScreenCaptureKit. macOS 26 requires the
    /// app to hold Screen Recording authorisation for this even for its own
    /// window; unauthorised calls fail (after showing the system prompt on
    /// interactive runs) and the caller falls back to `cacheDisplay`.
    ///
    /// Nonisolated: the ScreenCaptureKit objects (`SCShareableContent`,
    /// `SCContentFilter`) are non-Sendable snapshots, and older SDKs reject
    /// sending them across the MainActor boundary at every await. Working
    /// in the nonisolated domain keeps fetch, filter and screenshot in one
    /// place; only the `Data` — plain bytes — travels back.
    @available(macOS 14.0, *)
    private nonisolated static func screenCaptureKitPNG(windowID: CGWindowID, scale: CGFloat) async throws -> Data? {
        let content = try await shareableContentBox().content
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            Self.debugLog("capture backend: ScreenCaptureKit found no window \(windowID) on screen")
            return nil
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(scWindow.frame.width * scale)
        configuration.height = Int(scWindow.frame.height * scale)
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }
}
#endif

@main
struct SwiftResticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

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
                    // Through the model, not a notification: the intent has to
                    // survive the window being closed. The command also opens
                    // the window, like the tray's identical button — a menu
                    // command that visibly does nothing is a dead key, and an
                    // unexpired intent would ambush whatever opens the window
                    // later for other reasons.
                    model.pendingNewRepository = true
                    openWindow(id: Self.mainWindowID)
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
