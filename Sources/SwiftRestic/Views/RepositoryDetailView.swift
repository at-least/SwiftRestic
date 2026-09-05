import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID
    let onEdit: () -> Void

    @State private var browsing: SnapshotBrowserTarget?
    @State private var comparing: SnapshotDiffTarget?
    @State private var isConfirmingRemoval = false

    private var repository: Repository? { model.repository(id: repositoryID) }

    var body: some View {
        Group {
            if let repository {
                content(repository)
            } else {
                ContentUnavailableView("Repository not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(repository?.name ?? "Repository")
        .toolbar {
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                Menu("Maintenance", systemImage: "wrench.and.screwdriver") {
                    Button("Check Structure") {
                        model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 0)
                    }
                    Button("Check + Read 5% of Data") {
                        model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 5)
                    }
                    Button("Check + Read All Data") {
                        model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 100)
                    }
                    Divider()
                    Button("Prune Now") { model.runMaintenance(id: repositoryID, task: .prune) }
                    Button("Remove Stale Locks") { model.unlockRepository(id: repositoryID) }
                }
                .disabled(model.busyRepositoryIDs.contains(repositoryID))
                Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
            }
        }
        .sheet(item: $browsing) { target in
            SnapshotBrowserView(target: target).environment(model)
        }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target).environment(model)
        }
        #if DEBUG
        .onChange(of: model.snapshots(for: repositoryID).count, initial: true) { _, _ in
            applyCaptureSheetOverride()
        }
        #endif
        .confirmationDialog(
            "Remove this repository from SwiftRestic?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.deleteRepository(id: repositoryID) }
        } message: {
            Text("The backup data itself is not deleted. Plans pointing at it will be paused.")
        }
    }

    @ViewBuilder
    private func content(_ repository: Repository) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let banner = model.banner {
                BannerView(banner: banner)
            }

            let stats = model.repositoryStats[repositoryID]
            let snapshots = model.snapshots(for: repositoryID)

            HStack(spacing: 10) {
                StatTile(
                    title: "Repository size",
                    value: Format.bytes(stats?.totalSize),
                    systemImage: "internaldrive"
                )
                StatTile(
                    title: "Snapshots",
                    value: Format.count(stats?.snapshotsCount ?? snapshots.count),
                    systemImage: "camera.aperture"
                )
                StatTile(
                    title: "Blobs",
                    value: Format.count(stats?.totalBlobCount),
                    systemImage: "square.stack.3d.up"
                )
                StatTile(
                    title: "Compression saved",
                    value: stats?.compressionSpaceSaving.map {
                        ($0 / 100).formatted(.percent.precision(.fractionLength(1)))
                    } ?? "—",
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
            }

            GroupBox {
                DetailGrid {
                    DetailRow("Type", repository.kind.displayName)
                    DetailRow("Location") {
                        Text(repository.resticRepositoryString)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    DetailRow("Added", Format.timestamp(repository.createdAt))
                    DetailRow("Plans using it", Format.count(planCount))
                }
                .padding(6)
            } label: {
                Text("Details").font(.headline)
            }

            maintenanceCard(repository)

            GroupBox {
                SnapshotTable(
                    snapshots: snapshots,
                    isLoading: model.loadingSnapshots.contains(repositoryID),
                    onBrowse: { snapshot in
                        browsing = SnapshotBrowserTarget(repositoryID: repositoryID, snapshot: snapshot)
                    },
                    onCompare: { snapshot in
                        comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot)
                    }
                )
                .padding(6)
            } label: {
                Text("All Snapshots").font(.headline)
            }

            HStack {
                Spacer()
                Button("Remove from SwiftRestic…", role: .destructive) {
                    isConfirmingRemoval = true
                }
            }
        }
        .detailPane()
    }

    @ViewBuilder
    private func maintenanceCard(_ repository: Repository) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let task = model.maintenance[repositoryID] {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(task.displayName) running…")
                        Spacer()
                        Button("Cancel", role: .destructive) {
                            model.cancelMaintenance(repositoryID: repositoryID)
                        }
                        .controlSize(.small)
                    }
                }

                DetailGrid {
                    DetailRow("Policy", repository.maintenance.summary)
                    DetailRow("Last check", Format.relative(repository.maintenance.lastCheckAt))
                    DetailRow("Next check", nextText(.check, repository))
                    if repository.maintenance.pruneEnabled {
                        DetailRow("Last prune", Format.relative(repository.maintenance.lastPruneAt))
                        DetailRow("Next prune", nextText(.prune, repository))
                    }
                }

                if model.repositoriesMissingPassword.contains(repositoryID) {
                    Label(
                        "Waiting for a repository password — nothing is scheduled until one is saved.",
                        systemImage: "key"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text("Both operations lock the repository — prune exclusively — so backups to it are held back until they finish rather than failing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        } label: {
            Text("Maintenance").font(.headline)
        }
    }

    private func nextText(_ task: MaintenanceTask, _ repository: Repository) -> String {
        guard let date = repository.maintenance.nextDate(for: task, addedAt: repository.createdAt) else {
            return "Off"
        }
        return date <= .now ? "Due now" : Format.timestamp(date)
    }

    private var planCount: Int {
        model.configuration.plans.filter { $0.repositoryID == repositoryID }.count
    }

    #if DEBUG
    /// Debug-only: lets a capture run open the compare sheet on the newest
    /// snapshot once the list has loaded.
    private func applyCaptureSheetOverride() {
        guard ProcessInfo.processInfo.environment["SWIFTRESTIC_CAPTURE_SHEET"] == "diff",
              comparing == nil,
              let newest = model.snapshots(for: repositoryID).max(by: { $0.time < $1.time })
        else { return }
        comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: newest)
    }
    #endif
}
