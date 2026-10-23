import SwiftUI

/// The Hooks tab of the plan and repository editors: a list of hooks with a
/// form for the selected one.
///
/// `events` limits which events can be chosen — a plan offers the backup events,
/// a repository the check-and-prune ones — so a hook cannot be attached to an
/// event that will never fire where it lives.
struct HookEditor: View {
    @Binding var hooks: [BackupHook]
    var events: [BackupHook.Event] = BackupHook.Event.backupEvents
    @State private var selection: BackupHook.ID?
    @State private var isConfirmingRemove = false

    private var isForMaintenance: Bool { events.allSatisfy(\.isMaintenanceEvent) }

    var body: some View {
        // A fixed-height band for the list, the form for the rest: a split
        // view's divider has no visible affordance in a sheet, and its
        // initial split gives the list — usually one or two rows — most of
        // the height, pushing the Command field the user has to fill out of
        // view. With no hook yet, the list is all there is: its frame fills
        // the tab and says what + adds.
        VStack(spacing: 0) {
            list
                .frame(maxHeight: hooks.isEmpty ? .infinity : 180)
            if !hooks.isEmpty {
                detail
            }
        }
        // A hook is always open below the list while there is one, so the
        // form never stands empty: the first on arrival, a neighbour after
        // a removal.
        .onAppear {
            if selection == nil { selection = hooks.first?.id }
        }
        .confirmationDialog(
            "Remove this hook?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove") {
                guard let index = hooks.firstIndex(where: { $0.id == selection }) else { return }
                hooks.remove(at: index)
                selection = hooks.indices.contains(index) ? hooks[index].id : hooks.last?.id
            }
        } message: {
            Text("The script and its settings are removed from this editor. Nothing is deleted on disk.")
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            EditableListFrame(
                isEmpty: hooks.isEmpty,
                emptyTitle: "No hooks",
                emptyHint: isForMaintenance
                    ? "Click + to run a script before or after this repository's checks and cleanups."
                    : "Click + to run a script before or after this plan's backups.",
                addTitle: "Add Hook",
                removeTitle: "Remove Hook",
                canRemove: selection != nil,
                onAdd: addHook,
                onRemove: { isConfirmingRemove = true }
            ) {
                List(selection: $selection) {
                    ForEach($hooks) { $hook in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $hook.isEnabled)
                                .labelsHidden()
                                .controlSize(.mini)
                                .accessibilityLabel(hook.displayName)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hook.displayName)
                                Text(hook.event.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hook.abortsRunOnFailure {
                                Image(systemName: "exclamationmark.octagon")
                                    .foregroundStyle(Theme.warning)
                                    .help(isForMaintenance ? "Cancels the check or cleanup if it fails" : "Cancels the backup if it fails")
                            }
                        }
                        .tag(hook.id)
                    }
                    .onMove { indices, destination in
                        hooks.move(fromOffsets: indices, toOffset: destination)
                    }
                }
                .listStyle(.inset)
                // The frame is the list's edge; the stock white list
                // background inside it read as a broken empty pane.
                .scrollContentBackground(.hidden)
            }
            if hooks.count > 1 {
                Text("Hooks run in the order listed; drag to reorder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func addHook() {
        var hook = BackupHook()
        hook.name = "New hook"
        // The most likely reason to script a repository is to hear about a
        // failed check; a plan's is to act on a good backup.
        hook.event = isForMaintenance ? .afterMaintenanceFailure : .afterSuccess
        hooks.append(hook)
        selection = hook.id
    }

    @ViewBuilder
    private var detail: some View {
        if let index = hooks.firstIndex(where: { $0.id == selection }) {
            Form {
                TextField("Name", text: $hooks[index].name)

                Picker("Run", selection: $hooks[index].event) {
                    ForEach(events) { event in
                        Text(event.displayName).tag(event)
                    }
                    // A hook saved with an event this editor does not offer
                    // stays visible rather than silently jumping to another.
                    if !events.contains(hooks[index].event) {
                        Text(hooks[index].event.displayName).tag(hooks[index].event)
                    }
                }

                Section("Command") {
                    TextEditor(text: $hooks[index].command)
                        .font(.system(.callout, design: .monospaced))
                        .frame(minHeight: 70)
                        // The same hairline chip the path lists wear.
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                        )
                    Text(verbatim: "Runs through /bin/sh with the app's own privileges, which are not sandboxed. Details of the run arrive as SWIFTRESTIC_* environment variables.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Stepper(value: $hooks[index].timeoutSeconds, in: 1 ... 3600, step: 10) {
                    LabeledContent("Timeout", value: "\(hooks[index].timeoutSeconds)s")
                }

                if hooks[index].event.canAbort {
                    Picker("If it fails", selection: $hooks[index].failureBehaviour) {
                        ForEach(BackupHook.FailureBehaviour.allCases) { behaviour in
                            Text(behaviour.displayName).tag(behaviour)
                        }
                    }
                } else {
                    // Only a before hook can call the run off; by the time the
                    // others run the work is already done.
                    LabeledContent("If it fails", value: "Recorded in Activity")
                }

                DisclosureGroup("Available variables") {
                    Text(variableReference)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        } else {
            // Only while a click in the list's empty space has cleared the
            // selection.
            ContentUnavailableView(
                "No hook selected",
                systemImage: "terminal",
                description: Text("Select a hook in the list to change it.")
            )
        }
    }

    private var variableReference: String {
        isForMaintenance ? Self.maintenanceVariableReference : Self.backupVariableReference
    }

    private static let backupVariableReference = """
    SWIFTRESTIC_EVENT             beforeBackup | afterSuccess | …
    SWIFTRESTIC_PLAN_NAME         plan name
    SWIFTRESTIC_PLAN_ID           plan UUID
    SWIFTRESTIC_REPO_NAME         repository name
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

    private static let maintenanceVariableReference = """
    SWIFTRESTIC_EVENT             beforeMaintenance | afterMaintenanceSuccess | …
    SWIFTRESTIC_TASK              check | prune
    SWIFTRESTIC_PLAN_NAME         empty — repository hooks have no plan
    SWIFTRESTIC_PLAN_ID           empty — repository hooks have no plan
    SWIFTRESTIC_REPO_NAME         repository name
    SWIFTRESTIC_REPO_ID           repository UUID
    SWIFTRESTIC_OUTCOME           starting | succeeded | completedWithErrors | failed | skipped
    SWIFTRESTIC_FILES_NEW         0 — no backup ran
    SWIFTRESTIC_FILES_CHANGED     0 — no backup ran
    SWIFTRESTIC_BYTES_PROCESSED   0 — no backup ran
    SWIFTRESTIC_DATA_ADDED        0 — no backup ran
    SWIFTRESTIC_ERROR             set only when something failed
    SWIFTRESTIC_DURATION_SECONDS  seconds
    """
}
