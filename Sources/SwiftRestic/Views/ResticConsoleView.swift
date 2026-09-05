import SwiftUI

/// Runs restic commands directly, for the things the UI does not cover.
struct ResticConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var repositoryID: UUID?
    @State private var commandText = "snapshots --compact"
    @State private var output = ""
    @State private var isRunning = false
    @State private var pendingDestructive: [String]?
    @State private var history: [String] = []
    @State private var runTask: Task<Void, Never>?

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
                if let arguments = pendingDestructive {
                    pendingDestructive = nil
                    execute(arguments)
                }
            }
            Button("Cancel", role: .cancel) { pendingDestructive = nil }
        } message: {
            Text("`restic \(pendingDestructive?.joined(separator: " ") ?? "")` can change or delete data in this repository. Add --dry-run first if you are unsure.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            pendingDestructive = arguments
        } else {
            execute(arguments)
        }
    }

    private func execute(_ arguments: [String]) {
        guard let repositoryID else { return }
        isRunning = true
        output = "Running…"
        let entry = commandText
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
        }
    }
}
