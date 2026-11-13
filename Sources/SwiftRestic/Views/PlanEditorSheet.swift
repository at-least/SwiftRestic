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

    /// How often is not here: the plan's page changes it as it is set.
    init(plan: BackupPlan) {
        _draft = State(initialValue: plan)
    }

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
            form

            Divider()

            HStack {
                // A greyed Save owes the user the reason at the button.
                VStack(alignment: .leading, spacing: 4) {
                    if let reason = missingRequirement {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 20)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.upsert(plan: draft)
                    saveSharePasswords()
                    dismiss()
                }
                .accessibilityIdentifier(AccessibilityID.PlanEditor.save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(missingRequirement != nil)
            }
            .padding(12)
        }
        // Resizable, not fixed. The form scrolls, its exclude list a fixed
        // band that scrolls on its own.
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 620)
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
        EditorRequirements.plan(draft, isNew: false, among: model.configuration.plans)
    }

    /// The plan's identity above the form (Arq's place for it): the sheet
    /// often opens over a location's page or Activity, where nothing else
    /// names the plan. Its label over its path, the repository beside the
    /// label, since one folder can have a plan in two repositories.
    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        // reconnect it.
        if let row = model.shareRow(for: draft.resolvedPath, mounted: mountedShare) {
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
        // A folder that is gone fails every backup.
        if pathIsMissing {
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

    private var form: some View {
        Form {
            // The list holds only what the user added; the footer names what
            // the app leaves out.
            Section {
                PathListEditor(paths: $draft.excludePatterns)
            } header: {
                Text("Excluded Items")
            } footer: {
                Text(PlanSkips.always)
                    .foregroundStyle(.secondary)
                    .help(PlanSkips.alwaysHelp)
            }
        }
        .formStyle(.grouped)
    }
}
