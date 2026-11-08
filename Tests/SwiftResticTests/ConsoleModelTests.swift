import Foundation
import Testing

/// restic is never checked, so an executed command settles on the
/// damaged-install error: enough to prove execution happened and its
/// aftermath (output, running flag, history) was recorded.
@Suite("Console pane model")
@MainActor
struct ConsoleModelTests {
    /// A model with an isolated config directory, so
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

    @Test("`self-update` is refused in any position, and restic is never run: it would overwrite the signed bundled binary")
    func selfUpdateIsRefused() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticSelfUpdate-\(UUID().uuidString)-ran")
        let program = try writeExecutableScript("touch '\(marker.path)'", label: "SelfUpdate", named: "restic")
        let root = program.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        let app = AppModel(
            store: ConfigStore(directory: root.appendingPathComponent("config")),
            secrets: .inMemory([repository.id: (password: "p", providerSecret: nil)]), resticExecutable: program
        )
        app.resticState = .ready(ResticBinary(url: program), version: "")
        app.configuration.repositories = [repository]
        for arguments in [["self-update"], ["--verbose", "self-update", "--output", "/tmp/x"]] {
            let output = await app.runConsoleCommand(repositoryID: repository.id, arguments: arguments)
            #expect(output == "restic updates come with SwiftRestic.")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
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
    @Test("the window opening again ends an in-flight recall walk and keeps the session's history")
    func appearEndsRecallWalk() async throws {
        let (app, console, root) = try makeHarness()
        defer { try? FileManager.default.removeItem(at: root) }
        app.consoleDidAppear()
        await seedHistory(["aaa", "password one", "password two"], console: console)
        #expect(console.history.count == 3)

        #expect(console.recallPrevious(current: "draft") != nil)
        #expect(console.recallPrevious(current: "") != nil)
        #expect(console.recallPrevious(current: "") != nil)

        app.consoleDidAppear()
        #expect(console.recallNext() == nil)
        #expect(console.history == ["password two", "password one", "aaa"])
    }

    @Test("a running command's stream owns the output pane, so Clear waits for stillness")
    func clearOutputWaitsForStillness() async throws {
        let console = ConsoleModel()
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
