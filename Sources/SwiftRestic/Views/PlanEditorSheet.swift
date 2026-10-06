import SwiftUI

struct PlanEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BackupPlan
    /// The state the sheet opened with (after the repository defaulting in
    /// `onAppear`). Cancel compares against it: Esc is a reflex on macOS, and
    /// a reflex must not silently throw away ten pasted exclude patterns.
    @State private var initial: BackupPlan?
    @State private var isConfirmingDiscard = false
    /// Files first: what to back up is the first question a plan answers,
    /// and the header above the tabs already holds the name and the
    /// repository.
    @State private var tab: Tab = .files
    @FocusState private var isNameFocused: Bool
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
    /// plan and reveals its fold, which are its states to move.
    private let onAdopted: ((UUID) -> Void)?
    private let isNew: Bool
    /// The schedule default the adopt draft opened with, so the Schedule tab
    /// can say why it picked Manual — a fact of the prefill, not of the
    /// draft the user may have edited since.
    private let adoptDefaultedToManual: Bool

    private enum Tab: Hashable { case files, schedule, retention, hooks }

    init(plan: BackupPlan, mode: Mode? = nil, onAdopted: ((UUID) -> Void)? = nil) {
        var plan = plan
        let mode = mode ?? (plan.name.isEmpty && plan.sources.isEmpty ? .new : .editing)
        self.mode = mode
        self.onAdopted = onAdopted
        isNew = mode != .editing
        adoptDefaultedToManual = mode == .adopt && plan.schedule.frequency == .manual
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
            TabView(selection: $tab) {
                sourcesTab.tabItem { Label("Files", systemImage: "folder") }
                    .tag(Tab.files)
                scheduleTab.tabItem { Label("Schedule", systemImage: "calendar") }
                    .tag(Tab.schedule)
                retentionTab.tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
                    .tag(Tab.retention)
                HookEditor(hooks: $draft.hooks)
                    .tabItem { Label("Hooks", systemImage: "terminal") }
                    .tag(Tab.hooks)
            }
            .padding(12)

            Divider()

            HStack {
                // A greyed Save that spans four tabs of validation owes the
                // user the reason at the button, not a hunt across tabs. The
                // first-run consequence rides in the same slot: it changes
                // what Create does, and the Schedule tab that explains the
                // escape hatch may never be opened.
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
                    if startsFirstBackupOnCreate {
                        Text(mode == .adopt
                            ? "Adopting this plan starts its first backup within a minute."
                            : "Creating this plan starts its first backup within a minute."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    // Only when this save turns a schedule on — the moment
                    // the user commits to it. `initial` is nil until
                    // onAppear, and an existing plan must not flash the
                    // offer on that first pass, so the draft stands in.
                    // No key equivalent: Return stays Create, Esc Cancel.
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
                    }
                }
                // Wider than the buttons' own spacing: the login line's small
                // button belongs to its caption, not to Cancel and Create.
                Spacer(minLength: 20)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .adopt ? "Adopt" : (isNew ? "Create Plan" : "Save")) {
                    guard mode == .adopt else {
                        model.upsert(plan: draft)
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
                .disabled(!draft.isConfigurationComplete || (mode == .adopt && briefing == nil))
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
            if draft.repositoryID == nil {
                draft.repositoryID = model.configuration.repositories.first?.id
            }
            // A new plan starts with its name; the Files tab below waits.
            if isNew { isNameFocused = true }
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
            Button("Keep Editing", role: .cancel) {}
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
        } else {
            dismiss()
        }
    }

    private var missingRequirement: String? {
        EditorRequirements.plan(draft)
    }

    /// The first backup of a new scheduled plan starts within a minute of
    /// the button that saves it — Create for a fresh plan, Adopt for a
    /// prefilled one whose folders are all here. The scheduler ticks once a
    /// minute and a never-run plan counts as immediately due. Stated at the
    /// button, on every tab, because the schedule picker that could avoid it
    /// sits behind a tab the user may never open.
    private var startsFirstBackupOnCreate: Bool {
        isNew && draft.isEnabled && draft.schedule.frequency != .manual
    }

    /// The plan's identity, above the tabs and so on screen from every one
    /// of them — Arq's place for it, with our live controls: the sheet often
    /// opens over a repository's page or Activity, where nothing else names the
    /// plan being edited, and the repository stays changeable here. An adopt
    /// draft is the exception: its history lives in this one repository, and
    /// a picker is the one control that could silently point the plan at
    /// another — moving a plan is the editor's own guarded act, with its
    /// consequence said below.
    private func identityHeader(_ briefing: AdoptBriefing?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $draft.name, prompt: Text("Documents to NAS"))
                        .labelsHidden()
                        .focused($isNameFocused)
                }
                GridRow {
                    Text("Repository")
                    if mode == .adopt {
                        // Locked, and the briefing's own words. While the
                        // group is gone — its page revalidating away — the
                        // bare name still says where this draft points.
                        Text(briefing?.repositoryLine ?? model.repository(id: draft.repositoryID)?.name ?? "")
                    } else {
                        Picker("Repository", selection: $draft.repositoryID) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(model.configuration.repositories) { repository in
                                Text(repository.name).tag(UUID?.some(repository.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            if let consequence = model.moveConsequence(for: draft) {
                Text(consequence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PathListEditor(
                title: "Back up these folders and files",
                systemImage: "folder.fill",
                paths: $draft.sources,
                placeholder: "/Users/you/Documents",
                expandsTildeInPath: true
            )
            // Said here, where the source is chosen, rather than after a
            // backup comes back with warnings. The check is a few string
            // comparisons per source (ProtectedLocations).
            if model.fullDiskAccess != .granted,
               let source = ProtectedLocations.firstProtectedSource(draft.sources, home: NSHomeDirectory())
            {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        // Orange on the glyph only; the sentence says it all.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        Text("Without Full Disk Access, macOS keeps parts of “\((source as NSString).abbreviatingWithTildeInPath)” from SwiftRestic, and backups of it finish with warnings.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    FullDiskAccessButton()
                }
            }
            PathListEditor(
                title: "Exclude patterns",
                systemImage: "eye.slash",
                paths: $draft.excludePatterns,
                allowsBrowsing: false,
                placeholder: "e.g. **/node_modules"  // a String variable, so not parsed as Markdown
            )
            Toggle("Skip folders marked as caches (CACHEDIR.TAG)", isOn: $draft.excludeCaches)
            Toggle("Stay on one filesystem", isOn: $draft.oneFileSystem)
        }
        .padding(.top, 6)
    }

    private var scheduleTab: some View {
        Form {
            // The schedule's on/off lives with the schedule. Off, the
            // pickers below stay editable: a paused plan's times can still
            // be changed, and saving keeps the pause.
            Toggle("Run on schedule", isOn: $draft.isEnabled)
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
                Text("This plan only runs when you press Back Up Now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Why the adopt draft opened on Manual: the folders it
                // prefilled from were not all here to back up.
                if adoptDefaultedToManual {
                    Text("Recommended — the folders may not exist on this Mac.")
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
                timeOfDayPickers
            case .weekly:
                Picker("On", selection: $draft.schedule.weekday) {
                    ForEach(1 ... 7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                timeOfDayPickers
            }

            if draft.schedule.frequency != .manual {
                // The footer states the consequence on every tab; this line
                // only carries the escape hatch, so the two never repeat
                // each other on the tab where both are visible.
                Text("Pick Manually if the plan should only run when you press Back Up Now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // No summary row: it would only restate the pickers above. The
            // daemon's honesty line stays — scheduled runs need the app.
            Section {
                Text(
                    "Scheduled runs need SwiftRestic to be running. It checks every minute and catches up on a run it missed while the Mac was asleep."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// "At 02 : 05" on one line, in the 24-hour form every schedule summary
    /// uses; the pickers' hidden labels reach VoiceOver only.
    private var timeOfDayPickers: some View {
        LabeledContent("At") {
            HStack(spacing: 4) {
                Picker("Hour", selection: $draft.schedule.hour) {
                    ForEach(0 ... 23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                // Hidden labels still name the controls to VoiceOver; an
                // added accessibilityLabel read "Hour, Hour".
                .labelsHidden()
                .fixedSize()
                Text(verbatim: ":")
                    .accessibilityHidden(true)
                // Any minute, not a hidden 15-minute grid: a typed :05 or
                // :20 must work. Bordered, so "00" reads as a field and not
                // as a label beside the popup.
                TextField(
                    "Minute",
                    value: Binding(
                        get: { draft.schedule.minute },
                        set: { draft.schedule.minute = min(59, max(0, $0)) }
                    ),
                    format: Schedule.minuteStyle
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 40)
            }
        }
    }

    private var retentionTab: some View {
        Form {
            Toggle("Apply retention after each backup", isOn: $draft.retention.isEnabled)

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
                Picker("How far back do you want to reach?", selection: retentionChoice) {
                    ForEach(RetentionPolicy.Reach.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            }

            Section {
                Toggle("Also prune (reclaims space, much slower)", isOn: $draft.retention.runPrune)
                    .disabled(!draft.retention.isEnabled)
                LabeledContent("Summary", value: draft.retention.summary)
                if draft.retention.isEnabled, let projection {
                    // Retention is where users decide what gets deleted; the
                    // bucket arithmetic is impossible to eyeball, so project
                    // the outcome instead of restating the rules.
                    Label(
                        "≈ \(projection.keptSnapshots) snapshots would survive, reaching back about \(Format.plural(projection.historyDays, "day")) at this schedule.",
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
                        LabeledContent("Snapshots now", value: Format.count(count))
                    }
                }
                if draft.retention.isEnabled, !draft.retention.isSafeToRun {
                    Label(
                        "With every rule at zero, restic would delete all snapshots. Retention is skipped until at least one rule is set.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(Theme.warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            if draft.retention.isEnabled {
                DisclosureGroup("Advanced: keep rules by bucket") {
                    keepStepper("Keep latest", value: $draft.retention.keepLast, max: 100)
                    keepStepper("Keep hourly", value: $draft.retention.keepHourly, max: 168)
                    keepStepper("Keep daily", value: $draft.retention.keepDaily, max: 365)
                    keepStepper("Keep weekly", value: $draft.retention.keepWeekly, max: 260)
                    keepStepper("Keep monthly", value: $draft.retention.keepMonthly, max: 120)
                    keepStepper("Keep yearly", value: $draft.retention.keepYearly, max: 50)
                    // Hand-edited rules are the Custom answer, said out loud so
                    // the picker above never silently disagrees with the
                    // buckets below.
                    Text("Hand-editing the rules shows as Custom in the picker above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            LabeledContent(title, value: value.wrappedValue == 0 ? "off" : "\(value.wrappedValue)")
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
                    Text("Asking restic what these rules would keep…")
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
