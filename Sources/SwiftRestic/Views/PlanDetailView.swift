import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let planID: UUID
    let onEdit: () -> Void
    /// Sends the pane to Activity — the "Last backup" tile's destination,
    /// wired by RootView so this view owns no navigation of its own.
    var onShowRun: (() -> Void)? = nil

    @State private var browsing: SnapshotBrowserTarget?
    @State private var comparing: SnapshotDiffTarget?
    @State private var browsingFolders: FolderBrowserTarget?
    @State private var isConfirmingDeletion = false

    private var plan: BackupPlan? { model.plan(id: planID) }

    var body: some View {
        Group {
            if let plan {
                content(plan)
            } else {
                ContentUnavailableView("Plan not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(plan?.name ?? "Plan")
        // Opening the page is the Mail "read": whatever failure the sidebar's
        // dot was announcing is seen now — honestly, because the status row
        // under the tiles shows that failure for as long as it stands. The
        // dot for a run that fails while the page is already open stays,
        // like a message arriving into the mailbox you are reading — leaving
        // and returning clears it.
        .onAppear { model.markProblemSeen(planID: planID) }
        .toolbar {
            ToolbarItemGroup {
                if let plan {
                    if model.isRunning(planID: plan.id) {
                        Button("Cancel", systemImage: "stop.fill") {
                            model.cancelBackup(planID: plan.id)
                        }
                    } else {
                        Button("Back Up Now", systemImage: "arrow.up.circle.fill") {
                            model.runBackup(planID: plan.id)
                        }
                        .disabled(!plan.isConfigurationComplete || !model.isResticAvailable)
                        .labelStyle(.titleAndIcon)
                        .help("Run this plan's backup now")
                    }
                    if plan.isEnabled {
                        Button("Pause Schedule", systemImage: "pause.circle") {
                            model.setPlanEnabled(id: plan.id, isEnabled: false)
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Stop scheduled runs — Back Up Now still works")
                    } else {
                        Button("Resume Schedule", systemImage: "play.circle") {
                            model.setPlanEnabled(id: plan.id, isEnabled: true)
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Run this plan on its schedule again")
                    }
                    Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                        .labelStyle(.titleAndIcon)
                        .help("Change this plan's folders, schedule and retention")
                    // Deletion was sidebar-context-menu-only, while the less
                    // destructive repository removal sat in its pane's own
                    // toolbar — the more destructive act had the worse
                    // affordance.
                    Button("Delete Plan", systemImage: "trash", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Remove this plan and its schedule; snapshots are not deleted")
                }
            }
        }
        .sheet(item: $browsing) { target in
            SnapshotBrowserView(target: target)
                .environment(model)
        }
        .sheet(item: $browsingFolders) { target in
            FolderBrowserView(target: target)
                .environment(model)
        }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target)
                .environment(model)
        }
        .confirmationDialog(
            "Delete “\(plan?.name ?? "")”?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Plan", role: .destructive) {
                if let plan { model.deletePlan(id: plan.id) }
            }
        } message: {
            // Same promise the sidebar's dialog makes, plus the one thing this
            // pane can see that the sidebar cannot: a run in flight.
            Text(
                model.isRunning(planID: planID)
                    ? "The running backup will be stopped and recorded as cancelled. Snapshots already written to the repository are not deleted."
                    : "The plan and its schedule are removed. Snapshots already written to the repository are not deleted."
            )
        }
    }

    /// The running-operation strip, as its own view. It reads only this
    /// plan's activity and progress — both inside this body, so a restic
    /// progress tick (~1/sec) re-renders the strip instead of the whole
    /// pane (progress lives in its own observable storage precisely so
    /// phase-reading views — the strip's title, the sidebar's rows — stay
    /// untouched by it), and `content`'s snapshot table never reruns per
    /// tick.
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
    /// and a retry is the toolbar's Back Up Now a few points away.
    private struct PlanProblemRow: View {
        let summary: PlanProblemSummary
        var onShowInActivity: (() -> Void)?

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                // Activity's glyph and hue for the outcome. Beside a headline
                // that names it: decoration to VoiceOver.
                Image(systemName: summary.outcome.symbolName ?? "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChartPalette.status(summary.outcome))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(summary.headline)
                            .font(.headline)
                        Text(Format.relative(summary.finishedAt))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help(Format.timestamp(summary.finishedAt))
                    }
                    if let message = summary.message {
                        // Middle truncation, as Activity's Detail column does
                        // for failures: restic's messages lead with the
                        // subject and end with the verdict.
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
    /// stays as it was — only the "Last backup" tile, which can land on a
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

            summaryTiles(plan)
            // The plan's standing problem, on the plan's own page: present
            // exactly while the sidebar names it, gone once a run succeeds.
            if let problem = model.currentProblem(for: plan.id) {
                PlanProblemRow(summary: PlanStatus.summary(of: problem), onShowInActivity: showInActivity(problem))
            }
            SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: plan.repositoryID))
            configurationCard(plan)
            snapshotsCard(plan)
        }
        .detailPane()
    }

    private func summaryTiles(_ plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: plan.repositoryID, planID: plan.id)
        let lastRun = model.configuration.runs.first { $0.planID == plan.id }
        let outcome = model.snapshotListingOutcome(for: plan.repositoryID)
        // The scheduler's own answer, so a paused plan reads "Paused" and one
        // it skips never shows a date. Tile-sized on the face, full form in
        // the tooltip: the plain timestamp truncated away its AM/PM exactly
        // when that was the part that said morning or evening.
        let next = PlanStatus.nextBackupTile(
            for: plan,
            existingRepositoryIDs: Set(model.configuration.repositories.map(\.id))
        )
        return HStack(spacing: Theme.Space.tile) {
            lastBackupTile(plan)
            StatTile(title: "Next backup", value: next.value, help: next.help)
            // A count is only a fact once the listing it derives from has
            // succeeded; before that (or after a failure) the honest face is
            // "—", with the tooltip saying which.
            StatTile.snapshots(outcome: outcome, loadedCount: snapshots.count)
            StatTile(
                title: "Last run added",
                // The run record is the primary source. When the global
                // history cap has evicted this plan's newest record — a busy
                // plan can do that to a quiet neighbour — the newest
                // snapshot's own summary answers the same question, because a
                // snapshot carries what the backup that wrote it added.
                value: Format.bytes(lastRun?.dataAdded ?? snapshots.first?.dataAdded)
            )
        }
    }

    /// Arq's "View Latest Backup Record…" as a tile: the timestamp is a
    /// handle to its run's record. Only when a record exists to land on —
    /// "Never" has nowhere to go and stays a plain tile.
    @ViewBuilder
    private func lastBackupTile(_ plan: BackupPlan) -> some View {
        let value = plan.lastSuccessAt.map { Format.relative($0) } ?? "Never"
        // The destination must be the run the tile's value claims — the
        // newest backup that stamped `lastSuccessAt`. That is the same
        // predicate `markPlanRun` uses: a snapshot-writing run whose
        // after-hooks then failed still counts (`.completedWithErrors`),
        // because the stamp happens before the downgrade. A `.failed` run
        // never stamped, so landing on it would break the promise the
        // tile's value makes.
        let lastSuccessfulRun = model.configuration.runs
            .filter {
                $0.planID == plan.id && $0.kind == .backup
                    && ($0.outcome == .succeeded || $0.outcome == .completedWithErrors)
            }
            .max { $0.startedAt < $1.startedAt }
        if let lastSuccessfulRun, let onShowRun {
            Button {
                router.activityShowsProblemsOnly = false
                router.activityFocusRunID = lastSuccessfulRun.id
                onShowRun()
            } label: {
                StatTile(
                    title: "Last backup",
                    value: value,
                    trailingSymbol: "chevron.forward"
                )
            }
            .buttonStyle(HoverableButtonStyle())
            .help("Show this backup's run in Activity")
            .accessibilityLabel("Last backup \(value). Show its run in Activity")
        } else {
            StatTile(title: "Last backup", value: value)
        }
    }

    private func configurationCard(_ plan: BackupPlan) -> some View {
        Card("Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                DetailGrid {
                    DetailRow("Repository") {
                        if let repository = model.repository(id: plan.repositoryID) {
                            Text(repository.name)
                        } else {
                            Text("Not set").foregroundStyle(Theme.warning)
                        }
                    }
                    DetailRow("Schedule", plan.isEnabled ? plan.schedule.summary : "Paused")
                    DetailRow("Retention", plan.retention.summary)
                    DetailRow("Excludes", Format.plural(plan.excludePatterns.count, "pattern"))
                    if !plan.hooks.isEmpty {
                        DetailRow("Hooks", "\(plan.hooks.filter(\.isRunnable).count) enabled")
                    }
                }

                // The same projection the editor shows: the shorthand above is
                // buckets, this sentence is what the buckets mean.
                if plan.retention.isEnabled,
                   let projection = RetentionProjection.project(policy: plan.retention, schedule: plan.schedule)
                {
                    Text(
                        "≈ \(projection.keptSnapshots) snapshots would survive, reaching back about \(Format.plural(projection.historyDays, "day")) at this schedule."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text("Backing up")
                    .font(.subheadline.weight(.medium))
                ForEach(plan.sources, id: \.self) { source in
                    Label {
                        Text((source as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Theme.tint)
                    }
                    .font(.callout)
                }
                if plan.sources.isEmpty {
                    Text("No folders chosen yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func snapshotsCard(_ plan: BackupPlan) -> some View {
        if let repositoryID = plan.repositoryID {
            snapshotsCard(repositoryID: repositoryID, plan: plan)
        } else {
            // A retry could never succeed, so the card says what is actually
            // missing instead of offering buttons that lie.
            Card("Snapshots") {
                Text("No repository set — snapshots appear once the plan points at one.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }

    private func snapshotsCard(repositoryID: UUID, plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: repositoryID, planID: plan.id)
        let repositoryTotal = model.snapshots(for: repositoryID).count
        let outcome = model.snapshotListingOutcome(for: repositoryID)
        let loadedAt = model.snapshotsLoadedAt(for: repositoryID)
        return Card("Snapshots") {
            SnapshotTable(
                snapshots: snapshots,
                isLoading: model.loadingSnapshots.contains(repositoryID),
                loadOutcome: outcome,
                // Both are true statements, but only one is the user's: a
                // repository with snapshots from before this plan existed (or
                // from other restic clients) must not read as "nothing there".
                emptyMessage: repositoryTotal == 0
                    ? "No snapshots yet — they appear here after the first backup."
                    : "This repository has snapshots, but none from this plan yet.",
                onBrowse: { snapshot in
                    browsing = SnapshotBrowserTarget(repositoryID: repositoryID, snapshot: snapshot)
                },
                onCompare: { snapshot in
                    comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot)
                },
                onRetry: {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
            )
        } accessory: {
            HStack(spacing: 8) {
                // Every number on this card traces to the moment it was read:
                // an "Updated 7:27 AM" caption, or a spinner while a refresh
                // is in flight.
                SnapshotFreshnessLabel(
                    loadedAt: loadedAt,
                    isLoading: model.loadingSnapshots.contains(repositoryID)
                )
                // The folder-first entry: pick a folder, then flip through the
                // snapshots that contain it. Needs at least one snapshot to
                // stand in as the newest version.
                Button("Browse Folders…") {
                    browsingFolders = FolderBrowserTarget(repositoryID: repositoryID, planID: plan.id)
                }
                .controlSize(.small)
                .disabled(snapshots.isEmpty)
                .help("Walk this plan's folders and flip through the snapshots that contain them")
                Button("Refresh") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Sortable, filterable list of snapshots with "Browse" and "Compare"
/// affordances per row — as buttons, in a context menu, and on double-click.
struct SnapshotTable: View {
    /// For the completeness column's run lookup. Both hosts (the plan pane
    /// and the repository pane's All Snapshots) sit in the main window's
    /// environment.
    @Environment(AppModel.self) private var model
    let snapshots: [Snapshot]
    var isLoading = false
    /// The owning repository's last settled listing outcome. Without it, a
    /// failed refresh renders as the empty list it never was: "No snapshots
    /// yet." is a lie when the truth is "could not be read".
    var loadOutcome: SnapshotListingOutcome = .idle
    /// Shown when the listing succeeded but produced no rows for this view's
    /// scope — a plan's tag filter, say.
    var emptyMessage = "No snapshots yet."
    let onBrowse: (Snapshot) -> Void
    var onCompare: ((Snapshot) -> Void)?
    var onRetry: (() -> Void)?

    /// Newest first by default: the table is scanned by recency, and a year
    /// of hourly snapshots is otherwise a scroll hunt for last Tuesday.
    @State private var sortOrder: [KeyPathComparator<Snapshot>] = [
        KeyPathComparator(\Snapshot.time, order: .reverse)
    ]
    @State private var filterText = ""
    @State private var selection: Snapshot.ID?
    /// The snapshots' rendered date text, rebuilt only when the listing
    /// changes. The filter matches the displayed date, and re-formatting
    /// every snapshot on every keystroke was a formatter storm on
    /// year-sized histories — a year of hourly snapshots is ~8.7k
    /// `.formatted` calls per character typed.
    @State private var displayTimes: [Snapshot.ID: String] = [:]

    /// The sort does not apply itself: `Table(sortOrder:)` only reports the
    /// user's chosen order, so the rows are filtered and sorted here.
    private var visibleSnapshots: [Snapshot] {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        let base = needle.isEmpty ? snapshots : snapshots.filter { snapshot in
            snapshot.id.localizedCaseInsensitiveContains(needle)
                || displayTimes[snapshot.id]?
                    .localizedCaseInsensitiveContains(needle) == true
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        // One filter+sort per render: the empty test, the filter bar's count,
        // the table and its height all read the visible rows — a computed
        // property would re-evaluate the sort at every access (the hoist
        // SnapshotDiffView documents for its own candidates).
        let visible = visibleSnapshots
        // Read once per render, like `visible`: every cell's lookup then
        // hits the same dictionary.
        let runs = model.backupRunsBySnapshot
        return content(visible, runs: runs)
            .onChange(of: snapshots, initial: true) { _, snapshots in
                var times: [Snapshot.ID: String] = [:]
                times.reserveCapacity(snapshots.count)
                for snapshot in snapshots {
                    times[snapshot.id] = Format.timestamp(snapshot.time)
                }
                displayTimes = times
            }
    }

    @ViewBuilder
    private func content(_ visible: [Snapshot], runs: [String: RunRecord]) -> some View {
        if case let .failed(message) = loadOutcome, snapshots.isEmpty {
            failureRow(message)
        } else if isLoading, snapshots.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading snapshots…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if snapshots.isEmpty {
            // The two "no rows" moments get different words: before the first
            // listing settles, nothing is known yet; after it has, an empty
            // result is the fact. The stat tiles above make the same split.
            if case .idle = loadOutcome {
                Text("The snapshot list hasn't loaded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        } else if visible.isEmpty {
            // The listing succeeded but the filter matches nothing: say so
            // with the way back, rather than a content-less table frame that
            // reads as a broken load.
            VStack(alignment: .leading, spacing: 6) {
                Text("No snapshots match the filter.")
                    .foregroundStyle(.secondary)
                Button("Clear Filter") { filterText = "" }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                if case let .failed(message) = loadOutcome {
                    staleListingStrip(message)
                }
                filterBar(visible)
                table(visible, runs: runs)
            }
        }
    }

    private func filterBar(_ visible: [Snapshot]) -> some View {
        HStack(spacing: 8) {
            TextField(
                "Filter by ID or date",
                text: $filterText,
                prompt: Text(verbatim: "Filter by ID or date")
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(maxWidth: 220)
            // A selection that survives its own row leaving the filter would
            // strand the context menu and double-click on an id the table
            // no longer shows.
            .onChange(of: filterText) { selection = nil }

            if visible.count != snapshots.count {
                Text("\(Format.count(visible.count)) of \(Format.plural(snapshots.count, "snapshot"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.bottom, 6)
    }

    private func table(_ visible: [Snapshot], runs: [String: RunRecord]) -> some View {
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
                // Only an incomplete snapshot wears a glyph, the way
                // Activity's leading outcome column only marks trouble.
                TableColumn("") { snapshot in
                    SnapshotCompletenessMark(run: runs[snapshot.id])
                }
                .width(24)

                // Sortable where a person scans: when it ran, and which
                // snapshot it is. The numeric columns stay fixed because the
                // model's values are optional (a snapshot can lack a summary)
                // and a table sorter cannot sort "—".
                TableColumn("When", value: \.time) { snapshot in
                    // The displayTimes cache owns this spelling — it is what
                    // the filter matches against — so the cell reads it
                    // instead of re-formatting per row per render. The
                    // fallback covers the first render, before the cache's
                    // onChange has run; both spellings are identical.
                    Text(displayTimes[snapshot.id] ?? Format.timestamp(snapshot.time))
                        .monospacedDigit()
                }
                .width(min: 150, ideal: 164)

                TableColumn("ID", value: \.id) { snapshot in
                    Text(snapshot.shortID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .width(min: 76, ideal: 82)

                TableColumn("Files") { snapshot in
                    Text(Format.count(snapshot.totalFilesProcessed))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 66)

                TableColumn("Size") { snapshot in
                    Text(Format.bytes(snapshot.totalBytesProcessed))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 78)

                TableColumn("Added") { snapshot in
                    Text(Format.bytes(snapshot.dataAdded))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 78)

                TableColumn("") { snapshot in
                    HStack(spacing: 6) {
                        Button("Browse") { onBrowse(snapshot) }
                        if let onCompare {
                            Button("Compare") { onCompare(snapshot) }
                                .help("What changed since the previous snapshot")
                        }
                    }
                    .controlSize(.small)
                }
                // 126pt fits the two small buttons without crowding them.
                .width(min: 116, ideal: 126, max: 128)
            }
            // The row context menu and double-click mirror the two buttons,
            // so the table's most-repeated actions have a keyboard-and-menu
            // path and not only a mouse-only pair of small buttons.
            // Return on a selected row opens it, the same grammar the
            // browser sheet speaks — the context menu alone is not a
            // keyboard path.
            .onKeyPress(.return) {
                guard let selection,
                      let snapshot = visible.first(where: { $0.id == selection })
                else { return .ignored }
                onBrowse(snapshot)
                return .handled
            }
            .contextMenu(forSelectionType: Snapshot.ID.self) { ids in
                if let id = ids.first, ids.count == 1,
                   let snapshot = visible.first(where: { $0.id == id }) {
                    Button("Browse Contents…") { onBrowse(snapshot) }
                    if let onCompare {
                        Button("Compare with Previous…") { onCompare(snapshot) }
                    }
                    Divider()
                    Button("Copy Snapshot ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                }
            } primaryAction: { ids in
                guard let id = ids.first, ids.count == 1,
                      let snapshot = visible.first(where: { $0.id == id })
                else { return }
                onBrowse(snapshot)
            }
            // Content-sized: a Table fills whatever height it is offered, so a
            // fixed minimum renders phantom empty rows under a short list —
            // which reads as a broken loading skeleton — and fixedSize asks a
            // scroll-backed Table for a degenerate zero height instead. The
            // constants are measured from the rendered table (~38pt header,
            // ~34pt inset-row pitch) and biased a point high on purpose: an
            // overestimate fails as a hair of padding, an underestimate clips
            // the last row's glyphs mid-line. Sized from the *visible* rows so
            // a filter that narrows 300 rows to 2 shrinks the frame with it,
            // and the cap is where the table scrolls its own overflow anyway.
            .frame(height: min(320, 38 + CGFloat(visible.count) * 34))
            .alternatingRowBackgrounds(.disabled)
    }

    /// The whole card's truth when nothing can be listed: what went wrong,
    /// restic's own words, and the way back.
    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("Snapshots could not be read.")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                // A refresh that starts from a failure keeps the failure
                // visible: the spinner sits inside the error row instead of
                // replacing it, so a five-minute refresh cycle cannot make
                // the card throb between "broken" and "fine".
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    /// Rows from an earlier successful listing stay up beside a failure —
    /// stale snapshots are worth more than a blank card — as long as a strip
    /// says exactly how old they are.
    private func staleListingStrip(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text("Showing the last successful listing — the latest attempt failed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(message)
            Spacer(minLength: 12)
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if let onRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
        }
        .padding(.bottom, 6)
    }
}
