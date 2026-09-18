import Foundation
import Testing

/// The console pane's model: arming destructive commands, the confirmation
/// round trip, and the history's secret filter.
///
/// No restic binary is configured, so an executed command settles on the
/// binary-not-found error — that is enough to prove execution happened and
/// its aftermath (output, running flag, history) was recorded.
@Suite("Console pane model")
@MainActor
struct ConsoleModelTests {
    /// A model with no restic override and an isolated config directory, so
    /// nothing touches the login Keychain or a real configuration. One local
    /// repository exists for the console to target; the missing binary means
    /// an executed command settles on the not-found error.
    private func makeHarness() throws -> (app: AppModel, console: ConsoleModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticConsole-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(
            store: ConfigStore(directory: root.appendingPathComponent("config")),
            secrets: .inMemory()
        )
        var repository = Repository()
        repository.name = "Console Repo"
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        app.configuration.repositories = [repository]
        return (app, app.console, root)
    }

    @Test("a destructive command arms a confirmation instead of running")
    func destructiveArms() throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "prune"

        console.run()

        #expect(console.pendingDestructive != nil)
        #expect(!console.isRunning)
        #expect(console.output.isEmpty)
        // Cancelling the dialog clears the arm without executing anything.
        console.cancelPending()
        #expect(console.pendingDestructive == nil)
        #expect(console.output.isEmpty)
    }

    @Test("a line ending inside an open quote is refused, not run mangled")
    func unterminatedQuoteIsRefused() throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = #"forget --keep-daily "7"#

        console.run()

        // A shell would refuse this line; closing the quote silently would
        // arm — and confirm — a mangled argument. Nothing may run or arm.
        #expect(console.pendingDestructive == nil)
        #expect(!console.isRunning)
        #expect(console.output.contains("open quote"))
    }

    @Test("confirming a destructive command runs it and records the history")
    func confirmationRuns() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "prune"
        console.run()
        guard console.pendingDestructive != nil else {
            Issue.record("expected the command to arm a confirmation")
            return
        }

        console.confirmPending()
        await console.waitForCommand()

        #expect(console.output != "Running…")
        #expect(!console.output.isEmpty)
        #expect(!console.isRunning)
        #expect(console.history.first == "prune")
        // The pruned command carries no secret, so it reaches the
        // configuration for future sessions too.
        #expect(app.configuration.settings.consoleHistory.first == "prune")
        #expect(console.pendingDestructive == nil)
    }

    @Test("a non-destructive command runs without confirmation")
    func plainCommandRuns() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "snapshots --compact"

        console.run()
        await console.waitForCommand()

        #expect(console.pendingDestructive == nil)
        #expect(console.history.first == "snapshots --compact")
    }

    @Test("secret-bearing commands reach the session's history but not the configuration")
    func secretFilter() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "key add new-key"
        // `key` is a destructive subcommand, so it arms first.
        console.run()
        console.confirmPending()
        await console.waitForCommand()

        #expect(console.history.first == "key add new-key")
        #expect(app.configuration.settings.consoleHistory.isEmpty)
    }

    @Test("re-running a command moves it to the top instead of duplicating it")
    func historyDeduplicates() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "snapshots"
        console.run()
        await console.waitForCommand()
        console.commandText = "version"
        console.run()
        await console.waitForCommand()
        console.commandText = "snapshots"
        console.run()
        await console.waitForCommand()

        #expect(console.history == ["snapshots", "version"])
    }

    @Test("a pane re-entry keeps the session's history, secrets included")
    func appearKeepsSessionHistory() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        // Secret-carrying but non-destructive, so seedHistory's plain run()
        // executes it: `key …` would only arm the confirmation.
        await seedHistory(["snapshots", "snapshots --password-file secret.txt"], console: console)
        #expect(console.history.count == 2)
        // The secret-carrying command reached the session's sidebar only.
        #expect(app.configuration.settings.consoleHistory == ["snapshots"])

        // Leave the pane and come back: the session's own history — secret
        // included — is what the sidebar shows, not the shorter persisted
        // list. Overwriting it here would launder the command away.
        app.consoleDidAppear()
        #expect(console.history == ["snapshots --password-file secret.txt", "snapshots"])
    }

    @Test("removing a history entry removes it from both surfaces")
    func removeFromHistory() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        console.commandText = "snapshots"
        console.run()
        await console.waitForCommand()

        console.removeFromHistory("snapshots")

        #expect(console.history.isEmpty)
        #expect(app.configuration.settings.consoleHistory.isEmpty)
    }

    // MARK: - Arrow recall

    /// Seeds history through real runs, the only writer the model allows.
    private func seedHistory(_ commands: [String], console: ConsoleModel) async {
        for command in commands {
            console.commandText = command
            console.run()
            await console.waitForCommand()
        }
    }

    @Test("↑ walks the history newest first and clamps at the oldest; ↓ returns to the draft")
    func arrowRecallWalksHistoryAndReturnsToDraft() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        await seedHistory(["snapshots --compact", "version"], console: console)
        #expect(console.history.first == "version")

        // ↑ from a typed draft takes the newest entry, then walks older…
        #expect(console.recallPrevious(current: "ls") == "version")
        #expect(console.recallPrevious(current: "version") == "snapshots --compact")
        // …and clamps at the oldest instead of wrapping.
        #expect(console.recallPrevious(current: "snapshots --compact") == "snapshots --compact")

        // ↓ walks back toward the field's own words.
        #expect(console.recallNext() == "version")
        #expect(console.recallNext() == "ls")
        // With nothing recalled, ↓ has nothing to offer.
        #expect(console.recallNext() == nil)
    }

    @Test("submitting a command ends the recall walk")
    func submittingEndsRecall() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        await seedHistory(["version"], console: console)

        #expect(console.recallPrevious(current: "ls") == "version")
        console.commandText = "version"
        console.run()
        await console.waitForCommand()

        // The walk is over: ↓ must not conjure a recalled entry.
        #expect(console.recallNext() == nil)
        // And ↑ starts fresh from the newest entry again.
        #expect(console.recallPrevious(current: console.commandText) == "version")
    }

    @Test("an empty history has nothing to recall")
    func emptyHistoryRecallsNothing() throws {
        let (_, console, _) = try makeHarness()
        #expect(console.recallPrevious(current: "ls") == nil)
        #expect(console.recallNext() == nil)
    }
}

extension ConsoleModelTests {
    @Test("a pane re-entry ends an in-flight recall walk and keeps the session's history")
    func appearEndsRecallWalk() async throws {
        let (app, console, _) = try makeHarness()
        app.consoleDidAppear()
        // Two of the three commands carry secrets, so the persisted list is
        // shorter than the session's history.
        await seedHistory(["aaa", "password one", "password two"], console: console)
        #expect(console.history.count == 3)

        // Walk to the oldest entry, index 2.
        #expect(console.recallPrevious(current: "draft") != nil)
        #expect(console.recallPrevious(current: "") != nil)
        #expect(console.recallPrevious(current: "") != nil)

        // The pane is left and revisited: the walk is over — ↓ must not
        // conjure a recalled entry — and the session's history survives
        // whole, secrets included. (Newest first, as typed.)
        app.consoleDidAppear()
        #expect(console.recallNext() == nil)
        #expect(console.history == ["password two", "password one", "aaa"])
    }
}
