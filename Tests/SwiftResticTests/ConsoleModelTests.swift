import Foundation
import Testing

/// No restic binary is configured, so an executed command settles on the
/// binary-not-found error — that is enough to prove execution happened and
/// its aftermath (output, running flag, history) was recorded.
@Suite("Console pane model")
@MainActor
struct ConsoleModelTests {
    /// A model with no restic override and an isolated config directory, so
    /// nothing touches the login Keychain or a real configuration.
    private func makeHarness() throws -> (app: AppModel, console: ConsoleModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticConsole-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel(
            store: ConfigStore(directory: root.appendingPathComponent("config")),
            secrets: .inMemory()
        )
        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        app.configuration.repositories = [repository]
        return (app, app.console, root)
    }

    @Test("a route points the console at its repository; the pane's appear does not take it back")
    func routeChoosesTheRepository() throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = Repository()
        app.configuration.repositories.append(other)
        app.consoleDidAppear()
        #expect(console.repositoryID == app.configuration.repositories.first?.id)
        app.pointConsole(at: other.id)
        app.consoleDidAppear()
        #expect(console.repositoryID == other.id)
    }

    @Test("a destructive command arms a confirmation instead of running")
    func destructiveArms() throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        console.commandText = "prune"

        console.run()

        #expect(console.pendingDestructive != nil)
        #expect(!console.isRunning)
        #expect(console.output.isEmpty)
        console.cancelPending()
        #expect(console.pendingDestructive == nil)
        #expect(console.output.isEmpty)
    }

    @Test("Return while a command runs arms nothing: a confirmed command would have nowhere to run")
    func submitWhileRunningArmsNothing() async throws {
        let console = ConsoleModel()
        console.persistHistory = { _ in }
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        console.runCommand = { _, _ in
            startedSignal.yield()
            for await _ in release { break }
            return "done"
        }
        console.repositoryID = UUID()
        console.commandText = "snapshots"
        console.run()
        for await _ in started { break }
        #expect(console.isRunning)

        console.commandText = "forget abc"
        console.run()
        #expect(console.pendingDestructive == nil)
        console.commandText = #"ls "open"#
        console.run()
        #expect(console.output == "Running…")

        releaseSignal.yield()
        await console.waitForCommand()
        #expect(console.output == "done")
    }

    @Test("a line ending inside an open quote is refused, not run mangled")
    func unterminatedQuoteIsRefused() throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        console.commandText = "snapshots --compact"

        console.run()
        await console.waitForCommand()

        #expect(console.pendingDestructive == nil)
        #expect(console.history.first == "snapshots --compact")
    }

    @Test("secret-bearing commands reach the session's history but not the configuration")
    func secretFilter() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
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
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        // Secret-carrying but non-destructive, so seedHistory's plain run()
        // executes it: `key …` would only arm the confirmation.
        await seedHistory(["snapshots", "snapshots --password-file secret.txt"], console: console)
        #expect(console.history.count == 2)
        #expect(app.configuration.settings.consoleHistory == ["snapshots"])

        // Leave the pane and come back: the session's own history — secret
        // included — is what the sidebar shows, not the shorter persisted
        // list. Overwriting it here would launder the command away.
        app.consoleDidAppear()
        #expect(console.history == ["snapshots --password-file secret.txt", "snapshots"])
    }

    @Test("removing a history entry removes it from both surfaces")
    func removeFromHistory() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        console.commandText = "snapshots"
        console.run()
        await console.waitForCommand()

        console.removeFromHistory("snapshots")

        #expect(console.history.isEmpty)
        #expect(app.configuration.settings.consoleHistory.isEmpty)
    }

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
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        await seedHistory(["snapshots --compact", "version"], console: console)
        #expect(console.history.first == "version")

        #expect(console.recallPrevious(current: "ls") == "version")
        #expect(console.recallPrevious(current: "version") == "snapshots --compact")
        #expect(console.recallPrevious(current: "snapshots --compact") == "snapshots --compact")

        #expect(console.recallNext() == "version")
        #expect(console.recallNext() == "ls")
        #expect(console.recallNext() == nil)
    }

    @Test("submitting a command ends the recall walk")
    func submittingEndsRecall() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        await seedHistory(["version"], console: console)

        #expect(console.recallPrevious(current: "ls") == "version")
        console.commandText = "version"
        console.run()
        await console.waitForCommand()

        #expect(console.recallNext() == nil)
        #expect(console.recallPrevious(current: console.commandText) == "version")
    }

    @Test("an empty history has nothing to recall")
    func emptyHistoryRecallsNothing() throws {
        let (_, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(console.recallPrevious(current: "ls") == nil)
        #expect(console.recallNext() == nil)
    }
}

extension ConsoleModelTests {
    @Test("a pane re-entry ends an in-flight recall walk and keeps the session's history")
    func appearEndsRecallWalk() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        // Two of the three commands carry secrets, so the persisted list is
        // shorter than the session's history.
        await seedHistory(["aaa", "password one", "password two"], console: console)
        #expect(console.history.count == 3)

        #expect(console.recallPrevious(current: "draft") != nil)
        #expect(console.recallPrevious(current: "") != nil)
        #expect(console.recallPrevious(current: "") != nil)

        app.consoleDidAppear()
        #expect(console.recallNext() == nil)
        #expect(console.history == ["password two", "password one", "aaa"])
    }

    @Test("a history-sidebar click ends an in-flight recall walk and shows the entry")
    func pickingFromHistoryEndsTheRecallWalk() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        await seedHistory(["snapshots --compact", "version"], console: console)

        #expect(console.recallPrevious(current: "ls") == "version")

        console.pickFromHistory("snapshots --compact")
        #expect(console.commandText == "snapshots --compact")
        #expect(console.recallNext() == nil)
    }

    @Test("a running command's stream owns the output pane, so Clear waits for stillness")
    func clearOutputWaitsForStillness() async throws {
        let console = ConsoleModel()
        console.persistHistory = { _ in }
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        console.runCommand = { _, _ in
            startedSignal.yield()
            for await _ in release { break }
            return "done"
        }
        console.repositoryID = UUID()
        console.commandText = "snapshots"
        console.run()
        for await _ in started { break }
        #expect(console.output == "Running…")

        console.clearOutput()
        #expect(console.output == "Running…", "a running command's stream owns the pane")

        releaseSignal.yield()
        await console.waitForCommand()
        console.clearOutput()
        #expect(console.output == "")
    }
}
