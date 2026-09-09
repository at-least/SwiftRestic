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
    private let isNew: Bool

    init(plan: BackupPlan) {
        _draft = State(initialValue: plan)
        isNew = plan.name.isEmpty && plan.sources.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                generalTab.tabItem { Label("General", systemImage: "gearshape") }
                sourcesTab.tabItem { Label("Files", systemImage: "folder") }
                scheduleTab.tabItem { Label("Schedule", systemImage: "calendar") }
                retentionTab.tabItem { Label("Retention", systemImage: "clock.arrow.circlepath") }
                HookEditor(hooks: $draft.hooks)
                    .tabItem { Label("Hooks", systemImage: "terminal") }
            }
            .padding(12)

            Divider()

            HStack {
                // A greyed Save that spans five tabs of validation owes the
                // user the reason at the button, not a hunt across tabs.
                if let reason = missingRequirement {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create Plan" : "Save") {
                    var plan = draft
                    // New plans claim a palette slot so their colour is stable
                    // across the sidebar, tiles and charts. The editor is the
                    // one place plans are created, so this is where the slot
                    // is minted — the model layer stays view-free.
                    if isNew, plan.chartIndex == nil {
                        // Legacy plans count via their fallback slot: a new
                        // plan must not take a colour an existing one already
                        // renders with.
                        plan.chartIndex = ChartPalette.nextSlot(
                            taken: Set(model.configuration.plans.map { ChartPalette.slot(for: $0) })
                        )
                    }
                    model.upsert(plan: plan)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isConfigurationComplete)
            }
            .padding(12)
        }
        .frame(width: 640, height: 580)
        .onAppear {
            if draft.repositoryID == nil {
                draft.repositoryID = model.configuration.repositories.first?.id
            }
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

    /// The first requirement the plan does not meet yet, in the order the
    /// tabs present them — the same one `isConfigurationComplete` checks.
    private var missingRequirement: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Name the plan to save it."
        }
        if draft.repositoryID == nil {
            return "Choose a repository to save it."
        }
        if draft.sources.isEmpty {
            return "Add at least one folder to back up."
        }
        return nil
    }

    private var generalTab: some View {
        Form {
            TextField("Name", text: $draft.name, prompt: Text("Documents to NAS"))
            Picker("Repository", selection: $draft.repositoryID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(model.configuration.repositories) { repository in
                    Text(repository.name).tag(UUID?.some(repository.id))
                }
            }
            Toggle("Run on schedule", isOn: $draft.isEnabled)
            Section("Snapshot tags") {
                Text(
                    "SwiftRestic always adds a private tag so retention only ever touches this plan's own snapshots."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var sourcesTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PathListEditor(
                title: "Back up these folders and files",
                paths: $draft.sources,
                placeholder: "/Users/you/Documents",
                expandsTildeInPath: true
            )
            PathListEditor(
                title: "Exclude patterns",
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
                // Owning the moment instead of surprising with it: a new plan
                // counts as due, so its first backup starts within a minute of
                // being created — a first-timer's unprompted multi-gigabyte
                // upload unless the caption says so.
                Text("A new plan starts its first backup within a minute of being created; pick Manually if that is not what you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Summary", value: draft.schedule.summary)
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

    private var timeOfDayPickers: some View {
        HStack {
            Picker("At", selection: $draft.schedule.hour) {
                ForEach(0 ... 23, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .frame(width: 130)
            // Any minute, not a hidden 15-minute grid: a typed :05 or :20
            // failed invisibly before, and "every 6 hours at :20" was
            // inexpressible.
            TextField(
                "Minute",
                value: Binding(
                    get: { draft.schedule.minute },
                    set: { draft.schedule.minute = min(59, max(0, $0)) }
                ),
                format: .number.grouping(.never)
            )
            .frame(width: 56)
        }
    }

    private var retentionTab: some View {
        Form {
            Toggle("Apply retention after each backup", isOn: $draft.retention.isEnabled)

            Group {
                keepStepper("Keep latest", value: $draft.retention.keepLast, max: 100)
                keepStepper("Keep hourly", value: $draft.retention.keepHourly, max: 168)
                keepStepper("Keep daily", value: $draft.retention.keepDaily, max: 365)
                keepStepper("Keep weekly", value: $draft.retention.keepWeekly, max: 260)
                keepStepper("Keep monthly", value: $draft.retention.keepMonthly, max: 120)
                keepStepper("Keep yearly", value: $draft.retention.keepYearly, max: 50)
            }
            .disabled(!draft.retention.isEnabled)

            Section {
                Toggle("Also prune (reclaims space, much slower)", isOn: $draft.retention.runPrune)
                    .disabled(!draft.retention.isEnabled)
                LabeledContent("Summary", value: draft.retention.summary)
                if draft.retention.isEnabled, let projection = RetentionProjection.project(
                    policy: draft.retention,
                    schedule: draft.schedule
                ) {
                    // Retention is where users decide what gets deleted; the
                    // steppers' bucket arithmetic is impossible to eyeball,
                    // so project the outcome instead of restating the rules.
                    Label(
                        "≈ \(projection.keptSnapshots) snapshots would survive, reaching back about \(Format.plural(projection.historyDays, "day")) at this schedule.",
                        systemImage: "chart.bar.doc.horizontal"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
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
        }
        .formStyle(.grouped)
    }

    private func keepStepper(_ title: String, value: Binding<Int>, max: Int) -> some View {
        Stepper(value: value, in: 0 ... max) {
            LabeledContent(title, value: value.wrappedValue == 0 ? "off" : "\(value.wrappedValue)")
        }
    }
}
