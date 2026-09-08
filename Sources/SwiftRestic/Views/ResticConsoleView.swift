import SwiftUI

/// Runs restic commands directly, for the things the UI does not cover.
struct ResticConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryID: UUID?
    @State private var commandText = "snapshots --compact"
    @State private var output = ""
    @State private var isRunning = false
    /// The command waiting on its destructive-confirmation dialog, with the
    /// text as it was when armed — the field stays editable while the dialog
    /// is up, and the history must record what was confirmed, not what got
    /// typed afterwards.
    @State private var pendingDestructive: PendingCommand?
    @State private var history: [String] = []
    @State private var runTask: Task<Void, Never>?

    private struct PendingCommand {
        let arguments: [String]
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            outputPane
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            if repositoryID == nil { repositoryID = model.configuration.repositories.first?.id }
            // History outlives the sheet: it lives in the configuration, so a
            // command that worked is still here next week.
            history = model.configuration.settings.consoleHistory
        }
        // A command outliving its sheet would keep a restic process (possibly a
        // confirmed-destructive one) running with nowhere to show its output.
        .onDisappear { runTask?.cancel() }
        .confirmationDialog(
            "Run this command?",
            isPresented: Binding(
                get: { pendingDestructive != nil },
                set: { if !$0 { pendingDestructive = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) {
                if let pending = pendingDestructive {
                    pendingDestructive = nil
                    execute(pending.arguments, record: pending.text)
                }
            }
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
        } message: {
            Text("`restic \(CommandLineTokenizer.render(pendingDestructive?.arguments ?? []))` can change or delete data in this repository. Add --dry-run first if you are unsure.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SheetHeader(
                systemImage: "apple.terminal",
                title: "restic Console",
                subtitle: "Run restic commands directly, for the things the UI does not cover"
            )

            Picker("Repository", selection: $repositoryID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(model.configuration.repositories) { repository in
                    Text(repository.name).tag(UUID?.some(repository.id))
                }
            }

            HStack(spacing: 6) {
                Text("restic")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("snapshots --compact", text: $commandText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                Button("Run", action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                if isRunning {
                    Button("Stop") { runTask?.cancel() }
                    ProgressView().controlSize(.small)
                }
            }

            Text("The repository and its credentials are supplied for you. Output is restic's own — nothing here is parsed by the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var outputPane: some View {
        ScrollView {
            Text(output.isEmpty ? "Output appears here." : output)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(output.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.quaternary.opacity(0.25))
    }

    private var footer: some View {
        HStack {
            Menu("History") {
                ForEach(history, id: \.self) { entry in
                    Button(entry) { commandText = entry }
                }
            }
            .disabled(history.isEmpty)
            .fixedSize()

            Button("Copy Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
            }
            .disabled(output.isEmpty)

            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var canRun: Bool {
        repositoryID != nil
            && !isRunning
            && !CommandLineTokenizer.tokenize(commandText).isEmpty
    }

    private func run() {
        let arguments = CommandLineTokenizer.tokenize(commandText)
        guard !arguments.isEmpty, repositoryID != nil else { return }
        if CommandLineTokenizer.isDestructive(arguments) {
            pendingDestructive = PendingCommand(arguments: arguments, text: commandText)
        } else {
            execute(arguments, record: commandText)
        }
    }

    private func execute(_ arguments: [String], record entry: String) {
        guard let repositoryID else { return }
        isRunning = true
        output = "Running…"
        runTask = Task {
            let result = await model.runConsoleCommand(
                repositoryID: repositoryID,
                arguments: arguments
            )
            // No cancellation guard here: `runConsoleCommand` answers a stop
            // with "The operation was cancelled.", and nothing else writes this
            // state while the command runs — the message must reach the pane.
            output = result
            isRunning = false
            runTask = nil
            history.removeAll { $0 == entry }
            history.insert(entry, at: 0)
            history = Array(history.prefix(20))
            // Sensitive commands stay in this session's menu but never reach
            // the configuration file: it gets rotated and is the first thing
            // attached to a bug report, and a history miss is a small price
            // next to a stored secret.
            model.configuration.settings.consoleHistory = history.filter {
                !Self.mayCarrySecret($0)
            }
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
