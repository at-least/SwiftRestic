import SwiftUI

/// The split view's sidebar: Arq's sections plus the dashboard (Overview,
/// Backup Plans, Restore, Activity), the restore disclosure groups, the
/// context menus and the Add footer. Every repository is listed once: its
/// Restore row opens the repository's page and expands to its backups.
///
/// Split out of `RootView` as a real child view so the sidebar's list
/// type-checks on its own: the root's modifier chain sat at the compiler's
/// type-check budget, and the sheet/deletion intents the sidebar raises are
/// passed back as closures — the presenting state stays in `RootView`.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    /// Which Restore-section repositories are expanded — the backup records
    /// underneath are the restore pane's entry points. Shared with the detail
    /// column: selecting a record from anywhere must find its group open.
    @Binding var expandedRestoreRepos: Set<UUID>

    /// Lineage groups under Restore that the user folded shut. Groups start
    /// open, as Arq's tree does, and a record selected from anywhere reopens
    /// its group — the promise `expandedRestoreRepos` keeps one level up.
    @State private var collapsedRestoreLineages: Set<RestoreLineageID> = []

    let onEditPlan: (BackupPlan) -> Void
    let onNewPlan: () -> Void
    let onEditRepository: (Repository) -> Void
    let onNewRepository: () -> Void
    /// Arms the shared deletion confirmation — the sidebar's menus must not
    /// be a faster way around it.
    let onDeletePlan: (BackupPlan) -> Void
    let onRemoveRepository: (Repository) -> Void

    var body: some View {
        List(selection: Binding(
            get: { router.selection },
            set: { router.selection = $0 }
        )) {
            // The same recent-problem count every surface uses; computed once
            // per body so the badge and the surfaces it points at agree.
            let problemCount = OverviewMetrics.problemCount(
                runs: model.configuration.runs,
                since: OverviewMetrics.problemWindowStart(from: .now)
            )
            Section {
                Label("Overview", systemImage: "square.grid.2x2")
                    .tag(SidebarItem.overview)
            }

            Section("Backup Plans") {
                ForEach(model.configuration.plans) { plan in
                    PlanSidebarRow(plan: plan)
                        .tag(SidebarItem.plan(plan.id))
                        .contextMenu { planContextMenu(plan) }
                }
                if model.configuration.plans.isEmpty, !model.isBootstrapping {
                    Text("No plans yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Restore") {
                ForEach(model.configuration.repositories) { repository in
                    restoreGroup(repository)
                }
                if model.configuration.repositories.isEmpty, !model.isBootstrapping {
                    Text("No repositories to restore from")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Header-less, like Overview: one row needs no title above it.
            // The restic console has no row — it is a power tool, reached
            // from Repository ▸ restic Console….
            Section {
                Label("Activity", systemImage: "list.bullet.rectangle")
                    // The window's unread badge, wired to the same 7-day
                    // window the tray dot, the Overview's Recent problems
                    // and the menu's problem line share: one count, so no
                    // surface can claim trouble another denies. It also
                    // yields to the unconfigured state like the tray's
                    // problem face does — a removed repository's old
                    // failures must not summon setup-bound attention — and
                    // stays silent when clean.
                    .badge(
                        problemCount > 0 && !model.configuration.repositories.isEmpty
                            ? Text(verbatim: "\(problemCount)")
                            : nil
                    )
                    // The tag must come after the badge. With .tag inside
                    // .badge — a nil badge too — neither a click nor
                    // Accessibility could select the row (probed on macOS 26);
                    // .disabled and .contextMenu after .tag do no such harm.
                    .tag(SidebarItem.activity)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
        .onChange(of: router.selection) {
            guard case let .restoreSnapshot(repositoryID, snapshotID) = router.selection,
                  let snapshot = model.snapshots(for: repositoryID).first(where: { $0.id == snapshotID })
            else { return }
            collapsedRestoreLineages.remove(RestoreLineageID(repositoryID: repositoryID, key: snapshot.lineageKey))
        }
    }

    /// Arq's bare + in the corner. A missing restic is not repeated here: the
    /// banner above every pane (RootDetailView) already says it, with the
    /// install instruction a cursor-only triangle could not show. The bar
    /// background stays — an expanded Restore section scrolls under it.
    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Backup Plan…") { onNewPlan() }
                    .disabled(model.configuration.repositories.isEmpty)
                Button("Add Repository…") { onNewRepository() }
            } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a backup plan or a repository")

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func planContextMenu(_ plan: BackupPlan) -> some View {
        let commands = model.planCommands(for: .plan(plan.id))
        Button("Back Up Now") { model.runBackup(planID: plan.id) }
            // The rule every Back Up Now follows, the menu bar's included:
            // enabled only for a complete, idle plan with restic to run it —
            // an error banner is not a substitute for a disabled item.
            .disabled(!commands.canBackUp)
        Button("Edit…") { onEditPlan(plan) }
        // The plan toolbar's pair, word for word. The row wears the pause
        // glyph while the schedule is held; manual runs stay possible either
        // way, and a manual plan has no schedule to pause.
        if !plan.isScheduleActive(at: .now) {
            Button("Resume Schedule") { model.resumePlanSchedule(id: plan.id) }
        } else if plan.schedule.frequency == .manual {
            Button("Pause Schedule") {}
                .disabled(true)
        } else {
            Menu("Pause Schedule") {
                ForEach(PauseLength.allCases) { length in
                    Button(length.menuTitle) {
                        model.pausePlanSchedule(id: plan.id, for: length)
                    }
                }
            }
        }
        Button("Apply Retention Now…") { router.request(.applyRetention(plan.id)) }
            .disabled(!commands.canApplyRetention)
        Divider()
        Button("Delete Plan…", role: .destructive) { onDeletePlan(plan) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        let commands = model.repositoryCommands(for: .repository(repository.id))
        Button("Edit…") { onEditRepository(repository) }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        // The two the pane and the menu bar offer that a row most often
        // wants; the shared confirmations ask first.
        Button("Check…") { router.request(.confirm(.check(repository.id))) }
            .disabled(!commands.canMaintain)
        Button("Prune Now…", role: .destructive) { router.request(.confirm(.prune(repository.id))) }
            .disabled(!commands.canMaintain)
        Divider()
        Button("Remove from SwiftRestic…", role: .destructive) {
            onRemoveRepository(repository)
        }
    }

    // MARK: - Restore

    /// Arq's RESTORE section: each repository expands to its backup
    /// records, and picking a record shows its files in the detail pane.
    /// The repository's own row is Arq's storage-location row, both group
    /// header and target: clicking it opens the repository's page, the
    /// disclosure triangle lists its backups.
    @ViewBuilder
    private func restoreGroup(_ repository: Repository) -> some View {
        let listing = model.snapshots(for: repository.id)
        DisclosureGroup(isExpanded: Binding(
            get: { expandedRestoreRepos.contains(repository.id) },
            set: { opened in
                if opened {
                    expandedRestoreRepos.insert(repository.id)
                    // First expand loads the record list; later refreshes
                    // come from the launch sweep and the repository's own
                    // Refresh.
                    if model.snapshotListingOutcome(for: repository.id) == .idle {
                        Task { await model.refreshSnapshots(repositoryID: repository.id) }
                    }
                } else {
                    expandedRestoreRepos.remove(repository.id)
                }
            }
        )) {
            if model.loadingSnapshots.contains(repository.id), listing.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading backups…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if case let .failed(message) = model.snapshotListingOutcome(for: repository.id), listing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Orange only on the glyph, the words secondary — the
                    // plan rows' contrast rule.
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .imageScale(.small)
                            .foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                        Text(Format.firstSentence(message))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .font(.caption)
                    Button("Try Again") {
                        Task { await model.refreshSnapshots(repositoryID: repository.id) }
                    }
                    .controlSize(.small)
                }
            } else if listing.isEmpty {
                Text("No backups yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // One lineage — one plan, or a repository only one tree ever
                // went into — stays a flat list: a group level would only
                // repeat the repository row above it.
                let lineages = model.lineages(for: repository.id)
                if lineages.count > 1 {
                    let labels = SnapshotLineage.labels(for: lineages, plans: model.configuration.plans)
                    ForEach(lineages) { lineage in
                        lineageGroup(lineage, label: labels[lineage.key], repositoryID: repository.id)
                    }
                } else {
                    ForEach(listing) { snapshot in
                        RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                            .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
                    }
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(repository.name)
                        .lineLimit(1)
                    Text("\(Format.plural(listing.count, "backup"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                // The sidebar's own icon tint, as on Overview and Activity:
                // it turns white under the selection, where an explicit
                // accent vanished into the selection's blue.
                Image(systemName: repository.kind.symbolName)
            }
            .tag(SidebarItem.repository(repository.id))
            .contextMenu { repositoryContextMenu(repository) }
        }
    }

    /// One lineage's records — Arq's backed-up-folder level, so a
    /// repository several plans share no longer interleaves their dates, and
    /// the row below a record is the one its Change column compares against.
    private func lineageGroup(
        _ lineage: SnapshotLineage,
        label: SnapshotLineage.Label?,
        repositoryID: UUID
    ) -> some View {
        let id = RestoreLineageID(repositoryID: repositoryID, key: lineage.key)
        let caption = [Format.plural(lineage.snapshots.count, "backup"), label?.qualifier]
            .compactMap { $0 }
            .joined(separator: " · ")
        return DisclosureGroup(isExpanded: Binding(
            get: { !collapsedRestoreLineages.contains(id) },
            set: { opened in
                if opened {
                    collapsedRestoreLineages.remove(id)
                } else {
                    collapsedRestoreLineages.insert(id)
                }
            }
        )) {
            ForEach(lineage.snapshots) { snapshot in
                RestoreRecordRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id))
                    .tag(SidebarItem.restoreSnapshot(repositoryID, snapshot.id))
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label?.title ?? "Backups")
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.tint)
            }
            .help(label?.detail ?? "")
        }
    }
}

/// A lineage group under Restore, per repository: the same folders from the
/// same host can live in two repositories, and each group folds on its own.
private struct RestoreLineageID: Hashable {
    let repositoryID: UUID
    let key: SnapshotLineage.Key
}

/// One dated backup record in the Restore section — the row whose selection
/// fills the detail pane with that record's files. One line, like Arq's: the
/// completeness mark and the moment are the whole record at sidebar size.
private struct RestoreRecordRow: View {
    let snapshot: Snapshot
    /// The backup run that wrote it, when the history still holds one.
    let run: RunRecord?

    var body: some View {
        HStack(spacing: 6) {
            // A fixed slot, so every timestamp starts at the same x whether
            // or not its row wears the incomplete triangle.
            SnapshotCompletenessMark(run: run)
                .font(.caption)
                .frame(width: 14)
            // The row's help sits on the timestamp, not the HStack: a help
            // on the HStack overwrites the mark's own ("Incomplete: …") in
            // the accessibility tree.
            Text(Format.timestamp(snapshot.time))
                .lineLimit(1)
                .help("Browse this backup's files and restore from it")
                // The date leads the combined utterance, as in a list of
                // dates it should; the mark sits first only on screen.
                .accessibilitySortPriority(1)
        }
        // One utterance per record: the mark's label, when it has one,
        // merges with the date, so there is no second row label to keep
        // in step with it.
        .accessibilityElement(children: .combine)
    }
}

private struct PlanSidebarRow: View {
    @Environment(AppModel.self) private var model
    let plan: BackupPlan

    var body: some View {
        let caption = PlanStatus.sidebarCaption(
            for: plan,
            activity: model.activity[plan.id],
            problem: model.currentProblem(for: plan.id),
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id))
        )
        HStack(spacing: 4) {
            // A fixed leading slot on every row, marker or not, so every plan
            // name starts at the same x — 26 + 4 = 30 pt, the title inset of
            // the Label rows under Restore at the default sidebar icon size
            // (measured equal). The marker sat inline before, and a dotted
            // Photos stood 17 pt right of an idle name.
            // Color.clear holds the slot's width: an empty marker is an
            // EmptyView, and EmptyView drops `.frame`.
            ZStack {
                Color.clear
                marker
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.name.isEmpty ? "Untitled Plan" : plan.name)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    // The glyph carries the severity — red for a failed run
                    // (restic exit 1, no snapshot), orange for one that
                    // completed with errors (exit 3, an incomplete snapshot)
                    // — and the words stay in the secondary colour: orange
                    // caption text measured 2.16:1 on the light sidebar.
                    // Beside words that say it, the glyph is decoration to
                    // VoiceOver. The words, and which state wins the line,
                    // come from `PlanStatus.sidebarCaption`.
                    if let outcome = caption.outcome, let symbol = outcome.symbolName {
                        Image(systemName: symbol)
                            .imageScale(.small)
                            .foregroundStyle(StatusPalette.status(outcome))
                            .accessibilityHidden(true)
                    }
                    // Middle truncation: the slot narrows the column, and a
                    // tail cut would take "ago" — when it happened. The
                    // tooltip and VoiceOver keep the whole line.
                    Text(caption.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(caption.text)
                }
                .font(.caption)
                // A paused plan whose problem took the line above: the pause
                // gets its own, so neither state hides the other — on screen
                // or to VoiceOver.
                if let pauseNote = caption.pauseNote {
                    Text(pauseNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pauseNote)
                }
            }
        }
    }

    /// A row wears state, never identity. In rank: the in-flight spinner,
    /// the Mail dot for a problem the user has not seen, the pause mark. An
    /// otherwise idle plan wears nothing.
    @ViewBuilder
    private var marker: some View {
        if model.isRunning(planID: plan.id) {
            ProgressView().controlSize(.small)
        } else if let label = model.unseenProblemLabel(for: plan.id) {
            // Accent blue like Mail's unread dot, never red: the dot is an
            // invitation ("a problem you haven't seen"), and the alarm lives
            // in the subtitle's glyph and words. It clears when the plan's
            // page is opened or the next run succeeds. Its label names the
            // outcome — a completed-with-errors run is not a failure.
            Circle()
                .fill(Theme.tint)
                .frame(width: 9, height: 9)
                .help(label)
                .accessibilityLabel(label)
        } else if PlanStatus.showsPauseMarker(for: plan) {
            // Either kind of pause. The caption already says "Paused — …"
            // or "Paused until …".
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}
