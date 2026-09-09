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
    /// Where ↑/↓ are walking in `history`. `nil` means the field shows the
    /// user's own words, not a recalled entry.
    private var historyIndex: Int?
    /// What the field held when the recall walk started, so ↓ past the newest
    /// entry returns to the user's draft instead of an empty field.
    private var recalledDraft: String?
    private var runTask: Task<Void, Never>?

    func appear(with app: AppModel) {
        if repositoryID == nil { repositoryID = app.configuration.repositories.first?.id }
        // History outlives the pane: it lives in the configuration, so a
        // command that worked is still here next week. It is also the
        // secret-filtered list, which can be shorter than the session's —
        // an in-progress walk's index would point past it, so the walk ends.
        history = app.configuration.settings.consoleHistory
        endRecall()
    }

    var canRun: Bool {
        repositoryID != nil && !isRunning
            && !CommandLineTokenizer.tokenize(commandText).isEmpty
    }

    func run(with app: AppModel) {
        let arguments = CommandLineTokenizer.tokenize(commandText)
        guard !arguments.isEmpty, repositoryID != nil else { return }
        // Submitting ends any recall walk: the field belongs to the user again.
        endRecall()
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
        endRecall()
        persistHistory(in: app)
    }

    /// The entry ↑ should show: the newest history entry first, then one
    /// older per press, clamped at the oldest. `current` is what the field
    /// holds right now — the draft remembered before the first recall.
    func recallPrevious(current: String) -> String? {
        guard !history.isEmpty else { return nil }
        if let index = historyIndex {
            historyIndex = min(index + 1, history.count - 1)
        } else {
            recalledDraft = current
            historyIndex = 0
        }
        return history[historyIndex!]
    }

    /// The entry ↓ should show: one step newer per press, and past the newest
    /// back to the draft the field held when the walk started.
    func recallNext() -> String? {
        // A history shorter than the index it was walked with (the persisted
        // list drops secrets) ends the walk rather than indexing past it.
        guard let index = historyIndex, index < history.count else {
            endRecall()
            return nil
        }
        if index == 0 {
            let draft = recalledDraft
            endRecall()
            return draft
        }
        historyIndex = index - 1
        return history[historyIndex!]
    }

    /// History-sidebar click: the user chose a command, so any walk ends and
    /// the field shows the entry.
    func pickFromHistory(_ entry: String) {
        endRecall()
        commandText = entry
    }

    private func endRecall() {
        historyIndex = nil
        recalledDraft = nil
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
        // An append shifts every index a walk in progress points at; end the
        // walk rather than let ↑ land on a different command than it showed.
        endRecall()
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
