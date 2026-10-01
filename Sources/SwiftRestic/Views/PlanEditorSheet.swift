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
    /// repository the old General tab was spent on.
    @State private var tab: Tab = .files
    @FocusState private var isNameFocused: Bool
    /// The retention tab's projection, computed off the render path under
    /// `RetentionProjection.key` — the simulation walks up to 30,000
    /// synthetic runs with Calendar decomposition, which is tens of
    /// milliseconds at the stepper maxima. As body state it was re-paid on
    /// every sheet re-render (every keystroke in any field, every stepper
    /// click); now only a change to the inputs project actually reads can
    /// re-run it.
    @State private var projection: RetentionProjection.Outcome?
    /// Set by the footer's Start at Login, so the line confirms the click
    /// where the offer stood. It follows the optimistic flip, as the
    /// Settings switch does: if the daemon answers otherwise, the mirror
    /// moves back and the offer, or the approval caption, returns.
    @State private var requestedLoginItem = false
    private let isNew: Bool

    private enum Tab: Hashable { case files, schedule, retention, hooks }

    init(plan: BackupPlan) {
        _draft = State(initialValue: plan)
        isNew = plan.name.isEmpty && plan.sources.isEmpty
        #if DEBUG
        // Debug-only: lets a capture run land on the Retention tab.
        if ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"] == "retention" {
            _tab = State(initialValue: .retention)
        }
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
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
                    if let reason = missingRequirement {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if startsFirstBackupOnCreate {
                        Text("Creating this plan starts its first backup within a minute.")
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
                Button(isNew ? "Create Plan" : "Save") {
                    model.upsert(plan: draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isConfigurationComplete)
            }
            .padding(12)
        }
        // Resizable, not fixed: forty pasted exclude patterns do not fit the
        // default frame, and a fixed sheet turns its list into a mailbox slot
        // at exactly the moment the user has the most to paste. The repository
        // editor already works this way. Tall enough that the Hooks tab's
        // Command field clears the fixed hook list band without scrolling.
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
    /// Create — the scheduler ticks once a minute and a never-run plan counts
    /// as immediately due. Stated at the button, on every tab, because the
    /// schedule picker that could avoid it sits behind a tab the user may
    /// never open.
    private var startsFirstBackupOnCreate: Bool {
        isNew && draft.isEnabled && draft.schedule.frequency != .manual
    }

    /// The plan's identity, above the tabs and so on screen from every one
    /// of them — Arq's place for it, with our live controls: the sheet often
    /// opens over the Overview or Activity, where nothing else names the
    /// plan being edited, and the repository stays changeable here.
    private var identityHeader: some View {
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
            case .hourly:
                Stepper(
                    "Every \(draft.schedule.intervalHours) hour(s)",
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
    /// uses. The field's own "Minute" label wrapped to "Min / ute" in its
    /// 56-pt frame beside a bare "0"; the labels now reach VoiceOver only.
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
                // Any minute, not a hidden 15-minute grid: a typed :05 or :20
                // failed invisibly before, and "every 6 hours at :20" was
                // inexpressible. Bordered, so "00" reads as a field and not
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
                // Anchor the projection to the snapshot count that exists
                // today, so "≈ 41 would survive" can be read against a real
                // number rather than floating free.
                if !isNew, let repositoryID = draft.repositoryID,
                   case .loaded = model.snapshotListingOutcome(for: repositoryID)
                {
                    let count = model.snapshots(for: repositoryID, planID: draft.id).count
                    LabeledContent("Snapshots now", value: Format.count(count))
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
