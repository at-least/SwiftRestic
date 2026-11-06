import SwiftUI

/// A plan's scripts, closed until one exists: most plans have none.
struct HookSection: View {
    @Binding var hooks: [BackupHook]
    @State private var isExpanded: Bool
    @State private var removing: BackupHook?

    init(hooks: Binding<[BackupHook]>) {
        _hooks = hooks
        _isExpanded = State(initialValue: !hooks.wrappedValue.isEmpty)
    }

    var body: some View {
        Section {
            DisclosureGroup("Scripts", isExpanded: $isExpanded) {
                ForEach($hooks) { $hook in
                    row($hook)
                }
                Button("Add Script") { hooks.append(BackupHook()) }
                // Verbatim: a literal is a LocalizedStringKey, which SwiftUI
                // parses as Markdown.
                Text(verbatim: "Runs through /bin/sh with the app’s own privileges, which are not sandboxed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("Environment variables") {
                    Text(Self.variableReference)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(
            "Remove “\(removing?.displayName ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { hook in
            Button("Remove") { hooks.removeAll { $0.id == hook.id } }
        } message: { _ in
            Text("Nothing is deleted on disk.")
        }
    }

    @ViewBuilder
    private func row(_ hook: Binding<BackupHook>) -> some View {
        Picker("Run", selection: hook.event) {
            ForEach(BackupHook.Event.allCases) { event in
                Text(event.displayName).tag(event)
            }
        }
        TextEditor(text: hook.command)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 60)
            .accessibilityLabel(Text("Command"))
        HStack {
            if hook.wrappedValue.event == .beforeBackup {
                Picker("If it fails", selection: hook.failureBehaviour) {
                    ForEach(BackupHook.FailureBehaviour.allCases) { behaviour in
                        Text(behaviour.displayName).tag(behaviour)
                    }
                }
            } else {
                // By the time it runs the backup is already done.
                LabeledContent("If it fails", value: "Recorded in Activity")
            }
            Button("Remove") { removing = hook.wrappedValue }
        }
    }

    private static let variableReference = """
    SWIFTRESTIC_EVENT             beforeBackup | afterBackup
    SWIFTRESTIC_PLAN_NAME         plan’s folder name
    SWIFTRESTIC_PLAN_ID           plan UUID
    SWIFTRESTIC_REPO_NAME         repository’s drive, folder, host, bucket or remote
    SWIFTRESTIC_REPO_ID           repository UUID
    SWIFTRESTIC_OUTCOME           starting | succeeded | completedWithErrors | failed | skipped
    SWIFTRESTIC_SNAPSHOT_ID       set once the backup is written
    SWIFTRESTIC_ERROR             set only when something failed
    SWIFTRESTIC_FILES_NEW         file count
    SWIFTRESTIC_FILES_CHANGED     file count
    SWIFTRESTIC_BYTES_PROCESSED   bytes
    SWIFTRESTIC_DATA_ADDED        bytes written to the repository
    SWIFTRESTIC_DURATION_SECONDS  seconds
    """
}
