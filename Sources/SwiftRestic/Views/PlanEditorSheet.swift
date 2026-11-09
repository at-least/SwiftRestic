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
    @FocusState private var isPathFocused: Bool
    /// Adopt's asking-again dialog, armed only when the group's facts ask
    /// for it (a foreign-host snapshot, or a newest backup under 48 h).
    /// Its words are captured when it is armed: the group can leave while
    /// the dialog is up, and an empty dialog is worse than last moment's
    /// true words.
    @State private var isConfirmingAdopt = false
    @State private var armedAdoptConfirmation: ConfirmationCopy?
    /// The network share the path is on while mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShare: MountedShare?
    /// Whether the path is gone from this Mac, read off the main actor
    /// beside `mountedShare`: a stalled share can hold the read.
    @State private var pathIsMissing = false
    /// Each share's password as typed, by volume name: empty leaves a saved
    /// one as it is.
    @State private var sharePasswords: [String: String] = [:]
    /// Which kind of editing this sheet is for. An adopt draft is prefilled,
    /// so emptiness alone would read it as an edit; adoption says so — the
    /// presenting root names `.adopt` when it raises the sheet.
    enum Mode {
        case new
        case editing
        case adopt
    }
    private let mode: Mode
    /// `Mode.adopt`'s completion: the presenting surface selects the new
    /// plan and turns its page to Backups, which are its states to move.
    private let onAdopted: ((UUID) -> Void)?
    /// `Mode.new`'s completion: the window moves to the new plan's page.
    private let onCreated: ((UUID) -> Void)?
    private let isNew: Bool
    /// The schedule default the adopt draft opened with, so the Schedule tab
    /// can say why it picked Manual — a fact of the prefill, not of the
    /// draft the user may have edited since.
    private let adoptDefaultedToManual: Bool

    init(
        plan: BackupPlan,
        mode: Mode? = nil,
        initialTab: PlanEditorTab = .files,
        onAdopted: ((UUID) -> Void)? = nil,
        onCreated: ((UUID) -> Void)? = nil
    ) {
        var plan = plan
        let mode = mode ?? (plan.path.isEmpty ? .new : .editing)
        self.mode = mode
        self.onAdopted = onAdopted
        self.onCreated = onCreated
        isNew = mode != .editing
        adoptDefaultedToManual = mode == .adopt && plan.schedule.frequency == .manual
        _tab = State(initialValue: initialTab)
        #if DEBUG
        // Debug-only: lets a capture run land on the Retention tab.
        let sheet = ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"]
        if sheet == "retention" || sheet == "adoptRetention" {
            _tab = State(initialValue: .retention)
        }
        // The dry run that tab exists for: a capture run cannot flip the
        // toggle the preview is gated on, so the capture draft opens with
        // a thinning policy for restic to answer — keep the latest alone,
        // the one rule that answers with a smaller history.
        if sheet == "adoptRetention", mode == .adopt {
            plan.retention.isEnabled = true
            plan.retention.keepLast = 1
            plan.retention.keepHourly = 0
            plan.retention.keepDaily = 0
            plan.retention.keepWeekly = 0
            plan.retention.keepMonthly = 0
            plan.retention.keepYearly = 0
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
            if mode == .new {
                Text("New Backup Plan")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top], 20)
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
                    if registersLoginItem {
                        Text(LoginItemAdvice.registeringOnSave)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 20)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .adopt ? "Continue Backups" : (isNew ? "Create Plan" : "Save")) {
                    guard mode == .adopt else {
                        // As restic will read it: trimmed, a typed tilde
                        // expanded (restic sees no shell).
                        if isNew {
                            draft.path = PathListEntry.value(for: draft.path, expandsTildeInPath: true, escapesGlobs: false) ?? ""
                        }
                        if registersLoginItem { model.requestStartsAtLogin(true) }
                        if isNew {
                            model.createPlan(draft)
                            onCreated?(draft.id)
                        } else {
                            model.upsert(plan: draft)
                        }
                        saveSharePasswords()
                        dismiss()
                        return
                    }
                    adopt()
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
            // A new plan starts with its path; the Excluding tab below waits.
            if mode == .new { isPathFocused = true }
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
        // Only armed when the briefing's facts ask for it — a group that is
        // entirely this Mac's and older than two days adopts in one click,
        // the sheet having already said everything the dialog would repeat.
        .confirmationDialog(
            armedAdoptConfirmation?.title ?? "",
            isPresented: $isConfirmingAdopt,
            titleVisibility: .visible
        ) {
            Button("Continue Backups") { performAdopt() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(armedAdoptConfirmation?.message ?? "")
        }
    }

    /// The adopt sheet's facts, read fresh as the model changes so a backup
    /// landing while the sheet is open keeps the words true. Nil in every
    /// other mode, and once the group is gone. The body derives its own
    /// single pass; this one serves the button's click.
    private var briefing: AdoptBriefing? {
        guard mode == .adopt else { return nil }
        return model.adoptBriefing(for: draft, sourceExists: !pathIsMissing)
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

    private func adopt() {
        // No briefing: the group left while the sheet was open, nothing left
        // to ask about. The model says what the click found, and the plan
        // the draft still describes is a coherent one to keep or cancel.
        guard let briefing, briefing.needsConfirmation else {
            performAdopt()
            return
        }
        armedAdoptConfirmation = briefing.confirmation
        isConfirmingAdopt = true
    }

    private func performAdopt() {
        if registersLoginItem { model.requestStartsAtLogin(true) }
        model.adopt(draft: draft)
        onAdopted?(draft.id)
        dismiss()
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

    private var registersLoginItem: Bool {
        model.registersLoginItemOnSave(draft)
    }

    private var missingRequirement: String? {
        EditorRequirements.plan(draft, isNew: isNew, among: model.configuration.plans)
    }

    /// What the button that saves a new scheduled plan starts: Create runs it
    /// at once (`AppModel.createPlan`); Adopt leaves it to the scheduler's
    /// next tick, a minute at most, as a never-run plan counts as due.
    /// Stated on the Schedule tab, beside the picker that could avoid it.
    private var startsFirstBackupOnCreate: Bool {
        isNew && draft.isScheduled
    }

    /// The plan's identity, above the tabs and so on screen from every one
    /// of them — Arq's place for it: the sheet often opens over a
    /// repository's page or Activity, where nothing else names the plan
    /// being edited. Only a new plan chooses its path and repository, in
    /// rows; an adopt draft's are the history's own, in the same rows. A
    /// saved plan is its path in its repository — restic keeps one history
    /// per path, and the plan sits under its repository in the sidebar,
    /// where that history is — so it reads as its page does, with no rows:
    /// its label over its path, the repository beside the label as every
    /// surface away from the tree names a plan, since one folder can have a
    /// plan in two repositories.
    @ViewBuilder
    private func identityHeader(_ briefing: AdoptBriefing?) -> some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 16)
        } else {
            identityRows(briefing)
        }
    }

    private func identityRows(_ briefing: AdoptBriefing?) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Folder or file")
                    .gridColumnAlignment(.trailing)
                if mode == .new {
                    HStack {
                        TextField("Folder or file", text: $draft.path, prompt: Text("/Users/you/Documents"))
                            .labelsHidden()
                            .accessibilityLabel("Folder or file")
                            .focused($isPathFocused)
                        Button("Choose…") {
                            if let url = FilePicker.chooseFolderOrFile(message: "Choose the folder or file this plan backs up") {
                                draft.path = url.path
                            }
                        }
                    }
                } else {
                    Text((draft.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(draft.path)
                }
            }
            GridRow {
                Text("Location")
                switch mode {
                case .new:
                    Picker("Location", selection: $draft.repositoryID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(model.configuration.repositories) { repository in
                            Text(model.label(of: repository)).tag(UUID?.some(repository.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Location")
                case .adopt, .editing:
                    // The briefing's own words. While the group is gone —
                    // its page revalidating away — the bare name still says
                    // where this draft points.
                    Text(briefing?.repositoryLine ?? model.repository(id: draft.repositoryID).map { model.label(of: $0) } ?? "")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var sourcesTab: some View {
        Form {
            // A folder on a network share: its password, so a backup can
            // reconnect it. Not while adopting — the sheet is about history.
            if mode != .adopt, let row = model.shareRow(for: draft.resolvedPath, mounted: mountedShare) {
                Section {
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
            // A folder that is gone fails every backup; said here first.
            // Adopt's footer already says it, in the same words.
            if mode != .adopt, pathIsMissing {
                Section {
                    Label {
                        Text(AppModel.missingSourcesWarning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                    .font(.callout)
                }
            }
            // Said here, where the path is chosen, rather than after a
            // backup comes back with warnings. The check is a few string
            // comparisons (ProtectedLocations).
            if showsFullDiskAccessSection {
                Section {
                    Label {
                        Text("Without Full Disk Access, parts of “\((draft.path as NSString).abbreviatingWithTildeInPath)” can’t be read, and its backups end with warnings.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // Orange on the glyph only; the sentence says it all.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    }
                    .font(.callout)
                    FullDiskAccessButton()
                }
            }
            // The user's own list first: what the tab is opened for (the plan
            // page's Excluded Items Edit…). Below the switches, its + opened
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
                DisclosureGroup("Advanced") {
                    Toggle(isOn: $draft.excludeCloudFiles) {
                        Text(PlanSkips.cloudFiles)
                        Text(PlanSkips.cloudFilesCaption)
                    }
                }
            } header: {
                Text("Also exclude")
            }
            .editorSwitches()
        }
        .formStyle(.grouped)
    }

    private var showsFullDiskAccessSection: Bool {
        model.fullDiskAccess != .granted && ProtectedLocations.needsFullDiskAccess(draft.path, home: NSHomeDirectory())
    }

    private var scheduleTab: some View {
        Form {
            Picker("How often", selection: $draft.schedule.frequency) {
                ForEach(Schedule.Frequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .accessibilityIdentifier(AccessibilityID.PlanEditor.frequency)

            switch draft.schedule.frequency {
            case .manual:
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
            case .hourly:
                EmptyView()
            case .daily:
                timeOfDayPicker
            case .weekly:
                Picker("On", selection: $draft.schedule.weekday) {
                    ForEach(1 ... 7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                timeOfDayPicker
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

            // No summary row: it would only restate the pickers above. The
            // daemon's honesty line stays — scheduled runs need the app —
            // with what saving this schedule starts, and the offer to open
            // the app at login, where the schedule is chosen.
            Section {
                if startsFirstBackupOnCreate {
                    Text(mode == .adopt
                        ? "Its next backup starts within a minute."
                        : "Its first backup starts when you create it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // Only when this save turns a schedule on — the moment the user
                // commits to it. `initial` is nil until onAppear, and an
                // existing plan must not flash the line on that first pass, so
                // the draft stands in. Starting at login itself is the footer's
                // to say, once saving does it.
                if let offer = LoginItemAdvice.editorOffer(
                    draft: draft,
                    initial: initial ?? draft,
                    isNew: isNew,
                    startsAtLogin: model.startsAtLogin,
                    needsApproval: model.loginItemNeedsApproval,
                    isInstallable: model.loginItemInstallable
                ), offer != .startAtLogin {
                    LoginItemOfferLine(offer: offer)
                } else if draft.isScheduled {
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

    /// macOS's own time field: the Mac's 12- or 24-hour clock, typed or
    /// stepped, in the form the summary and the Next backup value say it
    /// in. Any minute, not a hidden 15-minute grid: a typed :05 or :20
    /// works.
    private var timeOfDayPicker: some View {
        DatePicker(
            "At",
            selection: Binding(
                get: { Schedule.moment(hour: draft.schedule.hour, minute: draft.schedule.minute) },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    draft.schedule.hour = parts.hour!
                    draft.schedule.minute = parts.minute!
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }

    private var retentionTab: some View {
        // Restic's answer once there is a history to judge, which a plan
        // not yet run has not: the old simulation could disagree with it.
        let showsPreview = mode != .new
            && draft.retention.isSafeToRun
            && model.latestSnapshot(in: draft.repositoryID, planID: draft.id) != nil
        return Form {
            Section {
                Picker("Keep backups", selection: retentionChoice) {
                    ForEach(retentionChoices) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
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
                if draft.retention.isEnabled, !draft.retention.isSafeToRun {
                    WarningLine(text: "With every rule off, every backup would be removed, so nothing is removed until a rule is set.")
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Custom is on the list only for a plan that opened with one, so its
    /// rules can be read and gone back to; nothing writes a new one.
    private var retentionChoices: [RetentionPolicy.Reach] {
        let isCustom = RetentionPolicy.Reach(policy: initial?.retention ?? draft.retention) == .custom
            || RetentionPolicy.Reach(policy: draft.retention) == .custom
        return RetentionPolicy.Reach.allCases.filter { $0 != .custom || isCustom }
    }

    private var retentionChoice: Binding<RetentionPolicy.Reach> {
        Binding(
            get: { RetentionPolicy.Reach(policy: draft.retention) },
            set: { choice in
                if choice == .custom, let initial {
                    draft.retention = initial.retention
                } else {
                    choice.apply(to: &draft.retention)
                }
            }
        )
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

/// The start-at-login step only the user can take, as the plan editor shows
/// it. The rules for when it shows are `LoginItemAdvice`'s; this reads only
/// model state, never the daemon.
private struct LoginItemOfferLine: View {
    let offer: LoginItemAdvice.Offer

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LoginItemAdvice.caption(for: offer))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if offer == .awaitingApproval {
                Button("Open Login Items") { LoginItem.openLoginItemsSettings() }
                    .controlSize(.small)
            }
        }
    }
}

/// A plan's scripts, closed until one exists: most plans have none.
private struct HookSection: View {
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
