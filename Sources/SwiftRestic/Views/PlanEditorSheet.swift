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
    /// Files first: the header above the tabs already holds the path and
    /// the repository, and what to leave out is the next question.
    @State private var tab: Tab = .files
    @FocusState private var isPathFocused: Bool
    /// The retention tab's projection, computed off the render path under
    /// `RetentionProjection.key`: the simulation walks up to 30,000
    /// synthetic runs with Calendar decomposition — tens of milliseconds at
    /// the stepper maxima, too slow to re-run as body state on every sheet
    /// re-render (every keystroke, every stepper click).
    @State private var projection: RetentionProjection.Outcome?
    /// Set by the footer's Start at Login, so the line confirms the click
    /// where the offer stood. It follows the optimistic flip, as the
    /// Settings switch does: if the daemon answers otherwise, the mirror
    /// moves back and the offer, or the approval caption, returns.
    @State private var requestedLoginItem = false
    /// Adopt's asking-again dialog, armed only when the group's facts ask
    /// for it (a foreign-host snapshot, or a newest backup under 48 h).
    /// Its words are captured when it is armed: the group can leave while
    /// the dialog is up, and an empty dialog is worse than last moment's
    /// true words.
    @State private var isConfirmingAdopt = false
    @State private var armedAdoptConfirmation: ConfirmationCopy?
    /// The network shares among the folders while mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShares: [MountedShare] = []
    /// Whether the path is gone from this Mac, read off the main actor
    /// beside `mountedShares`: a stalled share can hold the read.
    @State private var pathIsMissing = false
    /// Each share's password as typed, by volume name: empty leaves a saved
    /// one as it is.
    @State private var sharePasswords: [String: String] = [:]
    /// Which kind of editing this sheet is for. An adopt draft is prefilled,
    /// so emptiness alone would read it as an edit; adoption says so — the
    /// presenting root names `.adopt` when it raises the sheet.
    enum Mode {
        /// A fresh plan, nothing prefilled.
        case new
        /// An existing plan, opened by Edit.
        case editing
        /// A plan-UUID group's history, prefilled for adoption.
        case adopt
    }
    private let mode: Mode
    /// `Mode.adopt`'s completion: the presenting surface selects the new
    /// plan and turns its page to Backups, which are its states to move.
    private let onAdopted: ((UUID) -> Void)?
    private let isNew: Bool
    /// The schedule default the adopt draft opened with, so the Schedule tab
    /// can say why it picked Manual — a fact of the prefill, not of the
    /// draft the user may have edited since.
    private let adoptDefaultedToManual: Bool

    enum Tab: CaseIterable { case files, schedule, retention, hooks }

    init(plan: BackupPlan, mode: Mode? = nil, initialTab: Tab = .files, onAdopted: ((UUID) -> Void)? = nil) {
        var plan = plan
        let mode = mode ?? (plan.path.isEmpty ? .new : .editing)
        self.mode = mode
        self.onAdopted = onAdopted
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
        // repository row and dialog below all read this pass's answer —
        // and deriving it stats the filesystem once per source, work the
        // render path should not pay five times over.
        let briefing = mode == .adopt ? model.adoptBriefing(for: draft) : nil
        return VStack(spacing: 0) {
            if let briefing {
                adoptHeader(briefing)
            }
            identityHeader(briefing)
            SheetTabs(selection: $tab, tabs: Tab.allCases, title: { tab in
                switch tab {
                case .files: "Files"
                case .schedule: "Schedule"
                case .retention: "Retention"
                case .hooks: "Hooks"
                }
            }) { tab in
                switch tab {
                case .files: sourcesTab
                case .schedule: scheduleTab
                case .retention: retentionTab
                case .hooks: HookEditor(hooks: $draft.hooks)
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
                        Text("These backups are no longer in the repository — there is nothing to adopt.")
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
                Button(mode == .adopt ? "Adopt" : (isNew ? "Create Plan" : "Save")) {
                    guard mode == .adopt else {
                        // As restic will read it: trimmed, a typed tilde
                        // expanded (restic sees no shell).
                        if isNew {
                            draft.path = PathListEntry.value(for: draft.path, expandsTildeInPath: true, escapesGlobs: false) ?? ""
                        }
                        model.upsert(plan: draft)
                        saveSharePasswords()
                        dismiss()
                        return
                    }
                    adopt()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                // In adopt mode the group must still be there: with the
                // history gone there is nothing to adopt, and the footer
                // above says so beside the greyed button.
                .disabled(missingRequirement != nil || (mode == .adopt && briefing == nil))
            }
            .padding(12)
        }
        // Resizable, not fixed: forty pasted exclude patterns do not fit the
        // default frame, and a fixed sheet turns its list into a mailbox slot
        // at exactly the moment the user has the most to paste. Tall enough
        // that the Hooks tab's Command field clears the fixed hook list band
        // without scrolling. Adopt's header strip and footer warnings fit the
        // same frame because the Files tab's lists give way first
        // (PathListEditor's floor); content that outgrows the sheet is
        // centred in it.
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 620)
        .onAppear {
            draft.repositoryID = EditorRequirements.initialRepositoryID(
                draft.repositoryID, among: model.configuration.repositories
            )
            // A new plan starts with its path; the Files tab below waits.
            if mode == .new { isPathFocused = true }
            // Snapshot after the defaulting above, so an untouched sheet is
            // not born dirty.
            if initial == nil { initial = draft }
        }
        // A new plan's excludes follow its path while they are still the
        // defaults for the path before — the home folder's caches appear for
        // the home folder, not for ~/dotfiles — and stop once the list is
        // edited, so a hand-made list is never replaced.
        .onChange(of: draft.path) { oldPath, newPath in
            guard mode == .new, draft.excludePatterns == BackupPlan.defaultExcludes(for: oldPath) else { return }
            draft.excludePatterns = BackupPlan.defaultExcludes(for: newPath)
        }
        .confirmationDialog(
            "Discard changes?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The plan has unsaved changes.")
        }
        // Only armed when the briefing's facts ask for it — a group that is
        // entirely this Mac's and older than two days adopts in one click,
        // the sheet having already said everything the dialog would repeat.
        .confirmationDialog(
            armedAdoptConfirmation?.title ?? "",
            isPresented: $isConfirmingAdopt,
            titleVisibility: .visible
        ) {
            Button("Adopt") { performAdopt() }
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
        return model.adoptBriefing(for: draft)
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
        guard let briefing else {
            // The group left while the sheet was open: nothing left to ask
            // about. The model says what the click found, and the plan the
            // draft still describes is a coherent one to keep or cancel.
            performAdopt()
            return
        }
        guard briefing.needsConfirmation else {
            performAdopt()
            return
        }
        armedAdoptConfirmation = briefing.confirmation
        isConfirmingAdopt = true
    }

    private func performAdopt() {
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

    /// The network share the path is on: as mounted now, else as saved — a
    /// share away while the sheet is open keeps its rows, so its password
    /// can still be replaced.
    private var folderShares: [(share: MountedShare, isSaved: Bool)] {
        guard let volume = VolumePresence.volumeName(of: ResticService.expandTilde(draft.path)) else { return [] }
        let saved = model.networkShare(forVolume: volume)
        if let mounted = mountedShares.first(where: { $0.volumeName == volume }) {
            return [(mounted, saved != nil)]
        }
        if let saved {
            return [(MountedShare(volumeName: saved.volumeName, url: saved.url), true)]
        }
        return []
    }

    /// The typed share passwords, saved once the sheet has closed — the
    /// Keychain answers off the main actor; a failure says so in a banner.
    private func saveSharePasswords() {
        let typed = folderShares.compactMap { entry in
            sharePasswords[entry.share.volumeName].flatMap { $0.isEmpty ? nil : (share: entry.share, password: $0) }
        }
        guard !typed.isEmpty else { return }
        Task { [model] in
            for entry in typed {
                do {
                    try await model.saveNetworkShare(entry.share, password: entry.password)
                } catch {
                    model.post(Banner(
                        title: "The password for \(entry.share.url) was not saved",
                        message: error.localizedDescription,
                        isError: true
                    ))
                }
            }
        }
    }

    private var missingRequirement: String? {
        EditorRequirements.plan(draft, isNew: isNew, among: model.configuration.plans)
    }

    /// The first backup of a new scheduled plan starts within a minute of
    /// the button that saves it — Create for a fresh plan, Adopt for a
    /// prefilled one whose path is here. The scheduler ticks once a
    /// minute and a never-run plan counts as immediately due. Stated on the
    /// Schedule tab, beside the picker that could avoid it.
    private var startsFirstBackupOnCreate: Bool {
        isNew && draft.isEnabled && draft.schedule.frequency != .manual
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
                Text("Repository")
                switch mode {
                case .new:
                    Picker("Repository", selection: $draft.repositoryID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.configuration.repositories) { repository in
                            Text(model.label(of: repository)).tag(UUID?.some(repository.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
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
            if mode != .adopt {
                ForEach(folderShares, id: \.share.volumeName) { entry in
                    Section {
                        NetworkSharePasswordRows(
                            url: entry.share.url,
                            isSaved: entry.isSaved,
                            password: Binding(
                                get: { sharePasswords[entry.share.volumeName] ?? "" },
                                set: { sharePasswords[entry.share.volumeName] = $0 }
                            )
                        )
                    }
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
            if model.fullDiskAccess != .granted,
               ProtectedLocations.needsFullDiskAccess(draft.path, home: NSHomeDirectory())
            {
                Section {
                    Label {
                        Text("Without Full Disk Access, parts of “\((draft.path as NSString).abbreviatingWithTildeInPath)” can't be read, and its backups end with warnings.")
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
            Section {
                PathListEditor(
                    title: "Exclude patterns",
                    systemImage: "eye.slash",
                    paths: $draft.excludePatterns,
                    placeholder: "e.g. **/node_modules",  // a String variable, so not parsed as Markdown
                    browseMessage: "Choose folders and files to leave out of backups",
                    browsePrompt: "Exclude",
                    escapesPickedGlobs: true,
                    groupsExcludeRules: true,
                    // The set a run of this draft passes restic, fitted to
                    // the folder as it is typed, among the rows while the
                    // switch below is on.
                    switchRules: draft.excludeDeveloperFiles ? BackupPlan.developerRules(for: draft.path) : []
                )
            }
            Section {
                Toggle("Skip folders marked as caches", isOn: $draft.excludeCaches)
                    .help("Folders holding a CACHEDIR.TAG file.")
                // No row anywhere can name what a simulator or a container
                // disk held, so the trade is said here, once.
                Toggle(isOn: $draft.excludeDeveloperFiles) {
                    Text("Skip developer files")
                    Text(developerFilesCaption)
                }
                Toggle("Stay on one file system", isOn: $draft.oneFileSystem)
                    .help("Folders on another disk mounted inside this one are skipped.")
                // No row anywhere can show a file that was left out, so the
                // trade is said here, once.
                Toggle(isOn: $draft.excludeCloudFiles) {
                    Text("Skip online-only files")
                    Text(cloudFilesCaption)
                }
            }
            .editorSwitches()
        }
        .formStyle(.grouped)
        // The path's network share, read off the main actor: a stalled
        // share can hold the read for seconds.
        .task(id: draft.path) {
            let path = draft.path
            let (shares, missing) = await Task.detached {
                (
                    VolumePresence.mountedShare(holding: ResticService.expandTilde(path)).map { [$0] } ?? [],
                    !path.isEmpty && !AppModel.sourceExists(path)
                )
            }.value
            guard !Task.isCancelled else { return }
            mountedShares = shares
            pathIsMissing = missing
        }
    }

    /// What the developer switch covers, and its one trade: the rules'
    /// names are the tools' own, what they download again — the contents
    /// of the simulators and the machines are the part nobody rebuilds.
    private var developerFilesCaption: String {
        "Leaves out what developer tools download or build again, simulators and Docker or OrbStack disks included — whatever is inside those isn't backed up."
    }

    /// What the cloud-files switch does with this restic: 0.19 brought
    /// `--exclude-cloud-files` to macOS.
    private var cloudFilesCaption: String {
        if let version = ResticVersion(parsing: model.resticVersion), !version.excludesCloudFilesOnMac {
            return "Needs restic 0.19 or later."
        }
        return "Files kept only in iCloud Drive or OneDrive aren't downloaded or backed up."
    }

    private var scheduleTab: some View {
        Form {
            // The schedule's on/off lives with the schedule. Off, the
            // pickers below stay editable: a paused plan's times can still
            // be changed, and saving keeps the pause.
            Toggle("Run on schedule", isOn: $draft.isEnabled)
                .editorSwitches()
            // A timed Pause Schedule leaves the switch on; without this line
            // the editor would read as if the plan were running on schedule.
            if draft.isEnabled, let end = draft.activePauseEnd(at: .now) {
                Text("Paused until \(Format.pauseEnd(end)) — scheduled runs resume by themselves then.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Run", selection: $draft.schedule.frequency) {
                ForEach(Schedule.Frequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }

            switch draft.schedule.frequency {
            case .manual:
                Text("This plan only runs when you click Back Up Now.")
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
                // The summary's own words: "Every hour", "Every 4 hours".
                Stepper(
                    draft.schedule.summary,
                    value: $draft.schedule.intervalHours,
                    in: 1 ... 24
                )
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
                hold: model.scheduleHold,
                isBackingUp: model.activity[draft.id]?.isBackup == true,
                now: now
            ) {
                LabeledContent("Next backup") {
                    Text(next.value)
                        .help(next.help ?? "")
                }
            }

            // No summary row: it would only restate the pickers above. The
            // daemon's honesty line stays — scheduled runs need the app —
            // with what saving this schedule starts, and the offer to open
            // the app at login, where the schedule is chosen.
            Section {
                if startsFirstBackupOnCreate {
                    Text(mode == .adopt
                        ? "Its first backup starts within a minute of adopting it."
                        : "Its first backup starts within a minute of creating it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // Only when this save turns a schedule on — the moment
                // the user commits to it. `initial` is nil until
                // onAppear, and an existing plan must not flash the
                // offer on that first pass, so the draft stands in. The
                // offer says the app must be open itself, so the plain
                // line only stands without it.
                if let offer = LoginItemAdvice.editorOffer(
                    draft: draft,
                    initial: initial ?? draft,
                    isNew: isNew,
                    startsAtLogin: model.startsAtLogin,
                    needsApproval: model.loginItemNeedsApproval,
                    isInstallable: model.loginItemInstallable
                ) {
                    LoginItemOfferLine(offer: offer) { requestedLoginItem = true }
                } else if requestedLoginItem, model.startsAtLogin {
                    Text(LoginItemAdvice.enabledConfirmation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Runs while SwiftRestic is open, and catches up after the Mac sleeps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        Form {
            Toggle("Apply retention after each backup", isOn: $draft.retention.isEnabled)
                .editorSwitches()

            // The adopt draft starts here off, and the consequence of turning
            // it on is not the editor's usual one: the plan's tag is shared
            // with every Mac that ever ran it, so its rules reach each Mac's
            // backups of it at the next run.
            if mode == .adopt {
                Text("Turning retention on applies to every Mac's backups of this plan at the next run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if draft.retention.isEnabled {
                // The question people actually have, in the words they'd
                // answer it with. The six buckets are the machinery that
                // delivers the answer, so they live in the disclosure below.
                Picker("Keep backups", selection: retentionChoice) {
                    ForEach(RetentionPolicy.Reach.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                // Retention's own follow-up, so it sits under it and goes
                // with it.
                Toggle(isOn: $draft.retention.runPrune) {
                    Text("Also clean up")
                    Text("Frees the space removed backups held. Much slower.")
                }
                .editorSwitches()
            }

            Section {
                LabeledContent("Summary", value: draft.retention.summary)
                if draft.retention.isEnabled, let projection {
                    // Retention is where users decide what gets deleted; the
                    // bucket arithmetic is impossible to eyeball, so project
                    // the outcome instead of restating the rules.
                    Label(
                        "≈ \(Format.plural(projection.keptSnapshots, "backup")) would survive, reaching back about \(Format.plural(projection.historyDays, "day")) at this schedule.",
                        systemImage: "chart.bar.doc.horizontal"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if mode == .adopt, draft.retention.isEnabled, draft.retention.isSafeToRun {
                    AdoptRetentionPreview(draft: draft)
                }
                // Anchor the projection to the snapshot count that exists
                // today, so "≈ 41 would survive" can be read against a real
                // number rather than floating free. Keyed on what the draft's
                // plan tag already holds here — an adopt draft's group counts,
                // the one history it is about to own.
                if let repositoryID = draft.repositoryID,
                   case .loaded = model.snapshotListingOutcome(for: repositoryID)
                {
                    let count = model.snapshots(for: repositoryID, planID: draft.id).count
                    if count > 0 {
                        LabeledContent("Current backups", value: Format.count(count))
                    }
                }
                if draft.retention.isEnabled, !draft.retention.isSafeToRun {
                    Label(
                        "With every rule at zero, every backup would be deleted, so retention is skipped until a rule is set.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if draft.retention.isEnabled {
                DisclosureGroup("Custom rules") {
                    keepStepper("Latest", value: $draft.retention.keepLast, max: 100)
                    keepStepper("Hourly", value: $draft.retention.keepHourly, max: 168)
                    keepStepper("Daily", value: $draft.retention.keepDaily, max: 365)
                    keepStepper("Weekly", value: $draft.retention.keepWeekly, max: 260)
                    keepStepper("Monthly", value: $draft.retention.keepMonthly, max: 120)
                    keepStepper("Yearly", value: $draft.retention.keepYearly, max: 50)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: RetentionProjection.key(policy: draft.retention, schedule: draft.schedule)) {
            await computeProjection()
        }
    }

    /// Re-runs only under `RetentionProjection.key` — a change to the inputs
    /// the simulation reads — and lands its answer back on the main actor.
    /// The cancellation guard keeps a slow simulation whose inputs were
    /// replaced mid-flight (a stepper held down) from overwriting the newer
    /// one's answer.
    private func computeProjection() async {
        let policy = draft.retention
        let schedule = draft.schedule
        let outcome = await Task.detached(priority: .userInitiated) {
            RetentionProjection.project(policy: policy, schedule: schedule)
        }.value
        guard !Task.isCancelled else { return }
        projection = outcome
    }

    /// The reach question and the bucket machinery, kept in sync on the model
    /// (`RetentionPolicy.Reach`), where matching and writing are testable.
    /// Custom only exists because a hand-edited policy needs a name; selecting
    /// the Custom row itself changes nothing.
    private var retentionChoice: Binding<RetentionPolicy.Reach> {
        Binding(
            get: { RetentionPolicy.Reach(policy: draft.retention) },
            set: { choice in
                guard choice != .custom else { return }
                choice.apply(to: &draft.retention)
            }
        )
    }

    private func keepStepper(_ title: String, value: Binding<Int>, max: Int) -> some View {
        Stepper(value: value, in: 0 ... max) {
            LabeledContent(title, value: value.wrappedValue == 0 ? "Off" : "\(value.wrappedValue)")
        }
    }
}

/// The adopt sheet's dry run over the draft itself: restic's own answer, not
/// the synthetic projection above it, because the question here is about
/// backups that already exist — what the rules the user just turned on would
/// leave of the history being adopted. `previewRetention(planID:)` cannot
/// serve this sheet (the plan is not saved yet), so the draft travels to
/// `forget --dry-run --no-lock` directly: no lock taken, nothing removed.
private struct AdoptRetentionPreview: View {
    @Environment(AppModel.self) private var model
    /// The sheet's live draft; the repository is locked in adopt mode, and
    /// the plan tag is the group's own UUID.
    let draft: BackupPlan

    @State private var result: RetentionPreview?
    @State private var isLoading = true
    @State private var failure: String?
    @State private var retry = 0

    /// What the preview depends on: the rules, and the newest backup the
    /// rules would judge — a backup landing while the sheet is open changes
    /// the answer, so it re-runs — plus Try Again.
    private struct PreviewKey: Hashable {
        var retention: RetentionPolicy
        var newestSnapshotID: String?
        var retry: Int
    }

    private var previewKey: PreviewKey {
        PreviewKey(
            retention: draft.retention,
            newestSnapshotID: model.snapshots(for: draft.repositoryID, planID: draft.id).first?.id,
            retry: retry
        )
    }

    var body: some View {
        // The task rides on the always-present container: a modifier on an
        // `if` branch never renders while that branch is empty, and the
        // preview would never start.
        VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out what these rules would keep…")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text(Format.firstSentence(failure))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(failure)
                Button("Try Again") { retry += 1 }
                    .controlSize(.small)
            } else if let result {
                // The glyph is decoration beside a sentence that says it all;
                // no alarm colour — a dry run has not failed anything.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .accessibilityHidden(true)
                    Text(result.adoptionLine)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: previewKey) { await load() }
    }

    private func load() async {
        isLoading = true
        failure = nil
        do {
            let preview = try await model.previewRetention(plan: draft)
            // A newer key (or the sheet closing) cancelled this read; its
            // successor owns the state now.
            guard !Task.isCancelled else { return }
            result = preview
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            result = nil
        }
        isLoading = false
    }
}

extension View {
    /// The plan editor's on/off settings: mini switches in a grouped form,
    /// the HIG's "consider using a mini switch to control the setting in a
    /// single row", the same on every tab.
    func editorSwitches() -> some View {
        toggleStyle(.switch).controlSize(.mini)
    }
}
