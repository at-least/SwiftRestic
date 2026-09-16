import SwiftUI

/// The split view's sidebar: the five sections (Overview, Backup Plans,
/// Restore, Repositories, Tools), the restore disclosure groups, the context
/// menus and the Add footer.
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

    let onEditPlan: (BackupPlan) -> Void
    let onNewPlan: () -> Void
    let onEditRepository: (Repository) -> Void
    let onNewRepository: () -> Void
    /// Arms the deletion confirmation — the sidebar's menus must not be a
    /// faster way around the detail pages' own confirmations.
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
                since: Date.now.addingTimeInterval(-7 * 86_400)
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

            Section("Repositories") {
                ForEach(model.configuration.repositories) { repository in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repository.name)
                                .lineLimit(1)
                            Text(repository.displayLocation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: repository.kind.symbolName)
                            .foregroundStyle(Theme.tint)
                    }
                    .tag(SidebarItem.repository(repository.id))
                    .contextMenu { repositoryContextMenu(repository) }
                }
                if model.configuration.repositories.isEmpty, !model.isBootstrapping {
                    Text("No repositories yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Console and Activity are peers, not a lone tool plus a footnote.
            // Console carries the toolbar's guards: with no repository it
            // opened a pane whose only content was "Choose…", and a tool that
            // can never work reads as breakage, not emptiness.
            Section("Tools") {
                Label("restic Console", systemImage: "apple.terminal")
                    .tag(SidebarItem.console)
                    .disabled(model.configuration.repositories.isEmpty || !model.isResticAvailable)
                Label("Activity", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.activity)
                    // The window's unread badge, wired to the same 7-day
                    // window the tray dot, the Problems tile and the menu's
                    // problem line share: one count, so no surface can claim
                    // trouble another denies. It also yields to the
                    // unconfigured state like the tray's problem face does —
                    // a removed repository's old failures must not summon
                    // setup-bound attention — and stays silent when clean.
                    .badge(
                        problemCount > 0 && !model.configuration.repositories.isEmpty
                            ? Text(verbatim: "\(problemCount)")
                            : nil
                    )
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Backup Plan…") { onNewPlan() }
                    .disabled(model.configuration.repositories.isEmpty)
                Button("Add Repository…") { onNewRepository() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            if !model.isResticAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help(model.binaryProblem ?? "restic not found")
                    .accessibilityLabel(model.binaryProblem ?? "restic not found")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func planContextMenu(_ plan: BackupPlan) -> some View {
        Button("Back Up Now") { model.runBackup(planID: plan.id) }
            // Same guard the menu bar applies: an incomplete plan has nothing
            // to run, and an error banner is not a substitute for a disabled
            // item.
            .disabled(model.isRunning(planID: plan.id) || !plan.isConfigurationComplete)
        Button("Edit…") { onEditPlan(plan) }
        // The sidebar row already wears a pause icon when disabled; the menu
        // is where that state is changed. Manual runs stay possible either way.
        Button(plan.isEnabled ? "Pause Scheduled Runs" : "Resume Scheduled Runs") {
            model.setPlanEnabled(id: plan.id, isEnabled: !plan.isEnabled)
        }
        Divider()
        Button("Delete Plan", role: .destructive) { onDeletePlan(plan) }
    }

    @ViewBuilder
    private func repositoryContextMenu(_ repository: Repository) -> some View {
        Button("Edit…") { onEditRepository(repository) }
        Button("Refresh") { Task { await model.refreshSnapshots(repositoryID: repository.id) } }
        Divider()
        Button("Remove from SwiftRestic…", role: .destructive) {
            onRemoveRepository(repository)
        }
    }

    // MARK: - Restore

    /// Arq's RESTORE section: each repository expands to its backup
    /// records, and picking a record shows its files in the detail pane.
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
                    Text(Format.firstSentence(message))
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
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
                ForEach(listing) { snapshot in
                    RestoreRecordRow(snapshot: snapshot)
                        .tag(SidebarItem.restoreSnapshot(repository.id, snapshot.id))
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
                Image(systemName: repository.kind.symbolName)
                    .foregroundStyle(Theme.tint)
            }
        }
    }
}

/// One dated backup record in the Restore section — the row whose selection
/// fills the detail pane with that record's files. One line, like Arq's: the
/// checkmark and the moment are the whole record at sidebar size.
private struct RestoreRecordRow: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.caption)
                .help("This backup is complete and restorable")
            Text(Format.timestamp(snapshot.time))
                .lineLimit(1)
        }
        .help("Browse this backup's files and restore from it")
    }
}

private struct PlanSidebarRow: View {
    @Environment(AppModel.self) private var model
    let plan: BackupPlan

    var body: some View {
        HStack(spacing: 8) {
            // A row wears state, never identity. In rank: the in-flight
            // spinner, the Mail dot for a failure the user has not seen, the
            // pause mark. An otherwise idle plan wears nothing.
            if model.isRunning(planID: plan.id) {
                ProgressView().controlSize(.small)
            } else if model.showsProblemDot(for: plan.id) {
                // Accent blue like Mail's unread dot, never red: the dot is
                // an invitation ("a failure you haven't seen"), and the alarm
                // lives in the subtitle's words and hue. It clears when the
                // plan's page is opened or the next run succeeds.
                Circle()
                    .fill(Theme.tint)
                    .frame(width: 9, height: 9)
                    .accessibilityLabel("A failed run you haven't seen")
            } else if !plan.isEnabled {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.name.isEmpty ? "Untitled Plan" : plan.name)
                    .lineLimit(1)
                Text(subtitle.text)
                    .font(.caption)
                    .foregroundStyle(subtitle.hue)
                    .lineLimit(1)
            }
        }
    }

    // Words and hue move together, so the dot is never a state's only
    // non-text signal.
    private var subtitle: (text: String, hue: Color) {
        if let activity = model.activity[plan.id] {
            return (activity.phase.displayName, .secondary)
        }
        // Paused wears no icon any more; the subtitle is where the state
        // is named.
        if !plan.isEnabled {
            return ("Paused — \(plan.schedule.summary)", .secondary)
        }
        // A standing failure is the row's real news, named for as long as it
        // stands — seen or not — in the warning hue.
        if let problem = model.currentProblem(for: plan.id) {
            return ("\(problem.outcome.displayName) — \(Format.relative(problem.finishedAt))", Theme.warning)
        }
        if plan.lastSuccessAt != nil {
            return ("Last backup \(Format.relative(plan.lastSuccessAt))", .secondary)
        }
        return (plan.schedule.summary, .secondary)
    }
}
