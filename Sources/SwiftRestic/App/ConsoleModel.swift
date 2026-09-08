import Foundation
import Observation

/// One confirmed-destructive console command, kept with its arguments so the
/// dialog shows — and the history records — exactly what was armed.
struct PendingCommand {
    let arguments: [String]
    let text: String
}

/// State of the restic console pane.
///
/// Owned by `AppModel` rather than the view. The console used to be a sheet
/// that kept its state in the view, so switching panes would have cancelled a
/// running restic process and thrown its output away; as a first-class pane
/// it must survive both. Only quitting cancels, via `AppModel.shutdown`.
@MainActor
@Observable
final class ConsoleModel {
    var repositoryID: UUID?
    var commandText = "snapshots --compact"
    private(set) var output = ""
    private(set) var isRunning = false
    /// Newest first, as typed — what the history sidebar offers back.
    private(set) var history: [String] = []
    /// The command waiting on its destructive-confirmation dialog, with the
    /// text as it was when armed — the field stays editable while the dialog
    /// is up, and the history must record what was confirmed, not what got
    /// typed afterwards.
    var pendingDestructive: PendingCommand?
    private var runTask: Task<Void, Never>?

    func appear(with app: AppModel) {
        if repositoryID == nil { repositoryID = app.configuration.repositories.first?.id }
        // History outlives the pane: it lives in the configuration, so a
        // command that worked is still here next week.
        history = app.configuration.settings.consoleHistory
    }

    var canRun: Bool {
        repositoryID != nil && !isRunning
            && !CommandLineTokenizer.tokenize(commandText).isEmpty
    }

    func run(with app: AppModel) {
        let arguments = CommandLineTokenizer.tokenize(commandText)
        guard !arguments.isEmpty, repositoryID != nil else { return }
        if CommandLineTokenizer.isDestructive(arguments) {
            pendingDestructive = PendingCommand(arguments: arguments, text: commandText)
        } else {
            execute(arguments, record: commandText, app: app)
        }
    }

    func confirmPending(app: AppModel) {
        guard let pending = pendingDestructive else { return }
        pendingDestructive = nil
        execute(pending.arguments, record: pending.text, app: app)
    }

    func cancelPending() {
        pendingDestructive = nil
    }

    func removeFromHistory(_ entry: String, app: AppModel) {
        history.removeAll { $0 == entry }
        persistHistory(in: app)
    }

    /// Stops a running command. The in-flight task still unwinds naturally —
    /// `runConsoleCommand` answers the cancellation with its own message, and
    /// the pane shows it.
    func cancelRunningCommand() {
        runTask?.cancel()
    }

    /// Waits for an in-flight command, so tests can observe settled state.
    func waitForCommand() async {
        await runTask?.value
    }

    private func execute(_ arguments: [String], record entry: String, app: AppModel) {
        guard let repositoryID, !isRunning else { return }
        isRunning = true
        output = "Running…"
        runTask = Task { [weak self] in
            let result = await app.runConsoleCommand(
                repositoryID: repositoryID,
                arguments: arguments
            )
            // No cancellation guard here: `runConsoleCommand` answers a stop
            // with "The operation was cancelled.", and nothing else writes
            // this state while the command runs — the message must reach the
            // pane.
            self?.output = result
            self?.isRunning = false
            self?.runTask = nil
            self?.record(entry, in: app)
        }
    }

    private func record(_ entry: String, in app: AppModel) {
        history.removeAll { $0 == entry }
        history.insert(entry, at: 0)
        history = Array(history.prefix(20))
        persistHistory(in: app)
    }

    /// Sensitive commands stay in this session's sidebar but never reach the
    /// configuration file: it gets rotated and is the first thing attached to
    /// a bug report, and a history miss is a small price next to a stored
    /// secret.
    private func persistHistory(in app: AppModel) {
        app.configuration.settings.consoleHistory = history.filter {
            !Self.mayCarrySecret($0)
        }
    }

    private static func mayCarrySecret(_ command: String) -> Bool {
        let lowered = command.lowercased()
        return lowered.contains("password")
            || lowered.contains("secret")
            || lowered.contains("token")
            || lowered.contains("key add")
            || lowered.contains("key passwd")
    }
}
