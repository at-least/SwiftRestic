import SwiftUI

struct PlanEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BackupPlan
    /// The state the sheet opened with (after the repository defaulting in
    /// `onAppear`). Cancel compares against it: Esc is a reflex on macOS, and
    /// a reflex must not silently throw away ten excluded items.
    @State private var initial: BackupPlan?
    @State private var isConfirmingDiscard = false
    /// The network share the path is on while mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShare: MountedShare?
    /// Whether the path is gone from this Mac, read off the main actor
    /// beside `mountedShare`: a stalled share can hold the read.
    @State private var pathIsMissing = false
    /// Each share's password as typed, by volume name: empty leaves a saved
    /// one as it is.
    @State private var sharePasswords: [String: String] = [:]
    enum Mode {
        case editing
        case adopt
    }
    private let mode: Mode
    /// `Mode.adopt`'s completion: the presenting surface selects the new
    /// plan and turns its page to Backups, which are its states to move.
    private let onAdopted: ((UUID) -> Void)?

    /// How often and Remove old backups automatically are not here: the
    /// plan's page changes them as they are set, and an adopted plan opens
    /// there with the draft's own (`adoptDraft`).
    init(
        plan: BackupPlan,
        mode: Mode,
        onAdopted: ((UUID) -> Void)? = nil
    ) {
        self.mode = mode
        self.onAdopted = onAdopted
        _draft = State(initialValue: plan)
    }

    var body: some View {
        // One derivation per render pass: the header, footer, locked
        // repository row and dialog below all read this pass's answer.
        let briefing = mode == .adopt ? model.adoptBriefing(for: draft, sourceExists: !pathIsMissing) : nil
        return VStack(spacing: 0) {
            if let briefing {
                adoptHeader(briefing)
            }
            identityHeader(briefing)
            form


            Divider()

            HStack {
                // A greyed Save owes the user the reason at the button.
                VStack(alignment: .leading, spacing: 4) {
                    // Adopt's warnings and standing sentence, beside the
                    // button they qualify.
                    if let briefing {
                        ForEach(briefing.warnings, id: \.self) { warning in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Theme.warning)
                                    .accessibilityHidden(true)
                                Text(warning)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(AdoptBriefing.footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        // What Continue Backups starts: Adopt leaves it to
                        // the scheduler's next tick, as a never-run plan
                        // counts as due.
                        if draft.isScheduled {
                            Text("Its next backup starts within a minute.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if mode == .adopt {
                        // The group left while the sheet was open — its page
                        // is revalidating away behind the sheet. Say it here
                        // rather than letting the button grey without a why.
                        Text("These backups are no longer here, so there’s nothing to continue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = missingRequirement {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 20)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .adopt ? "Continue Backups" : "Save") {
                    switch mode {
                    case .editing:
                        model.upsert(plan: draft)
                    case .adopt:
                        // The warnings and footer beside this button are
                        // the confirmation: no dialog asks again.
                        model.adopt(draft: draft)
                        onAdopted?(draft.id)
                    }
                    saveSharePasswords()
                    dismiss()
                }
                .accessibilityIdentifier(AccessibilityID.PlanEditor.save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // In adopt mode the group must still be there: with the
                // history gone there is nothing to adopt, and the footer
                // above says so beside the greyed button.
                .disabled(missingRequirement != nil || (mode == .adopt && briefing == nil))
            }
            .padding(12)
        }
        // Resizable, not fixed. The form scrolls, its exclude list a fixed
        // band that scrolls on its own, so adopt's header strip and footer
        // warnings fit the same frame.
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 620)
        // The path's network share and presence, read off the main actor: a
        // stalled share can hold the read for seconds. The identity rows and
        // adopt's briefing read them.
        .task(id: draft.path) {
            let path = draft.path
            let (share, missing) = await Task.detached {
                (
                    VolumePresence.mountedShare(holding: ResticService.expandTilde(path)),
                    !path.isEmpty && !AppModel.sourceExists(path)
                )
            }.value
            guard !Task.isCancelled else { return }
            mountedShare = share
            pathIsMissing = missing
        }
        .onAppear {
            draft.repositoryID = EditorRequirements.initialRepositoryID(
                draft.repositoryID, among: model.configuration.repositories
            )
            // Snapshot after the defaulting above, so an untouched sheet is
            // not born dirty.
            if initial == nil { initial = draft }
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The adopt sheet's title: what the group's backups become, when they
    /// were made and where they stay. The sheet has no other header of its
    /// own — the identity grid below is the same one every mode edits.
    private func adoptHeader(_ briefing: AdoptBriefing) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(briefing.historyLine)
                .font(.callout.weight(.semibold))
            Text(briefing.madeLine)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func cancel() {
        if let initial, draft != initial {
            isConfirmingDiscard = true
        } else if sharePasswords.values.contains(where: { !$0.isEmpty }) {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    /// The typed share password, saved once the sheet has closed — the
    /// Keychain answers off the main actor; a failure says so in a banner.
    private func saveSharePasswords() {
        guard let row = model.shareRow(for: draft.resolvedPath, mounted: mountedShare),
              let typed = sharePasswords[row.share.volumeName], !typed.isEmpty
        else { return }
        Task { [model] in
            do {
                try await model.saveNetworkShare(row.share, password: typed)
            } catch {
                model.post(Banner(
                    title: "Couldn’t save the password for “\(row.share.url)”",
                    message: error.localizedDescription,
                    level: .error
                ))
            }
        }
    }

    private var missingRequirement: String? {
        EditorRequirements.plan(draft, isNew: mode == .adopt, among: model.configuration.plans)
    }

    /// The plan's identity, above the form — Arq's place for it: the sheet
    /// often opens over a
    /// repository's page or Activity, where nothing else names the plan
    /// being edited. An adopt draft's path and repository are the history's
    /// own, in rows. A saved plan is its path in its repository — restic keeps one history
    /// per path, and the plan sits under its repository in the sidebar,
    /// where that history is — so it reads as its page does, with no rows:
    /// its label over its path, the repository beside the label as every
    /// surface away from the tree names a plan, since one folder can have a
    /// plan in two repositories.
    private func identityHeader(_ briefing: AdoptBriefing?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .editing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(RunRecordPresentation.planWithRepository(
                        draft, plans: model.configuration.plans, repositories: model.configuration.repositories
                    ))
                    .font(.headline)
                    Text((draft.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                        .help(draft.path)
                }
                .lineLimit(1)
            } else {
                identityRows(briefing)
            }
            pathNotices
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// What the folder needs before it can be backed up, beside the folder.
    @ViewBuilder
    private var pathNotices: some View {
        // A folder on a network share: its password, so a backup can
        // reconnect it. Not while adopting — the sheet is about history.
        if mode != .adopt, let row = model.shareRow(for: draft.resolvedPath, mounted: mountedShare) {
            VStack(alignment: .leading, spacing: 6) {
                NetworkSharePasswordRows(
                    url: row.share.url,
                    isSaved: row.isSaved,
                    password: Binding(
                        get: { sharePasswords[row.share.volumeName] ?? "" },
                        set: { sharePasswords[row.share.volumeName] = $0 }
                    )
                )
            }
        }
        // A folder that is gone fails every backup. Adopt's footer already
        // says it, in the same words.
        if mode != .adopt, pathIsMissing {
            WarningLine(text: AppModel.missingSourcesWarning)
                .font(.callout)
        }
        if let notice = model.fullDiskAccessNotice(for: draft.path) {
            HStack(alignment: .firstTextBaseline) {
                WarningLine(text: notice)
                Spacer(minLength: 8)
                FullDiskAccessButton()
                    .controlSize(.small)
            }
            .font(.callout)
        }
    }

    private func identityRows(_ briefing: AdoptBriefing?) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Folder or file")
                    .gridColumnAlignment(.trailing)
                Text((draft.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(draft.path)
            }
            GridRow {
                Text("Location")
                // The briefing's own words. While the group is gone — its
                // page revalidating away — the bare name still says where
                // this draft points.
                Text(briefing?.repositoryLine ?? model.repository(id: draft.repositoryID).map { model.label(of: $0) } ?? "")
            }
        }
    }

    private var form: some View {
        Form {
            // The user's own list first: below the switches, its + would
            // sit under the sheet's fold.
            Section("Excluded Items") {
                PathListEditor(paths: $draft.excludePatterns)
            }
            // What the app leaves out; the list above holds only what the
            // user added.
            Section {
                Text(PlanSkips.always)
                    .foregroundStyle(.secondary)
                    .help(PlanSkips.alwaysHelp)
                Toggle(isOn: $draft.skipsDeveloperFiles) {
                    Text(PlanSkips.developerFiles)
                    Text(PlanSkips.developerFilesCaption)
                }
                Toggle(isOn: $draft.skipsMachines) {
                    Text(PlanSkips.machines)
                    Text(PlanSkips.machinesCaption)
                }
            } header: {
                Text("Also exclude")
            }
            .editorSwitches()
            HookSection(hooks: $draft.hooks)
        }
        .formStyle(.grouped)
    }
}

/// A plan's scripts, closed until one exists: most plans have none.
private struct HookSection: View {
    @Binding var hooks: [BackupHook]
    @State private var isExpanded: Bool

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
            LabeledContent(
                "If it fails",
                value: hook.wrappedValue.abortsRunOnFailure ? "The backup doesn’t run" : "Recorded in Activity"
            )
            // Undone by the editor's Cancel, so it does not ask.
            Button("Remove") { hooks.removeAll { $0.id == hook.wrappedValue.id } }
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
