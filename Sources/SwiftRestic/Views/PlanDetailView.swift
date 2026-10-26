import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The window's minute clock: Last backup and Next backup are as of it.
    @Environment(\.now) private var now
    let planID: UUID
    /// The Files tab's "Search All Backups": Find Files, prefilled.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    private var plan: BackupPlan? { model.plan(id: planID) }

    var body: some View {
        Group {
            if let plan {
                switch router.tab(of: .plan(planID)) {
                case .overview: content(plan)
                case .backups: backups(plan)
                case .files: files(plan)
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
        .pageSearch(
            page: .plan(planID),
            roots: plan?.repositoryID.map { FileNode.roots(repositoryID: $0, chainKey: ResticService.planTag(planID)) },
            filesPrompt: "Search this plan’s backups"
        )
        // The toolbar holds the tabs and the search field; the editor is
        // Plan ▸ Edit Plan and the sidebar row's Edit Plan, removing Plan ▸
        // Remove Plan and the row's menu —
        // the HIG's macOS toolbars: "it doesn't make sense to provide a
        // toolbar item for every menu item".
        // Opening the page marks the plan's problem seen — honestly, since
        // the problem row under the Backups card shows the failure for as
        // long as it stands. Keyed on the plan, not on appearing: moving
        // from one plan's page straight to another's keeps this view
        // (RootDetailView gives it no per-plan identity), so onAppear never
        // fires for the second plan. A failure arriving while the page is
        // already open stays unseen until the page is opened again.
        .onChange(of: planID, initial: true) { model.markProblemSeen(planID: planID) }
    }

    /// The Backups card's verb: Back Up Now, Stop while a run is in
    /// flight — worded as every command that ends a run is; the progress
    /// strip above the cards reports the run without a Cancel of its own —
    /// Stop (⌘.) ends it. The Plan menu's predicates, so the card and
    /// the menu bar cannot disagree about either.
    @ViewBuilder
    private func backUpControl(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        if model.isRunning(planID: plan.id) {
            Button("Stop") {
                model.cancelBackup(planID: plan.id)
            }
            .disabled(!commands.canStop)
            .help("Activity records it as cancelled (⌘.)")
        } else {
            Button("Back Up Now") {
                model.runBackup(planID: plan.id)
            }
            .disabled(!commands.canBackUp)
            .modifier(TileHelp(help: commands.backUpDisabledReason))
        }
    }

    /// Pause and Resume, the Schedule card's verb — bare, the card names
    /// what they act on; the menus keep Pause Schedule and Resume Schedule
    /// (the user's call). A click on Pause keeps its one-click open-ended
    /// pause; the arrow offers the timed lengths. A manual plan has no
    /// schedule to pause and shows none: its Schedule row already says
    /// "Manually".
    @ViewBuilder
    private func scheduleControl(_ plan: BackupPlan) -> some View {
        if !plan.isScheduleActive(at: now) {
            Button("Resume") {
                model.resumePlanSchedule(id: plan.id)
            }
            .help(resumeHelp(plan))
        } else if plan.schedule.frequency != .manual {
            Menu("Pause") {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) {
                        model.pausePlanSchedule(id: plan.id, for: length)
                    }
                }
            } primaryAction: {
                model.pausePlanSchedule(id: plan.id, for: .untilResumed)
            }
            .help("Stop scheduled runs until you resume — Back Up Now still works")
        }
    }

    /// A manual plan switched off — the editor's "Run on schedule" switch —
    /// has no schedule for Resume to bring back, as its Next backup value
    /// says; the help must not promise one.
    private func resumeHelp(_ plan: BackupPlan) -> String {
        if plan.schedule.frequency == .manual {
            return "Turn “Run on schedule” back on"
        }
        return "Run this plan on its schedule again"
    }

    /// The running-operation strip, as its own view: it reads this plan's
    /// activity and progress here, so a restic progress tick re-renders the
    /// strip instead of the whole pane — `content`'s cards never rerun per
    /// tick.
    private struct OperationStrip: View {
        @Environment(AppModel.self) private var model
        let planID: UUID

        var body: some View {
            if let activity = model.activity[planID] {
                OperationProgressView(
                    title: activity.phase.displayName,
                    progress: model.planProgress[planID] ?? OperationProgress(),
                    startedAt: activity.startedAt
                )
            }
        }
    }

    /// The plan's standing problem: what went wrong, when, restic's first
    /// words about it and the counts behind them, with the way to the full
    /// record. No dismiss button — it lasts exactly as long as the problem,
    /// and a retry is the Backups card's Back Up Now just above it.
    private struct PlanProblemRow: View {
        @Environment(AppModel.self) private var model
        @Environment(\.now) private var now
        let summary: PlanProblemSummary
        /// The run the summary describes, for the fix its items need.
        let run: RunRecord
        /// How many backups in a row ended this way (`RunRecord.problemStretch`).
        let inARow: Int
        var onShowInActivity: (() -> Void)?

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                // Activity's glyph and hue for the outcome. Beside a headline
                // that names it: decoration to VoiceOver.
                Image(systemName: summary.outcome.symbolName ?? "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
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
                        if !summary.facts.isEmpty {
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
                if let fix = model.fix(for: run) {
                    RunFixButton(fix: fix)
                        .controlSize(.small)
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
            .padding(Theme.Space.cardPadding)
            .cardSurface()
        }
    }

    /// The row's landing: Activity with the problem run selected.
    private func showInActivity(_ run: RunRecord) -> () -> Void {
        { router.focusRun(run.id) }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            OperationStrip(planID: plan.id)

            backupsCard(plan)
            // The plan's standing problem, on the plan's own page: present
            // exactly while the sidebar names it, gone once a run succeeds.
            if let problem = model.currentProblem(for: plan.id) {
                PlanProblemRow(
                    summary: PlanStatus.summary(of: problem),
                    run: problem,
                    // Every backup problem in the history has one: filled at
                    // load and as each run is appended.
                    inARow: problem.problemStretch!,
                    onShowInActivity: showInActivity(problem)
                )
            }
            SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: plan.repositoryID))
            scheduleCard(plan)
            excludingCard(plan)
        }
        .detailPane()
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

    /// The Backups tab: the plan's backups in the repository it backs up
    /// to, each one's files beside the list.
    @ViewBuilder
    private func backups(_ plan: BackupPlan) -> some View {
        if let repositoryID = plan.repositoryID {
            BackupsBrowserView(
                page: .plan(planID),
                repositoryID: repositoryID,
                backups: planBackups(plan),
                onSearchAllBackups: onSearchAllBackups
            )
        } else {
            noRepository
        }
    }

    private var noRepository: some View {
        ContentUnavailableView {
            Label("No repository set", systemImage: "questionmark.folder")
        } description: {
            Text("Its repository is no longer in SwiftRestic.")
        } actions: {
            // Not Edit Plan…: the editor shows a saved plan's repository
            // without a picker and refuses to save one without a repository.
            Button("Remove Plan") { router.request(.confirm(.deletePlan(planID))) }
        }
    }

    /// The Files tab: the plan's folder as this Mac holds it, each item by
    /// version from the plan's backups in the repository it backs up to.
    @ViewBuilder
    private func files(_ plan: BackupPlan) -> some View {
        if let repositoryID = plan.repositoryID {
            FilesBrowserView(
                roots: FileNode.roots(repositoryID: repositoryID, chainKey: ResticService.planTag(plan.id)),
                page: .plan(plan.id),
                onSearchAllBackups: onSearchAllBackups
            )
        } else {
            noRepository
        }
    }

    /// The page's answer, in Arq's label/value idiom: did this plan back
    /// up, how many backups it holds and which of them it keeps — with the
    /// verb that makes the next one now. Its backups are this page's
    /// Backups tab and its files its Files tab, so the card neither lists
    /// them a second time nor offers a second way to open them.
    private func backupsCard(_ plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: plan.repositoryID, planID: plan.id)
        return Card("Backups") {
            DetailGrid {
                // The card's title labels this line: a DetailRow here would
                // read "Backups" twice, stacked. First, as the Schedule
                // card's unlabelled line is: between two labelled rows it
                // starts at the card's edge, left of their values.
                snapshotsValue(plan, snapshots: snapshots)
                DetailRow("Last backup") { lastBackupValue(plan, snapshots: snapshots) }
                // Applying it now is Plan ▸ Apply Retention Now (and the
                // sidebar row's menu); what it will keep is the editor's
                // Retention tab.
                DetailRow("Retention", plan.retention.summary)
            }
        } accessory: {
            backUpControl(plan)
                .controlSize(.small)
        }
    }

    /// When the plan runs: its schedule, and the scheduler's own answer for
    /// the next run — so a paused plan reads "Paused" and one it skips never
    /// shows a date; the full form is the tooltip, the short one leaving out
    /// the date when it is today or tomorrow — with the pause in its corner.
    private func scheduleCard(_ plan: BackupPlan) -> some View {
        let next = PlanStatus.nextBackupTile(
            for: plan,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
            hold: model.scheduleHold,
            isBackingUp: model.activity[plan.id]?.isBackup == true,
            now: now
        )
        let schedule = PlanStatus.scheduleRow(for: plan)
        return Card("Schedule") {
            DetailGrid {
                // The card's title labels this line, as the Backups card's
                // does its count.
                Text(schedule)
                    .accessibilityLabel("Schedule: \(schedule)")
                // With the schedule switched off the row above reads
                // "Paused — Daily at 2:00 AM" and Next backup could only
                // repeat "Paused" (`nextBackupTile`); a timed pause keeps
                // the row, which says when backups resume.
                if plan.isEnabled {
                    DetailRow("Next backup") {
                        Text(next.value)
                            .modifier(TileHelp(help: next.help))
                    }
                }
            }
        } accessory: {
            scheduleControl(plan)
                .controlSize(.small)
                .fixedSize()
        }
    }

    /// Arq's "View Latest Backup Record…" as the value itself: the time is a
    /// handle to its run's record in Activity, with what that backup added —
    /// when the plan has a run to land on. History it arrived with shows the
    /// snapshot's own moment and figure as plain text, and "Never" has
    /// nowhere to go.
    @ViewBuilder
    private func lastBackupValue(_ plan: BackupPlan, snapshots: [Snapshot]) -> some View {
        // The one moment every surface's "Last backup" counts from
        // (PlanStatus.lastBackupAt) — the sidebar caption's and the
        // Protection line's own derivation, so history the plan arrived
        // with is not "Never" here.
        let value = Format.ago(PlanStatus.lastBackupAt(plan: plan, latestSnapshot: snapshots.first), now: now)
        // The destination must be the run the value claims — the newest
        // backup that stamped `lastSuccessAt` (PlanStatus.lastBackupRun).
        let lastSuccessfulRun = PlanStatus.lastBackupRun(planID: plan.id, in: model.configuration.runs)
        // The run record is the primary source. When the global history cap
        // has evicted this plan's newest record — a busy plan can do that to
        // a quiet neighbour — or the history arrived with the repository and
        // no run exists, the newest snapshot's own summary answers the same
        // question, because a snapshot carries what its backup added.
        let added = (lastSuccessfulRun?.dataAdded ?? snapshots.first?.dataAdded).flatMap { $0 > 0 ? $0 : nil }
        let text = added.map { "\(value) · added \(Format.bytes($0))" } ?? value
        if let lastSuccessfulRun {
            // A clean run: Activity shows all if its Problems filter would
            // hide it.
            Button {
                router.focusRun(lastSuccessfulRun.id)
            } label: {
                HStack(spacing: 4) {
                    Text(text)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(HoverableButtonStyle())
            .help("Show this backup’s run in Activity")
            .accessibilityLabel("Last backup \(text). Show its run in Activity")
        } else {
            Text(text)
        }
    }

    /// The count only once the listing it derives from has succeeded; before
    /// that, or after a failure, "—" — the caveat under the card says why.
    /// An empty plan says which kind of empty: a repository holding other
    /// snapshots must not read as "nothing there".
    @ViewBuilder
    private func snapshotsValue(_ plan: BackupPlan, snapshots: [Snapshot]) -> some View {
        if let repositoryID = plan.repositoryID {
            HStack(spacing: 8) {
                switch model.snapshotListingOutcome(for: repositoryID) {
                case .loaded where !snapshots.isEmpty:
                    // The count and how far back the plan's history reaches,
                    // the count leading with its noun under the card's title
                    // — the repository page's line, for this plan alone.
                    let tile = OverviewMetrics.snapshotsTile(
                        total: snapshots.count, otherBackups: 0, repositoryHasPlans: true, snapshots: snapshots, subject: "of this plan",
                        noun: true
                    )
                    // When the count was read, in the tooltip with the rest.
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
                case .failed:
                    Text("—")
                    Button("Try Again") {
                        Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                    }
                    .controlSize(.small)
                    .disabled(model.loadingSnapshots.contains(repositoryID))
                case .idle:
                    Text("—")
                }
                // A spinner while a read is in flight.
                if model.loadingSnapshots.contains(repositoryID) {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            Text("No repository set")
                .foregroundStyle(.secondary)
        }
    }

    /// What the plan leaves out, as the editor's Excluding tab says it: the
    /// *Skip* switches that are on and the user's own patterns as typed,
    /// tilde and all. The folder itself is the page's subtitle. When is the
    /// Schedule card's, what it keeps the Backups card's, where the
    /// sidebar's (the plan sits under its repository); the rest of how it
    /// runs, its hooks among it, is the editor's, which Plan ▸ Edit Plan and
    /// the row's Edit Plan open — and the card's own Edit Plan, on the
    /// Excluding tab, where these rows are changed.
    private func excludingCard(_ plan: BackupPlan) -> some View {
        let skips = PlanSkips.on(in: plan)
        return Card("Excluding") {
            if skips.isEmpty, plan.excludePatterns.isEmpty {
                Text("Nothing is left out")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                DetailGrid {
                    if !skips.isEmpty {
                        DetailRow("Skip") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(skips, id: \.title) { skip in
                                    Text(skip.title)
                                        .modifier(TileHelp(help: skip.help))
                                }
                            }
                        }
                    }
                    if !plan.excludePatterns.isEmpty {
                        DetailRow("Also skip") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(plan.excludePatterns, id: \.self) { pattern in
                                    Text(pattern)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(pattern)
                                }
                            }
                        }
                    }
                }
            }
        } accessory: {
            Button("Edit Plan…") { router.request(.editPlan(plan.id)) }
                .controlSize(.small)
                .help("Change what this plan leaves out")
        }
    }
}
