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
        console.appear(with: app)
        console.commandText = "prune"

        console.run(with: app)

        #expect(console.pendingDestructive != nil)
        #expect(!console.isRunning)
        #expect(console.output.isEmpty)
        // Cancelling the dialog clears the arm without executing anything.
        console.cancelPending()
        #expect(console.pendingDestructive == nil)
        #expect(console.output.isEmpty)
    }

    @Test("confirming a destructive command runs it and records the history")
    func confirmationRuns() async throws {
        let (app, console, _) = try makeHarness()
        console.appear(with: app)
        console.commandText = "prune"
        console.run(with: app)
        guard console.pendingDestructive != nil else {
            Issue.record("expected the command to arm a confirmation")
            return
        }

        console.confirmPending(app: app)
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
        console.appear(with: app)
        console.commandText = "snapshots --compact"

        console.run(with: app)
        await console.waitForCommand()

        #expect(console.pendingDestructive == nil)
        #expect(console.history.first == "snapshots --compact")
    }

    @Test("secret-bearing commands reach the session's history but not the configuration")
    func secretFilter() async throws {
        let (app, console, _) = try makeHarness()
        console.appear(with: app)
        console.commandText = "key add new-key"
        // `key` is a destructive subcommand, so it arms first.
        console.run(with: app)
        console.confirmPending(app: app)
        await console.waitForCommand()

        #expect(console.history.first == "key add new-key")
        #expect(app.configuration.settings.consoleHistory.isEmpty)
    }

    @Test("re-running a command moves it to the top instead of duplicating it")
    func historyDeduplicates() async throws {
        let (app, console, _) = try makeHarness()
        console.appear(with: app)
        console.commandText = "snapshots"
        console.run(with: app)
        await console.waitForCommand()
        console.commandText = "version"
        console.run(with: app)
        await console.waitForCommand()
        console.commandText = "snapshots"
        console.run(with: app)
        await console.waitForCommand()

        #expect(console.history == ["snapshots", "version"])
    }

    @Test("removing a history entry removes it from both surfaces")
    func removeFromHistory() async throws {
        let (app, console, _) = try makeHarness()
        console.appear(with: app)
        console.commandText = "snapshots"
        console.run(with: app)
        await console.waitForCommand()

        console.removeFromHistory("snapshots", app: app)

        #expect(console.history.isEmpty)
        #expect(app.configuration.settings.consoleHistory.isEmpty)
    }
}
