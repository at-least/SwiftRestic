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
                    }
                    Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
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
            if let banner = model.banner {
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
        return HStack(spacing: 10) {
            StatTile(
                title: "Last backup",
                value: plan.lastSuccessAt.map { Format.relative($0) } ?? "Never",
                systemImage: "clock"
            )
            StatTile(
                title: "Next backup",
                value: plan.nextRunDate.map { Format.timestamp($0) } ?? "Manual",
                systemImage: "calendar"
            )
            StatTile(
                title: "Snapshots",
                value: Format.count(snapshots.count),
                systemImage: "camera.aperture"
            )
            StatTile(
                title: "Last run added",
                value: Format.bytes(lastRun?.dataAdded),
                systemImage: "arrow.up.doc"
            )
        }
    }

    private func configurationCard(_ plan: BackupPlan) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                DetailGrid {
                    DetailRow("Repository") {
                        if let repository = model.repository(id: plan.repositoryID) {
                            Text(repository.name)
                        } else {
                            Text("Not set").foregroundStyle(.orange)
                        }
                    }
                    DetailRow("Schedule", plan.isEnabled ? plan.schedule.summary : "Paused")
                    DetailRow("Retention", plan.retention.summary)
                    DetailRow("Excludes", "\(plan.excludePatterns.count) pattern(s)")
                    if !plan.hooks.isEmpty {
                        DetailRow("Hooks", "\(plan.hooks.filter(\.isRunnable).count) enabled")
                    }
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
                        Image(systemName: "folder")
                    }
                    .font(.callout)
                }
                if plan.sources.isEmpty {
                    Text("No folders chosen yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            Text("Configuration").font(.headline)
        }
    }

    private func snapshotsCard(_ plan: BackupPlan) -> some View {
        let snapshots = model.snapshots(for: plan.repositoryID, planID: plan.id)
        return GroupBox {
            SnapshotTable(
                snapshots: snapshots,
                isLoading: plan.repositoryID.map { model.loadingSnapshots.contains($0) } ?? false,
                onBrowse: { snapshot in
                    guard let repositoryID = plan.repositoryID else { return }
                    browsing = SnapshotBrowserTarget(repositoryID: repositoryID, snapshot: snapshot)
                },
                onCompare: { snapshot in
                    guard let repositoryID = plan.repositoryID else { return }
                    comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot)
                }
            )
            .padding(6)
        } label: {
            HStack {
                Text("Snapshots").font(.headline)
                Spacer()
                Button("Refresh") {
                    guard let repositoryID = plan.repositoryID else { return }
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Sortable list of snapshots with "Browse" and "Compare" affordances per row.
struct SnapshotTable: View {
    let snapshots: [Snapshot]
    var isLoading = false
    let onBrowse: (Snapshot) -> Void
    var onCompare: ((Snapshot) -> Void)?

    var body: some View {
        if isLoading, snapshots.isEmpty {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading snapshots…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if snapshots.isEmpty {
            Text("No snapshots yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            Table(snapshots) {
                TableColumn("When") { snapshot in
                    Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 150, ideal: 170)

                TableColumn("ID") { snapshot in
                    Text(snapshot.shortID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .width(min: 76, ideal: 84)

                TableColumn("Files") { snapshot in
                    Text(Format.count(snapshot.totalFilesProcessed))
                        .monospacedDigit()
                }
                .width(min: 60, ideal: 70)

                TableColumn("Size") { snapshot in
                    Text(Format.bytes(snapshot.totalBytesProcessed))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 84)

                TableColumn("Added") { snapshot in
                    Text(Format.bytes(snapshot.dataAdded))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 84)

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
                .width(onCompare == nil ? 72 : 150)
            }
            .frame(minHeight: 180, maxHeight: 320)
        }
    }
}
