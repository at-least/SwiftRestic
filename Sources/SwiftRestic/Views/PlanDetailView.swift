import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now
    let planID: UUID
    /// Whether Remove old backups automatically was turned on on this visit:
    /// the dry run that says what it leaves runs then, not on every visit,
    /// where it would ask a cloud location again each time.
    @State private var showsRetentionPreview = false

    private var plan: BackupPlan? { model.plan(id: planID) }

    var body: some View {
        Group {
            if let plan {
                switch router.tab(of: .plan(planID)) {
                case .overview: content(plan)
                case .backups: backups(plan)
                }
            } else {
                ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
            }
        }
        // A plan is its path: the label names the page, the path under it
        // says which folder that is — or, on the Backups tab, the moment of
        // the backup open there.
        .navigationTitle(plan.map { model.label(of: $0) } ?? "Plan")
        .navigationSubtitle(plan.map(subtitle) ?? "")
        .pageTabPicker(router.tabBinding(for: .plan(planID)), tabs: SidebarItem.plan(planID).pageTabs)
        .onChange(of: planID) { showsRetentionPreview = false }
        .pageSearch(
            page: .plan(planID),
            roots: plan?.repositoryID.map { FileNode.roots(repositoryID: $0, chainKey: ResticService.planTag(planID)) },
            prompt: "Search this plan’s backups"
        )
    }

    /// The Backup menu's predicates, so the section and the menu cannot disagree.
    @ViewBuilder
    private func backUpControl(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        if model.isRunning(planID: plan.id) {
            Button("Stop") {
                model.cancelBackup(planID: plan.id)
            }
            .disabled(!commands.canStop)
            .help("Activity records it as stopped (⌘.)")
        } else {
            Button("Back Up Now") {
                model.runBackup(planID: plan.id)
            }
            .accessibilityIdentifier(AccessibilityID.Plan.backUpNow)
            .disabled(!commands.canBackUp)
            .modifier(TileHelp(help: commands.backUpDisabledReason))
        }
    }

    /// Its own view, so a restic progress tick re-renders the strip instead of
    /// the whole pane.
    private struct OperationStrip: View {
        @Environment(AppModel.self) private var model
        let planID: UUID

        var body: some View {
            if let activity = model.activity[planID] {
                OperationProgressView(
                    title: activity.phase.displayName,
                    progress: model.planProgress[planID] ?? OperationProgress()
                )
            }
        }
    }

    /// No dismiss button: it lasts exactly as long as the problem.
    private struct PlanProblemRow: View {
        @Environment(AppModel.self) private var model
        @Environment(\.now) private var now
        let summary: PlanProblemSummary
        let run: RunRecord
        /// How many backups in a row ended this way (`RunRecord.problemStretch`).
        let inARow: Int
        var onShowInActivity: (() -> Void)?

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary.outcome.symbolName ?? "exclamationmark.triangle.fill")
                    .imageScale(.large)
                    .foregroundStyle(StatusPalette.status(summary.outcome))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(summary.headline)
                                .font(.headline)
                            // The backups in a row it stands for, then the
                            // newest run's moment.
                            Text(PlanStatus.standingProblemWhen(inARow: inARow, ago: Format.ago(summary.finishedAt, now: now)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .help(Format.timestamp(summary.finishedAt))
                        }
                        if let message = summary.message {
                            Text(message)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(message)
                        }
                        // The listed items below say what the count would.
                        if !summary.facts.isEmpty, summary.items.isEmpty {
                            Text(summary.facts.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    // The drawer's diagnosis, outside the combined text so
                    // its button stays a control of its own.
                    ItemErrorHintsView(run: run)
                    // The items the diagnosis is about, each with its
                    // Show in Finder and Exclude — the drawer's own line
                    // — and what the cap leaves to Activity.
                    if !summary.items.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(summary.items.enumerated()), id: \.offset) { _, line in
                                UnreadableItemLine(run: run, line: line)
                            }
                            if summary.unlistedItemCount > 0 {
                                Text("… and \(Format.count(summary.unlistedItemCount)) more in Activity")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 12)
                // The failure's one known fix, left of the way to its record.
                // Show Plan is no fix on the plan page itself: its switch is
                // already on screen.
                if let fix = model.fix(for: run) {
                    if case .showPlan = fix {} else {
                        RunFixButton(fix: fix)
                            .controlSize(.small)
                    }
                }
                if let onShowInActivity {
                    // The visible title is the accessible name, as on the
                    // Restore pane's incomplete-backup strip: a longer label
                    // would hide "Show in Activity" from Voice Control.
                    Button("Show in Activity", action: onShowInActivity)
                        .controlSize(.small)
                        .help("Select this run in Activity to read every message it recorded")
                }
            }
        }
    }

    private func showInActivity(_ run: RunRecord) -> () -> Void {
        { router.focusRun(run.id) }
    }

    private func content(_ plan: BackupPlan) -> some View {
        Form {
            if model.activity[plan.id] != nil {
                Section { OperationStrip(planID: plan.id) }
            }
            backupsSection(plan)
            if let problem = model.currentProblem(for: plan.id) {
                Section {
                    PlanProblemRow(
                        summary: PlanStatus.summary(of: problem),
                        run: problem,
                        // Every backup problem in the history has one: filled at
                        // load and as each run is appended.
                        inARow: problem.problemStretch!,
                        onShowInActivity: showInActivity(problem)
                    )
                }
            }
            if model.snapshotListingOutcome(for: plan.repositoryID) != .loaded {
                Section { SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: plan.repositoryID), repositoryID: plan.repositoryID) }
            }
            scheduleSection(plan)
            // The rest of the plan — what it leaves out — in
            // the editor, as System Settings keeps a pane's rarer settings
            // behind Options….
            Section {
                HStack {
                    Spacer()
                    Button("Edit Plan…") { router.request(.editPlan(plan.id)) }
                        .accessibilityIdentifier(AccessibilityID.Plan.edit)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func subtitle(_ plan: BackupPlan) -> String {
        if router.tab(of: .plan(planID)) == .backups,
           let open = BackupsBrowserView.openBackup(in: planBackups(plan), picked: router.backupSelection[.plan(planID)]) {
            return Format.timestamp(open.time)
        }
        return (plan.path as NSString).abbreviatingWithTildeInPath
    }

    /// The backups the plan made in its repository, newest first — its
    /// shelf, the one the Backups tab and the sidebar's caption read.
    private func planBackups(_ plan: BackupPlan) -> [Snapshot] {
        plan.repositoryID.flatMap { model.shelves(for: $0).byPlan[plan.id] } ?? []
    }

    @ViewBuilder
    private func backups(_ plan: BackupPlan) -> some View {
        if let repositoryID = plan.repositoryID {
            BackupsBrowserView(
                page: .plan(planID),
                repositoryID: repositoryID,
                backups: planBackups(plan)
            )
        } else {
            noRepository
        }
    }

    private var noRepository: some View {
        ContentUnavailableView {
            Label(BackupPlan.noBackupLocationReason, systemImage: "questionmark.folder")
        } description: {
            Text("Its backup location is no longer in SwiftRestic.")
        } actions: {
            // Not Edit Plan…: the editor shows a saved plan's repository
            // without a picker and refuses to save one without a repository.
            Button("Remove Plan…") { router.request(.confirm(.deletePlan(planID))) }
        }
    }

    private func backupsSection(_ plan: BackupPlan) -> some View {
        // The shelf's single home, not the raw tag filter: a backup two plans'
        // tags claim (only `restic tag` from outside can do this) counts once,
        // under the plan its page and the sidebar count it under.
        let snapshots = planBackups(plan)
        return Section {
            LabeledContent("Total") {
                snapshotsValue(plan, snapshots: snapshots)
                    .accessibilityIdentifier(AccessibilityID.Plan.total)
            }
            LabeledContent("Last backup") { lastBackupValue(plan, snapshots: snapshots) }
            retentionSwitch(plan, newestBackupID: snapshots.first?.id)
        } header: {
            HStack {
                Text("Backups")
                Spacer()
                backUpControl(plan)
            }
            .controlSize(.small)
        }
    }

    /// The scheduler's own answer for the next run, so one it skips never shows
    /// a date.
    private func scheduleSection(_ plan: BackupPlan) -> some View {
        let next = PlanStatus.nextBackupTile(
            for: plan,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
            hold: model.scheduleHold(repositoryID: plan.repositoryID, now: now),
            isBackingUp: model.activity[plan.id] != nil,
            now: now
        )
        return Section("Schedule") {
            // Saved as it changes, as System Settings' pop-ups are.
            Picker("How often", selection: Binding(
                get: { plan.schedule.frequency },
                set: { frequency in model.updatePlan(plan.id) { $0.schedule.frequency = frequency } }
            )) {
                ForEach(Schedule.Frequency.allCases) { frequency in
                    Text(frequency.displayName).tag(frequency)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Plan.frequency)
            LabeledContent("Next backup") {
                Text(next.value)
                    .accessibilityIdentifier(AccessibilityID.Plan.nextBackup)
                    .modifier(TileHelp(help: next.help))
            }
        }
    }

    /// Recommended or Keep everything, nothing between (user decision): on
    /// writes Recommended's rules. Saved as it changes; the removal runs
    /// after the next backup. Turned on, restic's own answer for what that
    /// removal leaves, once there is a history to judge.
    private func retentionSwitch(_ plan: BackupPlan, newestBackupID: String?) -> some View {
        let showsPreview = showsRetentionPreview && plan.retention.isSafeToRun && newestBackupID != nil
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Remove old backups automatically", isOn: Binding(
                get: { plan.retention.isEnabled },
                set: { isOn in
                    model.updatePlan(plan.id) { $0.retention = RetentionPolicy(isEnabled: isOn) }
                    showsRetentionPreview = isOn
                }
            ))
            .editorSwitches()
            if showsPreview {
                RetentionOutcomePreview(plan: plan, newestBackupID: newestBackupID)
            }
        }
    }

    private func lastBackupValue(_ plan: BackupPlan, snapshots: [Snapshot]) -> some View {
        // The one moment every surface's "Last backup" counts from
        // (PlanStatus.lastBackupAt) — the sidebar caption's and the
        // Status line's own derivation, so history the plan arrived
        // with is not "Never" here.
        let value = Format.ago(PlanStatus.lastBackupAt(plan: plan, latestSnapshotTime: snapshots.first?.time), now: now)
        // The run the value claims — the newest backup that stamped
        // `lastSuccessAt` (PlanStatus.lastBackupRun).
        let lastSuccessfulRun = PlanStatus.lastBackupRun(planID: plan.id, in: model.configuration.runs)
        // The run record is the primary source. When the global history cap
        // has evicted this plan's newest record — a busy plan can do that to
        // a quiet neighbour — or the history arrived with the repository and
        // no run exists, the newest snapshot's own summary answers the same
        // question, because a snapshot carries what its backup added.
        let added = (lastSuccessfulRun?.dataAdded ?? snapshots.first?.dataAdded).flatMap { $0 > 0 ? $0 : nil }
        return Text(added.map { "\(value) · added \(Format.bytes($0))" } ?? value)
    }

    /// "—" until the listing succeeds; the caveat says why. While a listing
    /// is read, a value read before stays with no spinner beside it; with
    /// none yet, "Reading backups…". An empty plan says
    /// which kind of empty: a location holding other backups must not read as
    /// "nothing there".
    @ViewBuilder
    private func snapshotsValue(_ plan: BackupPlan, snapshots: [Snapshot]) -> some View {
        if let repositoryID = plan.repositoryID {
            HStack(spacing: 8) {
                switch model.snapshotListingOutcome(for: repositoryID) {
                case .loaded where !snapshots.isEmpty:
                    let tile = OverviewMetrics.snapshotsTile(
                        total: snapshots.count, otherBackups: 0, repositoryHasPlans: true, snapshots: snapshots, subject: "of this plan",
                        noun: true
                    )
                    let updated = model.snapshotsLoadedAt(for: repositoryID)
                        .map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                    Text(tile.value)
                        .monospacedDigit()
                        .help([tile.help, updated].compactMap { $0 }.joined(separator: "\n"))
                case .loaded:
                    Text(
                        model.snapshots(for: repositoryID).isEmpty
                            ? "No backups yet"
                            : PlanStatus.noneFromThisPlanFact
                    )
                    .foregroundStyle(.secondary)
                case .notConnected, .passwordRefused, .failed, .idle:
                    // The caveat holds the fix, or Try Again.
                    if model.loadingSnapshots.contains(repositoryID) {
                        Text("Reading backups…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                    }
                }
            }
        } else {
            Text(BackupPlan.noBackupLocationReason)
                .foregroundStyle(.secondary)
        }
    }
}

/// The dry run over the plan's rules: `forget --dry-run --no-lock`, no lock
/// taken and nothing removed. A failure stays here and changes nothing.
private struct RetentionOutcomePreview: View {
    @Environment(AppModel.self) private var model
    let plan: BackupPlan
    /// The newest backup the rules would judge: one landing while the page
    /// is open changes the answer.
    let newestBackupID: String?

    @State private var load = RetentionPreviewLoad()

    /// Plus Try Again.
    private struct PreviewKey: Hashable {
        var newestBackupID: String?
        var retry: Int
    }

    private var previewKey: PreviewKey {
        PreviewKey(newestBackupID: newestBackupID, retry: load.retry)
    }

    var body: some View {
        // The task rides on the always-present container: a modifier on an
        // `if` branch never renders while that branch is empty, and the
        // preview would never start.
        VStack(alignment: .leading, spacing: 6) {
            if load.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working out which backups stay…")
                        .foregroundStyle(.secondary)
                }
            }
            if let failure = load.failure {
                WarningLine(text: Format.firstSentence(failure))
                    .help(failure)
                Button("Try Again") { load.requestRetry() }
                    .controlSize(.small)
            } else if let result = load.result {
                Text(result.outcomeLine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .task(id: previewKey) {
            await load.load { try await model.previewRetention(plan: plan) }
        }
    }
}
