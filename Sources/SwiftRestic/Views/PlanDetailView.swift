import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now
    let planID: UUID

    /// The network share the plan's folder is on while mounted
    /// (`VolumePresence.mountedShare`), read off the main actor.
    @State private var mountedShare: MountedShare?
    /// The plan path last read as gone from this Mac, beside
    /// `mountedShare`: a stalled share can hold the read. The path, not a
    /// flag: this view outlives a switch to another plan.
    @State private var missingPath: String?
    /// Each share's password as typed, by volume name.
    @State private var sharePasswords: [String: String] = [:]
    @State private var sharePasswordFailure: String?
    @State private var isSavingSharePassword = false

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
        // says which folder that is. None on the Backups tab: the selected
        // backup's row already says its moment.
        .navigationTitle(plan.map { model.label(of: $0) } ?? "Plan")
        .navigationSubtitle(plan.map(subtitle) ?? "")
        .pageTabPicker(router.tabBinding(for: .plan(planID)), tabs: SidebarItem.plan(planID).pageTabs)
        .allBackupsSearch()
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
            .help("Stop this backup (⌘.)")
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
        @Environment(AppRouter.self) private var router
        @Environment(\.now) private var now
        let summary: PlanProblemSummary
        let run: RunRecord
        /// How many backups in a row ended this way (`RunRecord.problemStretch`).
        let inARow: Int

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
                // The failure's one known fix, left of the way to its record:
                // the row's one prominent button.
                if let fix = model.fix(for: run) {
                    RunFixButton(fix: fix)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                // The visible title is the accessible name, as on the
                // Restore pane's incomplete-backup strip: a longer label
                // would hide "Show in Activity" from Voice Control.
                Button("Show in Activity") { router.focusRun(run.id) }
                    .controlSize(.small)
                    .help("See every message from this backup in Activity")
            }
        }
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
                        inARow: problem.problemStretch!
                    )
                }
            }
            if model.snapshotListingOutcome(for: plan.repositoryID) != .loaded {
                Section { SnapshotListingCaveat(repositoryID: plan.repositoryID) }
            }
            folderNotices(plan)
            scheduleSection(plan)
            excludedItemsSection(plan)
        }
        .formStyle(.grouped)
        .task(id: plan.path) {
            let path = plan.path
            let (share, isMissing) = await Task.detached {
                (
                    VolumePresence.mountedShare(holding: ResticService.expandTilde(path)),
                    !path.isEmpty && !AppModel.sourceExists(path)
                )
            }.value
            guard !Task.isCancelled else { return }
            mountedShare = share
            missingPath = isMissing ? path : nil
        }
    }

    /// The label is the path when two plans of a location share a folder
    /// name (`BackupPlan.label`).
    private func subtitle(_ plan: BackupPlan) -> String {
        guard router.tab(of: .plan(planID)) == .overview else { return "" }
        let path = (plan.resolvedPath as NSString).abbreviatingWithTildeInPath
        return path == model.label(of: plan) ? "" : path
    }

    /// What the folder needs before it can be backed up.
    @ViewBuilder
    private func folderNotices(_ plan: BackupPlan) -> some View {
        // A folder that is gone fails every backup.
        let isMissing = missingPath == plan.path
        let accessNotice = model.fullDiskAccessNotice(for: plan.path)
        if isMissing || accessNotice != nil {
            Section {
                if isMissing {
                    WarningLine(text: AppModel.missingSourcesWarning)
                }
                if let accessNotice {
                    HStack(alignment: .firstTextBaseline) {
                        WarningLine(text: accessNotice)
                        Spacer(minLength: 8)
                        FullDiskAccessButton()
                            .controlSize(.small)
                    }
                }
            }
        }
        // A folder on a network share: its password, so a backup can
        // reconnect it.
        if let row = model.shareRow(for: plan.resolvedPath, mounted: mountedShare) {
            let typed = sharePasswords[row.share.volumeName] ?? ""
            Section {
                NetworkSharePasswordRows(
                    url: row.share.url,
                    isSaved: row.isSaved,
                    password: Binding(
                        get: { typed },
                        set: {
                            sharePasswords[row.share.volumeName] = $0
                            sharePasswordFailure = nil
                        }
                    )
                )
                if let sharePasswordFailure {
                    // A form's inline error: red text, without a glyph.
                    Text(sharePasswordFailure)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Save Password") { Task { await saveSharePassword(typed, for: row.share) } }
                        .controlSize(.small)
                        .disabled(typed.isEmpty || isSavingSharePassword)
                }
            }
        }
    }

    private func saveSharePassword(_ password: String, for share: MountedShare) async {
        isSavingSharePassword = true
        defer { isSavingSharePassword = false }
        do {
            try await model.saveNetworkShare(share, password: password)
            sharePasswords[share.volumeName] = nil
        } catch {
            sharePasswordFailure = error.localizedDescription
        }
    }

    /// Saved as it changes, as How often is. The list holds only what the
    /// user added; the footer names what the app leaves out.
    private func excludedItemsSection(_ plan: BackupPlan) -> some View {
        Section {
            PathListEditor(paths: Binding(
                get: { plan.excludePatterns },
                set: { patterns in model.updatePlan(plan.id) { $0.excludePatterns = patterns } }
            ))
        } header: {
            Text("Excluded Items")
        } footer: {
            Text(PlanSkips.always)
                .foregroundStyle(.secondary)
                .help(PlanSkips.alwaysHelp)
        }
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
        Section("Schedule") {
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
            // Manually has no next backup: the row would restate How often.
            if plan.isScheduled {
                let next = PlanStatus.nextBackupTile(
                    for: plan,
                    existingRepositoryIDs: Set(model.configuration.repositories.map(\.id)),
                    hold: model.scheduleHold(repositoryID: plan.repositoryID, now: now),
                    isBackingUp: model.activity[plan.id] != nil,
                    now: now
                )
                LabeledContent("Next backup") {
                    Text(next.value)
                        .accessibilityIdentifier(AccessibilityID.Plan.nextBackup)
                        .modifier(TileHelp(help: next.help))
                }
            }
        }
    }

    private func lastBackupValue(_ plan: BackupPlan, snapshots: [Snapshot]) -> some View {
        // The moment every surface's "Last backup" counts from, so history
        // the plan arrived with is not "Never" here.
        let value = Format.ago(PlanStatus.lastBackupAt(plan: plan, latestSnapshotTime: snapshots.first?.time), now: now)
        let lastSuccessfulRun = PlanStatus.lastBackupRun(planID: plan.id, in: model.configuration.runs)
        // The newest snapshot's summary stands in when the history cap has
        // evicted this plan's newest run (a busy plan can do that to a quiet
        // neighbour) or the history arrived with the repository.
        let added = (lastSuccessfulRun?.dataAdded ?? snapshots.first?.dataAdded).flatMap { $0 > 0 ? $0 : nil }
        return Text(added.map { "\(value) · added \(Format.bytes($0))" } ?? value)
    }

    /// While a listing is read, a value read before stays with no spinner
    /// beside it.
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
                    Text(PlanStatus.noneFromThisPlanFact)
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

/// A plan's exclude list: + chooses items in a panel, as Time Machine's
/// exclusions do, a drop from Finder adds them, − removes the selected rows.
/// Every entry is an item's own path, glob characters escaped
/// (`ResticService.globEscaped`): "a[1].txt" would otherwise match "a1.txt"
/// and not itself. A pattern not added here still lists and removes.
private struct PathListEditor: View {
    @Binding var paths: [String]

    @State private var selection: Set<String> = []
    @State private var isDropTargeted = false

    private static let rowHeight: CGFloat = 22
    /// The list scrolls past them rather than growing the page.
    private static let rowsInView: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .contextMenu(forSelectionType: String.self) { items in
                Button("Remove") { remove(items) }
            }
            .accessibilityLabel("Excluded Items")
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .overlay {
                if paths.isEmpty {
                    Text("Drag folders and files here, or click +.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: Self.rowsInView * Self.rowHeight)
            .dropDestination(for: URL.self) { urls, _ in
                // Only file URLs are paths: a dragged web link's `.path`
                // would silently become a pattern matching nothing.
                let filePaths = urls.filter(\.isFileURL).map(\.path)
                guard !filePaths.isEmpty else { return false }
                addPaths(filePaths)
                return true
            } isTargeted: { isDropTargeted = $0 }
            Divider()
            HStack(spacing: 0) {
                ListBarButton(symbol: "plus", title: "Choose items") { browse() }
                    .accessibilityIdentifier(AccessibilityID.PathList.add)
                Divider()
                    .frame(height: 14)
                ListBarButton(symbol: "minus", title: "Remove") { remove(selection) }
                    .disabled(selection.isEmpty)
                Spacer()
            }
            .padding(.leading, 2)
            .frame(height: 26)
        }
        .overlay {
            if isDropTargeted {
                Rectangle().strokeBorder(Theme.tint, lineWidth: 2)
            }
        }
    }

    private func remove(_ items: Set<String>) {
        paths.removeAll { items.contains($0) }
        selection.subtract(items)
    }

    /// One write to `paths`: the plan's page saves on each.
    private func addPaths(_ rawPaths: [String]) {
        var added = paths
        for value in rawPaths.map(ResticService.globEscaped) where !added.contains(value) {
            added.append(value)
        }
        paths = added
    }

    /// `NSOpenPanel`, not SwiftUI's `fileImporter`: the list needs
    /// multi-select across both files and folders.
    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders and files to exclude from backups"
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        addPaths(panel.urls.map(\.path))
    }
}

private struct ListBarButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}
