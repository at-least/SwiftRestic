import SwiftUI

/// Runs restic commands directly, for the things the UI does not cover.
///
/// A first-class pane with its own history sidebar, not a sheet: the console
/// is the product's escape hatch, and its output and running commands
/// survive switching panes because the state lives in `ConsoleModel` on the
/// model, not here.
struct ResticConsoleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            historySidebar
            Divider()
            VStack(spacing: 0) {
                // The shared banner queue, like every other pane: the console
                // is a first-class pane, so a repository failure while it is
                // open must not be the one message with nowhere to land.
                if !model.banners.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(model.banners) { banner in
                            BannerView(banner: banner)
                        }
                    }
                    .padding([.horizontal, .top], 12)
                }
                controls
                Divider()
                outputPane
                Divider()
                footer
            }
        }
        .navigationTitle("restic Console")
        .onAppear { model.console.appear(with: model) }
        .confirmationDialog(
            "Run this command?",
            isPresented: Binding(
                get: { model.console.pendingDestructive != nil },
                set: { if !$0 { model.console.cancelPending() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Run", role: .destructive) {
                model.console.confirmPending(app: model)
            }
            Button("Cancel", role: .cancel) { model.console.cancelPending() }
        } message: {
            Text("`restic \(CommandLineTokenizer.render(model.console.pendingDestructive?.arguments ?? []))` can change or delete data in this repository. Add --dry-run first if you are unsure.")
        }
    }

    // MARK: - Sections

    private var historySidebar: some View {
        VStack(spacing: 0) {
            if model.console.history.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Commands you run are kept here, and in future sessions unless they carry a secret.")
                )
            } else {
                List {
                    Section("History") {
                        ForEach(model.console.history, id: \.self) { entry in
                            Button {
                                model.console.pickFromHistory(entry)
                            } label: {
                                Text(entry)
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help(entry)
                            .contextMenu {
                                Button("Remove from History", role: .destructive) {
                                    model.console.removeFromHistory(entry, app: model)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 230)
    }

    private var controls: some View {
        @Bindable var console = model.console
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Repository", selection: $console.repositoryID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(model.configuration.repositories) { repository in
                    Text(repository.name).tag(UUID?.some(repository.id))
                }
            }

            HStack(spacing: 6) {
                Text("restic")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("snapshots --compact", text: $console.commandText)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { console.run(with: model) }
                    // Terminal reflexes: ↑ walks into the history, ↓ walks
                    // back out to what was being typed. The model owns the
                    // walk; an .ignored lets the field keep its own handling.
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
                Button("Run") { console.run(with: model) }
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

            ExpandableCaption(
                summary: "The repository and its credentials are supplied for you.",
                detail: "Output is restic's own — nothing here is parsed by the app."
            )
        }
        .padding(12)
    }

    private var outputPane: some View {
        ScrollView {
            Text(model.console.output.isEmpty ? "Output appears here." : model.console.output)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(model.console.output.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(.quaternary.opacity(0.25))
    }

    private var footer: some View {
        HStack {
            Button("Copy Output") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.console.output, forType: .string)
            }
            .disabled(model.console.output.isEmpty)
            Button("Clear") { model.console.clearOutput() }
                .disabled(model.console.output.isEmpty || model.console.isRunning)
            Spacer()
        }
        .padding(12)
    }
}
