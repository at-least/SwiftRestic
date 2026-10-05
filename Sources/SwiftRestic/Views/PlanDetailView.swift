import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The window's minute clock: Last backup and Next backup are as of it.
    @Environment(\.now) private var now
    let planID: UUID
    let onEdit: () -> Void
    /// Sends the pane to Activity — the "Last backup" value's destination,
    /// wired by RootView so this view owns no navigation of its own.
    var onShowRun: (() -> Void)? = nil
    /// The Files tab's "Search All Backups…": Find Files, prefilled.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    private var plan: BackupPlan? { model.plan(id: planID) }

    var body: some View {
        Group {
            if let plan {
                switch router.tab(of: .plan(planID)) {
                case .overview: content(plan)
                case .files: files(plan)
                }
            } else {
                ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(plan?.name ?? "Plan")
        .pageTabPicker(router.tabBinding(for: .plan(planID)))
        // Opening the page is the Mail "read": whatever failure the sidebar's
        // dot was announcing is seen now — honestly, because the problem row
        // under the Backups card shows that failure for as long as it stands. The
        // dot for a run that fails while the page is already open stays,
        // like a message arriving into the mailbox you are reading — opening
        // the page again clears it. Keyed on the plan, not on appearing:
        // going from one plan's page straight to another's keeps this view
        // (RootDetailView gives it no per-plan identity), so onAppear never
        // fired for the second plan and its dot outlived the visit.
        .onChange(of: planID, initial: true) { model.markProblemSeen(planID: planID) }
    }

    /// The Backups card's verb: Back Up Now, Stop while a run is in
    /// flight — worded as every command that ends a run is; the progress
    /// strip keeps its Cancel. The Plan menu's predicates, so the card and
    /// the menu bar cannot disagree about either.
    @ViewBuilder
    private func backUpControl(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        if model.isRunning(planID: plan.id) {
            Button("Stop", systemImage: "stop.fill") {
                model.cancelBackup(planID: plan.id)
            }
            .disabled(!commands.canStop)
            .help("\(commands.stopTitle) (⌘.) — recorded as cancelled")
        } else {
            Button("Back Up Now", systemImage: "arrow.up.circle.fill") {
                model.runBackup(planID: plan.id)
            }
            .disabled(!commands.canBackUp)
            .help("Run this plan's backup now (⌘B)")
        }
    }

    /// Pause Schedule and Resume Schedule, the Schedule card's verb. A
    /// click on Pause keeps its one-click open-ended pause; the arrow offers
    /// the timed lengths. A manual plan has no schedule to pause and shows
    /// none: its Schedule row already says "Manually", and a card's corner,
    /// unlike the toolbar it replaced, has no row of neighbours to shift.
    @ViewBuilder
    private func scheduleControl(_ plan: BackupPlan) -> some View {
        let now = Date.now
        if !plan.isScheduleActive(at: now) {
            Button("Resume Schedule", systemImage: "play.circle") {
                model.resumePlanSchedule(id: plan.id)
            }
            .labelStyle(.titleAndIcon)
            .help(resumeHelp(plan, now: now))
        } else if plan.schedule.frequency != .manual {
            Menu("Pause Schedule", systemImage: "pause.circle") {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) {
                        model.pausePlanSchedule(id: plan.id, for: length)
                    }
                }
            } primaryAction: {
                model.pausePlanSchedule(id: plan.id, for: .untilResumed)
            }
            .labelStyle(.titleAndIcon)
            .help("Stop scheduled runs until you resume — or pick a length from the arrow. Back Up Now still works")
        }
    }

    /// A manual plan switched off — removing its repository does that, and
    /// so does the editor's switch — has no schedule for Resume to bring
    /// back, as its Next backup value says; the help must not promise one.
    private func resumeHelp(_ plan: BackupPlan, now: Date) -> String {
        if let end = plan.activePauseEnd(at: now) {
            return "Paused until \(Format.pauseEnd(end)) — run this plan on its schedule again now"
        }
        if plan.schedule.frequency == .manual {
            return "Switch “Run on schedule” back on — this plan has no schedule, so it still runs only when you click Back Up Now"
        }
        return "Run this plan on its schedule again"
    }

    /// The running-operation strip, as its own view. It reads only this
    /// plan's activity and progress — both inside this body, so a restic
    /// progress tick (~1/sec) re-renders the strip instead of the whole
    /// pane (progress lives in its own observable storage precisely so
    /// phase-reading views — the strip's title, the sidebar's and the
    /// Protection line's rows — stay
    /// untouched by it), and `content`'s cards never rerun per tick.
    private struct OperationStrip: View {
        @Environment(AppModel.self) private var model
        let planID: UUID

        var body: some View {
            if let activity = model.activity[planID] {
                OperationProgressView(
                    title: activity.phase.displayName,
                    progress: model.planProgress[planID] ?? OperationProgress(),
                    startedAt: activity.startedAt,
                    onCancel: { model.cancelBackup(planID: planID) }
                )
            }
        }
    }

    /// The plan's standing problem: what went wrong, when, restic's first
    /// words about it and the counts behind them, with the way to the full
    /// record. No dismiss button — it lasts exactly as long as the problem,
    /// and a retry is the Backups card's Back Up Now just above it.
    private struct PlanProblemRow: View {
        @Environment(\.now) private var now
        let summary: PlanProblemSummary
        /// The run the summary describes, for the fix its items need.
        let run: RunRecord
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
                            Text(Format.ago(summary.finishedAt, now: now))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .help(Format.timestamp(summary.finishedAt))
                        }
                        if let message = summary.message {
                            // Middle truncation, as Activity's Detail column
                            // does for failures: restic's messages lead with
                            // the subject and end with the verdict.
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
                }
                Spacer(minLength: 12)
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

    /// The row's landing: Activity with the problem run selected. A problem
    /// run shows under both of Activity's filters, so the user's filter
    /// stays as it was — only the "Last backup" value, which can land on a
    /// clean run, has to clear it.
    private func showInActivity(_ run: RunRecord) -> (() -> Void)? {
        guard let onShowRun else { return nil }
        return {
            router.activityFocusRunID = run.id
            onShowRun()
        }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            OperationStrip(planID: plan.id)

            backupsCard(plan)
            // The plan's standing problem, on the plan's own page: present
            // exactly while the sidebar names it, gone once a run succeeds.
            if let problem = model.currentProblem(for: plan.id) {
                PlanProblemRow(summary: PlanStatus.summary(of: problem), run: problem, onShowInActivity: showInActivity(problem))
            }
            SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: plan.repositoryID))
            scheduleCard(plan)
            configurationCard(plan)
        }
        .detailPane()
    }

    /// The Files tab: the plan's own history in the repository it backs up
    /// to, folders and files across every backup.
    @ViewBuilder
    private func files(_ plan: BackupPlan) -> some View {
        if let repositoryID = plan.repositoryID {
            FilesBrowserView(
                roots: FileNode.roots(repositoryID: repositoryID, chainKey: ResticService.planTag(plan.id)),
                searchPrompt: "Search this plan's files",
                onSearchAllBackups: onSearchAllBackups
            )
        } else {
            ContentUnavailableView(
                "No repository set",
                systemImage: "questionmark.folder",
                description: Text("Choose where this plan backs up in Edit; its files appear here after its first backup.")
            )
        }
    }

    /// The page's answer, in Arq's label/value idiom: did this plan back
    /// up, and how many backups it holds — with the verb that makes the
    /// next one now. Its records are the sidebar's, under the plan, and its
    /// files are this page's Files tab, so the card neither lists them a
    /// second time nor offers a second way to open them.
    private func backupsCard(_ plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: plan.repositoryID, planID: plan.id)
        return Card("Backups") {
            DetailGrid {
                DetailRow("Last backup") { lastBackupValue(plan, snapshots: snapshots) }
                DetailRow("Snapshots") { snapshotsValue(plan, snapshots: snapshots) }
            }
        } accessory: {
            backUpControl(plan)
                .labelStyle(.titleAndIcon)
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
        return Card("Schedule") {
            DetailGrid {
                DetailRow("Schedule", PlanStatus.scheduleRow(for: plan))
                DetailRow("Next backup") {
                    Text(next.value)
                        .help(next.help ?? "")
                }
            }
        } accessory: {
            scheduleControl(plan)
                .labelStyle(.titleAndIcon)
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
        if let lastSuccessfulRun, let onShowRun {
            Button {
                router.activityShowsProblemsOnly = false
                router.activityFocusRunID = lastSuccessfulRun.id
                onShowRun()
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
            .help("Show this backup's run in Activity")
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
                    Text(Format.count(snapshots.count))
                        .monospacedDigit()
                case .loaded:
                    Text(
                        model.snapshots(for: repositoryID).isEmpty
                            ? "None yet — they appear after the first backup"
                            : "None from this plan yet — the repository holds others"
                    )
                    .foregroundStyle(.secondary)
                case let .failed(message):
                    Text("—")
                        .help(message)
                    Button("Try Again") {
                        Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                    }
                    .controlSize(.small)
                    .disabled(model.loadingSnapshots.contains(repositoryID))
                case .idle:
                    Text("—")
                }
                // Every count traces to the moment it was read, or a spinner
                // while a read is in flight.
                SnapshotFreshnessLabel(
                    loadedAt: model.snapshotsLoadedAt(for: repositoryID),
                    isLoading: model.loadingSnapshots.contains(repositoryID)
                )
            }
        } else {
            Text("No repository set")
                .foregroundStyle(.secondary)
        }
    }

    /// The plan's defining facts — the folders it backs up and the patterns
    /// it leaves out, as the editor's Files tab pairs them — then what it
    /// keeps, with Edit in its corner. When is the Schedule card's; where is
    /// the sidebar's: the plan sits under its repository.
    private func configurationCard(_ plan: BackupPlan) -> some View {
        Card("Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Backing up")
                    .font(.subheadline.weight(.medium))
                ForEach(plan.sources, id: \.self) { source in
                    Label {
                        Text((source as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        // Every source wears it, a file too: decoration,
                        // whose SF label ("Move") would only mislead.
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Theme.tint)
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                }
                if plan.sources.isEmpty {
                    Text("No folders chosen yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                // As the user typed them, tilde and all; none, no section —
                // as Hooks below.
                if !plan.excludePatterns.isEmpty {
                    Text("Excluding")
                        .font(.subheadline.weight(.medium))
                    ForEach(plan.excludePatterns, id: \.self) { pattern in
                        Label {
                            Text(pattern)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(pattern)
                        } icon: {
                            // The editor's glyph for the list, holding the
                            // pattern where the folders' names start —
                            // secondary, not the folders' tint: these are
                            // what stays out of the backup.
                            Image(systemName: "eye.slash")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        .font(.callout)
                    }
                }

                Divider()

                DetailGrid {
                    // Applying it now is Plan ▸ Apply Retention Now… (and the
                    // sidebar row's menu); what it will keep is the editor's
                    // Retention tab.
                    DetailRow("Retention", plan.retention.summary)
                    if !plan.hooks.isEmpty {
                        DetailRow("Hooks", "\(plan.hooks.filter(\.isRunnable).count) enabled")
                    }
                }
            }
        } accessory: {
            // Deleting is rare and final, so it is not here: Plan ▸ Delete
            // Plan… and the sidebar row's menu, through the one shared
            // confirmation.
            Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .help("Change this plan's folders, schedule and retention")
        }
    }
}
