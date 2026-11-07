import SwiftUI

/// Runs restic commands directly, for the things the UI does not cover: a
/// utility window of its own, as Recovery's Terminal is. Its output and a
/// running command outlive the window because the state lives in
/// `ConsoleModel` on the model, not here.
struct ResticConsoleView: View {
    @Environment(AppModel.self) private var model
    @State private var finder = LogFinder()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            outputPane
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .onAppear { model.consoleDidAppear() }
        .confirmationDialog(
            "Run this command?",
            isPresented: Binding(
                get: { model.console.pendingDestructive != nil },
                set: { if !$0 { model.console.cancelPending() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) {
                model.console.confirmPending()
            }
            Button("Cancel", role: .cancel) { model.console.cancelPending() }
        } message: {
            Text("`restic \(CommandLineTokenizer.render(model.console.pendingDestructive?.arguments ?? []))` can change or delete data. Add --dry-run first if you are unsure.")
        }
    }

    private var controls: some View {
        @Bindable var console = model.console
        return VStack(alignment: .leading, spacing: 10) {
            // One label column, one value column: the popup and the field
            // start at the same x, as the editors' grids do.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Location")
                        .gridColumnAlignment(.trailing)
                    Picker("Location", selection: $console.repositoryID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(model.configuration.repositories) { repository in
                            Text(model.label(of: repository)).tag(UUID?.some(repository.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Location")
                }
                GridRow {
                    Text("restic")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("Command", text: $console.commandText, prompt: Text("snapshots --compact"))
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { console.run() }
                            // Terminal reflexes: ↑ walks into the history, ↓ walks
                            // back out to what was being typed.
                            .onKeyPress(.upArrow) {
                                if let entry = console.recallPrevious(current: console.commandText) {
                                    console.commandText = entry
                                    return .handled
                                }
                                return .ignored
                            }
                            .onKeyPress(.downArrow) {
                                if let entry = console.recallNext() {
                                    console.commandText = entry
                                    return .handled
                                }
                                return .ignored
                            }
                        Button("Run") { console.run() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!console.canRun)
                        // Always occupying their space, only visible while running:
                        // appearing here would shift the row at the exact moment of
                        // a click.
                        Button("Stop") { console.cancelRunningCommand() }
                            .disabled(!console.isRunning)
                            .opacity(console.isRunning ? 1 : 0)
                            .accessibilityHidden(!console.isRunning)
                        ProgressView()
                            .controlSize(.small)
                            .opacity(console.isRunning ? 1 : 0)
                            .accessibilityHidden(!console.isRunning)
                    }
                }
            }

            ExpandableCaption(
                summary: "The location and its credentials are supplied for you.",
                detail: "Output is restic’s own — nothing here is parsed by the app."
            )
        }
        .padding(12)
    }

    @ViewBuilder
    private var outputPane: some View {
        if model.console.output.isEmpty {
            Text("Output appears here.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        } else {
            // restic check on a large repository can print hundreds of
            // thousands of lines — the log sheet's lazily laid-out text view,
            // not a SwiftUI Text.
            LogTextView(text: model.console.output, finder: finder)
        }
    }

    private var footer: some View {
        HStack {
            Button("Copy Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.console.output, forType: .string)
            }
            .disabled(model.console.output.isEmpty)
            Button("Find…") { finder.showFindBar() }
                .keyboardShortcut("f")
                .disabled(model.console.output.isEmpty)
                .help("Search the output (⌘F)")
            Button("Clear") { model.console.clearOutput() }
                .disabled(model.console.output.isEmpty || model.console.isRunning)
            Spacer()
            Text(model.resticVersion)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
    }
}
