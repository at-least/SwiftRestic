import Foundation
import Observation

/// One confirmed-destructive console command, kept with its arguments so the
/// dialog shows — and the history records — exactly what was armed.
struct PendingCommand {
    let arguments: [String]
    let text: String
}

/// Owned by `AppModel` rather than the window: closing the window cancels
/// nothing; a running command ends by its Stop button, its repository's
/// deletion, or quitting (`AppModel.shutdown`).
///
/// `runCommand` arrives as a closure injected by `AppModel` at wiring, so the
/// console carries no back-reference to its owner. It cannot be an init
/// parameter — it captures the owner, and the owner owns this — so an unwired
/// console traps rather than drop a confirmed command.
@MainActor
@Observable
final class ConsoleModel {
    var runCommand: (_ repositoryID: UUID, _ arguments: [String]) async -> String = { _, _ in
        preconditionFailure("the console was never wired")
    }

    var repositoryID: UUID?
    var commandText = "snapshots --compact"
    private(set) var output = ""
    private(set) var isRunning = false
    /// The repository the in-flight command runs against, captured at submit:
    /// another location's Repair… may point the console elsewhere while it
    /// runs, and deletion needs the run's own
    /// answer to "would cancelling this still the removed repository's work?".
    private(set) var runningRepositoryID: UUID?
    /// Newest first, as typed, for this session only — what ↑ and ↓ walk.
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

    func appear(repositoryID defaultRepositoryID: UUID?) {
        if repositoryID == nil { repositoryID = defaultRepositoryID }
        endRecall()
    }

    var canRun: Bool {
        repositoryID != nil && !isRunning
            && !CommandLineTokenizer.tokenize(commandText).isEmpty
    }

    func run() {
        // The Run button's own gate: the field's Return submits while a
        // command runs, and a confirmation armed then would have nowhere to
        // run.
        guard canRun else { return }
        let arguments = CommandLineTokenizer.tokenize(commandText)
        // A shell refuses an unclosed quote; so does the console. Closing it
        // silently would confirm — or run — a mangled argument the user
        // never typed, which is exactly the failure a confirmation exists
        // to prevent.
        if CommandLineTokenizer.hasUnterminatedQuote(commandText) {
            output = "The command ends inside an open quote — close it before running."
            return
        }
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

    /// The entry ↑ should show: the newest history entry first, then one
    /// older per press, clamped at the oldest. `current` is what the field
    /// holds right now — the draft remembered before the first recall.
    ///
    /// The draft is fixed when the walk starts: edits made to a recalled
    /// entry mid-walk are discarded when ↓ returns to the draft, matching
    /// shell behavior. Submitting, the window opening again, or the history
    /// changing ends the walk.
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

    func recallNext() -> String? {
        guard let index = historyIndex else { return nil }
        if index == 0 {
            let draft = recalledDraft
            endRecall()
            return draft
        }
        historyIndex = index - 1
        return history[historyIndex!]
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

    /// Waits for an in-flight command: the quit path awaits the unwind
    /// (`AppModel.shutdown`); tests settle on it too.
    func waitForCommand() async {
        await runTask?.value
    }

    private func execute(_ arguments: [String], record entry: String) {
        guard let repositoryID, !isRunning else { return }
        let command = runCommand
        isRunning = true
        runningRepositoryID = repositoryID
        output = "Running…"
        runTask = Task { [weak self] in
            let result = await command(repositoryID, arguments)
            // No cancellation guard here: the runner answers a stop with
            // "The operation was stopped.", and nothing else writes this
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
    }
}
