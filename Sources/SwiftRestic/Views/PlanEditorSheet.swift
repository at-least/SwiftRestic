import SwiftUI

struct PlanEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.now) private var now

    @State private var draft: BackupPlan
    /// The state the sheet opened with (after the repository defaulting in
    /// `onAppear`). Cancel compares against it: Esc is a reflex on macOS, and
    /// a reflex must not silently throw away ten pasted exclude patterns.
    @State private var initial: BackupPlan?
    @State private var isConfirmingDiscard = false
    /// Excluding first: the header above the tabs already holds the path and
    /// the repository, and what to leave out is the next question.
    @State private var tab: PlanEditorTab = .files
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
    /// The schedule default the adopt draft opened with, so the Schedule tab
    /// can say why it picked Manual — a fact of the prefill, not of the
    /// draft the user may have edited since.
    private let adoptDefaultedToManual: Bool

    init(
        plan: BackupPlan,
        mode: Mode,
        initialTab: PlanEditorTab = .files,
        onAdopted: ((UUID) -> Void)? = nil
    ) {
        var plan = plan
        self.mode = mode
        self.onAdopted = onAdopted
        adoptDefaultedToManual = mode == .adopt && plan.schedule.frequency == .manual
        _tab = State(initialValue: initialTab)
        #if DEBUG
        // Debug-only: lets a capture run land on the Retention tab.
        let sheet = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"]
        if sheet == "retention" || sheet == "adoptRetention" {
            _tab = State(initialValue: .retention)
        }
        // The dry run that tab exists for: a capture run cannot flip the
        // switch the preview is gated on.
        if sheet == "adoptRetention", mode == .adopt {
            plan.retention.isEnabled = true
        }
        #endif
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
            SheetTabs(selection: $tab, tabs: PlanEditorTab.allCases, title: { tab in
                switch tab {
                case .files: "Excluded Items"
                case .schedule: "Schedule"
                case .retention: "Old Backups"
                }
            }) { tab in
                switch tab {
                case .files: sourcesTab
                case .schedule: scheduleTab
                case .retention: retentionTab
                }
            }
            .padding(12)

            Divider()

            HStack {
                // A greyed Save that spans four tabs of validation owes the
                // user the reason at the button, not a hunt across tabs.
                // What saving starts is the Schedule tab's to say.
                VStack(alignment: .leading, spacing: 4) {
                    // Adopt's warnings and standing sentence, beside the
                    // button they qualify — every tab's footer, so the words
                    // never sit behind a tab the user may not open.
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
        // Resizable, not fixed. The Files tab's form scrolls, its exclude list
        // a fixed band that scrolls on
        // its own, so adopt's header strip and footer warnings fit the same
        // frame.
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 620)
        // The path's network share and presence, read off the main actor: a
        // stalled share can hold the read for seconds. On the sheet, not a
        // tab: the identity rows and adopt's briefing read them on every tab.
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
                    isError: true
                ))
            }
        }
    }

    private var missingRequirement: String? {
        EditorRequirements.plan(draft, isNew: mode == .adopt, among: model.configuration.plans)
    }

    /// What Continue Backups starts on a schedule: Adopt leaves it to the
    /// scheduler's next tick, a minute at most, as a never-run plan counts
    /// as due. Stated on the Schedule tab, beside the picker that could
    /// avoid it.
    private var adoptsScheduledPlan: Bool {
        mode == .adopt && draft.isScheduled
    }

    /// The plan's identity, above the tabs and so on screen from every one
    /// of them — Arq's place for it: the sheet often opens over a
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

    /// What the folder needs before it can be backed up, beside the folder
    /// on every tab.
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

    private var sourcesTab: some View {
        Form {
            // The user's own list first: below the switches, its + opened
            // under the editor's fold.
            Section {
                PathListEditor(
                    title: "Exclude",
                    paths: $draft.excludePatterns,
                    placeholder: "Type a pattern, such as **/*.iso",  // a String variable, so not parsed as Markdown
                    browseMessage: "Choose folders and files to exclude from backups",
                    browsePrompt: "Exclude",
                    escapesPickedGlobs: true
                )
            } header: {
                Text("Exclude")
            } footer: {
                Text("In a pattern, * matches within a name and ** across folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        }
        .formStyle(.grouped)
    }

    private var scheduleTab: some View {
        Form {
            Picker("How often", selection: $draft.schedule.frequency) {
                ForEach(Schedule.Frequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .accessibilityIdentifier(AccessibilityID.PlanEditor.frequency)

            if draft.schedule.frequency == .manual {
                Text("This plan runs only when you click Back Up Now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Why the adopt draft opened on Manual: the path it
                // prefilled was not here to back up.
                if adoptDefaultedToManual {
                    Text("Recommended — the folder may not exist on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // When this schedule fires, as the plan page will say once it
            // is saved — the moment a wrong guess would otherwise first
            // show as a surprise run.
            if let next = PlanStatus.editorNextBackup(
                draft: draft,
                stored: model.plan(id: draft.id),
                existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
                hold: model.scheduleHold(repositoryID: draft.repositoryID, now: now),
                isBackingUp: model.activity[draft.id] != nil,
                now: now
            ) {
                LabeledContent("Next backup") {
                    Text(next.value)
                        .modifier(TileHelp(help: next.help))
                }
            }

            // What saving this schedule starts, and that scheduled runs
            // need the app.
            Section {
                if adoptsScheduledPlan {
                    Text("Its next backup starts within a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.isScheduled {
                    Text("Runs while SwiftRestic is open, and catches up after the Mac sleeps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HookSection(hooks: $draft.hooks)
        }
        .formStyle(.grouped)
    }

    private var retentionTab: some View {
        // Restic's answer once there is a history to judge, which a plan
        // not yet run has not: the old simulation could disagree with it.
        let showsPreview = draft.retention.isSafeToRun
            && model.latestSnapshot(in: draft.repositoryID, planID: draft.id) != nil
        return Form {
            Section {
                // Recommended or Keep everything, nothing between (user
                // decision): on writes Recommended's rules.
                Toggle("Remove old backups automatically", isOn: Binding(
                    get: { draft.retention.isEnabled },
                    set: { draft.retention = RetentionPolicy(isEnabled: $0) }
                ))
                // The adopt draft keeps everything, and the consequence of
                // changing that is not the editor's usual one: the plan's tag
                // is shared with every Mac that ever ran it.
                if mode == .adopt {
                    Text("Removing old backups applies to every Mac’s backups of this plan at the next run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Text(draft.retention.summary)
                if showsPreview {
                    RetentionOutcomePreview(draft: draft)
                } else if let repositoryID = draft.repositoryID,
                          case .loaded = model.snapshotListingOutcome(for: repositoryID)
                {
                    let count = model.shelves(for: repositoryID).backupCount(ofPlan: draft.id)
                    if count > 0 {
                        LabeledContent("Current backups", value: Format.count(count))
                    }
                }
                if mode == .editing, draft.retention != initial?.retention, draft.retention.isSafeToRun {
                    Text("These rules take effect at the next backup.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The dry run over the draft itself: `forget --dry-run --no-lock`, no lock
/// taken and nothing removed. A failure stays here and never blocks Save.
private struct RetentionOutcomePreview: View {
    @Environment(AppModel.self) private var model
    let draft: BackupPlan

    @State private var load = RetentionPreviewLoad()

    /// The rules, and the newest backup they would judge: one landing while
    /// the sheet is open changes the answer. Plus Try Again.
    private struct PreviewKey: Hashable {
        var retention: RetentionPolicy
        var newestSnapshotID: String?
        var retry: Int
    }

    private var previewKey: PreviewKey {
        PreviewKey(
            retention: draft.retention,
            newestSnapshotID: model.latestSnapshot(in: draft.repositoryID, planID: draft.id)?.id,
            retry: load.retry
        )
    }

    var body: some View {
        // The task rides on the always-present container: a modifier on an
        // `if` branch never renders while that branch is empty, and the
        // preview would never start.
        VStack(alignment: .leading, spacing: 6) {
            RetentionPreviewStatus(
                isLoading: load.isLoading,
                failure: load.failure,
                working: "Working out what these rules would keep…",
                onRetry: { load.requestRetry() }
            )
            if load.failure == nil, let result = load.result {
                Text(result.outcomeLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: previewKey) {
            await load.load { try await model.previewRetention(plan: draft) }
        }
    }
}

/// An editor sheet's tabs: a segmented picker over the chosen pane, where a
/// SwiftUI `TabView` would be an `NSTabView`. That one sizes its tab control
/// only when its own frame changes size. In a sheet held below its ideal
/// height by a short window — the main window at its 652 pt minimum — the
/// last change comes before the control can size itself, and the control
/// stays 0×0, drawn as a box reading "R…": `NSTabViewSegmentedControl` at
/// 0×0 beside an intrinsic 160.5×24 (macOS 27.0.1). A relayout
/// left it so; only another size change of the tab view fixed it.
///
/// A pane is built when first shown and kept after, as a `TabView` keeps its
/// tabs: a pane's task starts on its first visit, and a half-typed field
/// survives a look at another tab. A hidden pane is disabled, so the Tab key
/// cannot walk into it.
private struct SheetTabs<Tab: Hashable, Pane: View>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> String
    @ViewBuilder let pane: (Tab) -> Pane

    @State private var shown: Set<Tab> = []

    var body: some View {
        VStack(spacing: 10) {
            Picker("Tab", selection: $selection) {
                ForEach(tabs, id: \.self) { tab in
                    Text(title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ZStack {
                ForEach(tabs, id: \.self) { tab in
                    if tab == selection || shown.contains(tab) {
                        let isSelected = tab == selection
                        pane(tab)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .disabled(!isSelected)
                            .accessibilityHidden(!isSelected)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selection, initial: true) { _, tab in
            shown.insert(tab)
        }
    }
}

/// A retention dry-run's spinner and failure (`RetentionPreviewLoad`). Two
/// independent `if`s: a failure stands alone, the answer being cleared.
private struct RetentionPreviewStatus: View {
    let isLoading: Bool
    let failure: String?
    let working: String
    let onRetry: () -> Void

    var body: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(working)
                    .foregroundStyle(.secondary)
            }
        }
        if let failure {
            WarningLine(text: Format.firstSentence(failure))
                .help(failure)
            Button("Try Again", action: onRetry)
                .controlSize(.small)
        }
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
