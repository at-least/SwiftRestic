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
///
/// The two things it needs from the world — running a command and persisting
/// history — arrive as closures injected by `AppModel` at wiring, so the
/// console carries no back-reference to its owner: it held one for every
/// method once, and every method read the whole model for two lines of it.
/// They cannot be init parameters — the closures capture the owner, and the
/// owner owns this — so an unwired console says so in the output pane
/// instead of dropping a confirmed command on the floor in silence.
@MainActor
@Observable
final class ConsoleModel {
    /// Runs a command against a repository — `AppModel.runConsoleCommand`,
    /// the engine chokepoint, handed over at wiring.
    var runCommand: ((_ repositoryID: UUID, _ arguments: [String]) async -> String)?
    /// Persists the secret-filtered history — the configuration write,
    /// handed over at wiring.
    var persistHistory: (([String]) -> Void)?

    var repositoryID: UUID?
    var commandText = "snapshots --compact"
    private(set) var output = ""
    private(set) var isRunning = false
    /// The repository the in-flight command runs against, captured at submit:
    /// the picker may move on while it runs, and deletion needs the run's own
    /// answer to "would cancelling this still the removed repository's work?".
    private(set) var runningRepositoryID: UUID?
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

    /// The pane's appear moment, driven by `AppModel.consoleDidAppear`:
    /// the model reads its own configuration and hands the values over.
    func appear(repositoryID defaultRepositoryID: UUID?, persistedHistory: [String]) {
        if repositoryID == nil { repositoryID = defaultRepositoryID }
        // The session's history outranks the persisted list once it exists:
        // a secret-carrying command lives only here, and re-reading the
        // filtered list on every pane re-entry would launder it out of the
        // sidebar. A fresh session reads the persisted list; removals persist
        // immediately, so an emptied session stays emptied.
        if history.isEmpty { history = persistedHistory }
        endRecall()
    }

    var canRun: Bool {
        repositoryID != nil && !isRunning
            && !CommandLineTokenizer.tokenize(commandText).isEmpty
    }

    func run() {
        let arguments = CommandLineTokenizer.tokenize(commandText)
        guard !arguments.isEmpty, repositoryID != nil else { return }
        // A shell refuses an unclosed quote; so does the console. Closing it
        // silently would confirm — or run — a mangled argument the user
        // never typed, which is exactly the failure a confirmation exists
        // to prevent.
        if CommandLineTokenizer.hasUnterminatedQuote(commandText) {
            output = "The command ends inside an open quote — close it before running."
            return
        }
        // Submitting ends any recall walk: the field belongs to the user again.
        endRecall()
        if CommandLineTokenizer.isDestructive(arguments) {
            pendingDestructive = PendingCommand(arguments: arguments, text: commandText)
        } else {
            execute(arguments, record: commandText)
        }
    }

    func confirmPending() {
        guard let pending = pendingDestructive else { return }
        pendingDestructive = nil
        execute(pending.arguments, record: pending.text)
    }

    func cancelPending() {
        pendingDestructive = nil
    }

    func removeFromHistory(_ entry: String) {
        history.removeAll { $0 == entry }
        endRecall()
        persist()
    }

    /// The entry ↑ should show: the newest history entry first, then one
    /// older per press, clamped at the oldest. `current` is what the field
    /// holds right now — the draft remembered before the first recall.
    ///
    /// The draft is fixed when the walk starts: edits made to a recalled
    /// entry mid-walk are discarded when ↓ returns to the draft, matching
    /// shell behavior. Submitting, a history-sidebar click, the pane going
    /// away, or the history changing ends the walk.
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

    /// Empties the output pane. A running command's stream owns the pane, so
    /// this waits for stillness rather than fighting it.
    func clearOutput() {
        guard !isRunning else { return }
        output = ""
    }

    /// Waits for an in-flight command, so tests can observe settled state.
    func waitForCommand() async {
        await runTask?.value
    }

    private func execute(_ arguments: [String], record entry: String) {
        guard let repositoryID, !isRunning else { return }
        guard let command = runCommand else {
            output = "The console was not wired to a repository engine — this is a SwiftRestic bug."
            return
        }
        isRunning = true
        runningRepositoryID = repositoryID
        output = "Running…"
        runTask = Task { [weak self] in
            let result = await command(repositoryID, arguments)
            // No cancellation guard here: the runner answers a stop with
            // "The operation was cancelled.", and nothing else writes this
            // state while the command runs — the message must reach the pane.
            self?.output = result
            self?.isRunning = false
            self?.runningRepositoryID = nil
            self?.runTask = nil
            self?.record(entry)
        }
    }

    private func record(_ entry: String) {
        history.removeAll { $0 == entry }
        history.insert(entry, at: 0)
        history = Array(history.prefix(20))
        // An append shifts every index a walk in progress points at; end the
        // walk rather than let ↑ land on a different command than it showed.
        endRecall()
        persist()
    }

    /// Sensitive commands stay in this session's sidebar but never reach the
    /// configuration file: it gets rotated and is the first thing attached to
    /// a bug report, and a history miss is a small price next to a stored
    /// secret.
    private func persist() {
        persistHistory?(history.filter { !Self.mayCarrySecret($0) })
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
