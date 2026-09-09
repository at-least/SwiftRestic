import SwiftUI

struct PlanDetailView: View {
    @Environment(AppModel.self) private var model
    let planID: UUID
    let onEdit: () -> Void

    @State private var browsing: SnapshotBrowserTarget?
    @State private var comparing: SnapshotDiffTarget?

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
                }
            }
        }
        .sheet(item: $browsing) { target in
            SnapshotBrowserView(target: target)
                .environment(model)
        }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target)
                .environment(model)
        }
    }

    @ViewBuilder
    private func content(_ plan: BackupPlan) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            if let activity = model.activity[plan.id] {
                OperationProgressView(
                    title: activity.phase.displayName,
                    progress: activity.progress,
                    startedAt: activity.startedAt,
                    onCancel: { model.cancelBackup(planID: plan.id) }
                )
            }

            summaryTiles(plan)
            configurationCard(plan)
            snapshotsCard(plan)
        }
        .detailPane()
    }

    private func summaryTiles(_ plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: plan.repositoryID, planID: plan.id)
        let lastRun = model.configuration.runs.first { $0.planID == plan.id }
        let outcome = model.snapshotListingOutcome(for: plan.repositoryID)
        return HStack(spacing: Theme.Space.tile) {
            StatTile(
                title: "Last backup",
                value: plan.lastSuccessAt.map { Format.relative($0) } ?? "Never",
                systemImage: "clock.badge.checkmark",
                hue: plan.lastSuccessAt == nil ? Theme.warning : Theme.success
            )
            StatTile(
                title: "Next backup",
                // Tile-sized on the face, full form in the tooltip: the plain
                // timestamp truncated away its AM/PM exactly when that was
                // the part that said morning or evening.
                value: plan.nextRunDate.map { Format.tileTimestamp($0) } ?? "Manually",
                systemImage: "calendar",
                hue: plan.isEnabled ? Theme.tint : Theme.warning,
                help: plan.nextRunDate.map { Format.timestamp($0) }
            )
            // A count is only a fact once the listing it derives from has
            // succeeded; before that (or after a failure) the honest face is
            // "—", with the tooltip saying which.
            switch outcome {
            case .loaded:
                StatTile(
                    title: "Snapshots",
                    value: Format.count(snapshots.count),
                    systemImage: "camera.aperture"
                )
            case let .failed(message):
                StatTile(
                    title: "Snapshots",
                    value: "—",
                    systemImage: "camera.aperture",
                    hue: Theme.warning,
                    help: message
                )
            case .idle:
                StatTile(
                    title: "Snapshots",
                    value: "—",
                    systemImage: "camera.aperture",
                    help: "The snapshot list has not finished loading."
                )
            }
            StatTile(
                title: "Last run added",
                value: Format.bytes(lastRun?.dataAdded),
                systemImage: "arrow.up.doc"
            )
        }
    }

    private func configurationCard(_ plan: BackupPlan) -> some View {
        Card("Configuration", systemImage: "slider.horizontal.3") {
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
            Card("Snapshots", systemImage: "camera.on.rectangle.fill") {
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
        return Card("Snapshots", systemImage: "camera.on.rectangle.fill") {
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
                freshnessLabel(
                    loadedAt: loadedAt,
                    isLoading: model.loadingSnapshots.contains(repositoryID)
                )
                Button("Refresh") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
            }
        }
    }

    /// Every number on this card traces to the moment it was read: a
    /// "Updated 7:27 AM" caption, or a spinner while a refresh is in flight.
    @ViewBuilder
    private func freshnessLabel(loadedAt: Date?, isLoading: Bool) -> some View {
        if isLoading {
            ProgressView().controlSize(.small)
        } else if let loadedAt {
            Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Sortable list of snapshots with "Browse" and "Compare" affordances per row.
struct SnapshotTable: View {
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

    var body: some View {
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
        } else {
            VStack(spacing: 0) {
                if case let .failed(message) = loadOutcome {
                    staleListingStrip(message)
                }
                table
            }
        }
    }

    private var table: some View {
        Table(snapshots) {
                TableColumn("When") { snapshot in
                    Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 150, ideal: 164)

                TableColumn("ID") { snapshot in
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
            // Content-sized: a Table fills whatever height it is offered, so a
            // fixed minimum renders phantom empty rows under a short list —
            // which reads as a broken loading skeleton — and fixedSize asks a
            // scroll-backed Table for a degenerate zero height instead. The
            // constants are measured from the rendered table (~38pt header,
            // ~34pt inset-row pitch) and biased a point high on purpose: an
            // overestimate fails as a hair of padding, an underestimate clips
            // the last row's glyphs mid-line. The cap is where the table
            // scrolls its own overflow anyway.
            .frame(height: min(320, 38 + CGFloat(snapshots.count) * 34))
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
