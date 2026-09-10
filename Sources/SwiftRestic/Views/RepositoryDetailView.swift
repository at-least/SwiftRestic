import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID
    let onEdit: () -> Void

    @State private var browsing: SnapshotBrowserTarget?
    @State private var comparing: SnapshotDiffTarget?
    @State private var isConfirmingRemoval = false
    @State private var isConfirmingPrune = false
    @State private var isConfirmingUnlock = false
    @State private var isConfirmingCheck = false

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
                .help("Re-read snapshots and statistics")
                Menu("Maintenance", systemImage: "wrench.and.screwdriver") {
                    Button("Check…") { isConfirmingCheck = true }
                    Divider()
                    Button("Prune Now", role: .destructive) { isConfirmingPrune = true }
                    Button("Remove Stale Locks", role: .destructive) { isConfirmingUnlock = true }
                    Divider()
                    // The most destructive act on this pane — it pauses every
                    // plan pointing here — sits with the pane's other
                    // consequential actions, not at the bottom of a scroll.
                    Button("Remove from SwiftRestic…", role: .destructive) {
                        isConfirmingRemoval = true
                    }
                }
                .labelStyle(.titleAndIcon)
                .disabled(model.busyRepositoryIDs.contains(repositoryID))
                .help("Verify the repository's integrity, or run destructive maintenance")
                Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                    .labelStyle(.titleAndIcon)
                    .help("Change this repository's location, credentials and maintenance")
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
            // Same source as the sidebar's removal dialog: one wording, one
            // place, testable at the model level.
            Text(model.removalConsequences(for: repositoryID))
        }
        .confirmationDialog(
            "Prune this repository now?",
            isPresented: $isConfirmingPrune,
            titleVisibility: .visible
        ) {
            Button("Prune", role: .destructive) {
                model.runMaintenance(id: repositoryID, task: .prune)
            }
        } message: {
            Text("Pruning permanently removes the data of deleted snapshots and locks the repository exclusively — backups to it are held back until it finishes.")
        }
        .confirmationDialog(
            "Check this repository's integrity?",
            isPresented: $isConfirmingCheck,
            titleVisibility: .visible
        ) {
            Button("Check Structure") {
                model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 0)
            }
            Button("Check + Read 5% of Data") {
                model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 5)
            }
            Button("Check + Read All Data") {
                model.runMaintenance(id: repositoryID, task: .check, readDataPercent: 100)
            }
        } message: {
            Text(checkMessage)
        }
        .confirmationDialog(
            "Remove stale locks on this repository?",
            isPresented: $isConfirmingUnlock,
            titleVisibility: .visible
        ) {
            Button("Remove Locks", role: .destructive) {
                model.unlockRepository(id: repositoryID)
            }
        } message: {
            Text("This removes locks left behind by interrupted restic processes. If restic is running somewhere else right now, removing its lock can corrupt the repository.")
        }
    }

    @ViewBuilder
    private func content(_ repository: Repository) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            let stats = model.repositoryStats[repositoryID]
            let snapshots = model.snapshots(for: repositoryID)
            let listingOutcome = model.snapshotListingOutcome(for: repositoryID)

            HStack(spacing: Theme.Space.tile) {
                StatTile(
                    title: "Repository size",
                    value: Format.bytes(stats?.totalSize)
                )
                // The count is a fact only once the listing has succeeded; a
                // failed read wears "—" and says so in the tooltip instead of
                // passing an empty repository off as the truth.
                switch listingOutcome {
                case .loaded:
                    StatTile(
                        title: "Snapshots",
                        value: Format.count(stats?.snapshotsCount ?? snapshots.count),
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
                // A word restic owns, defined in the Concepts sheet: the tile
                // is a button so the definition is one click from the word,
                // not a Help-menu hunt.
                Button {
                    NotificationCenter.default.post(name: .swiftResticShowConcepts, object: nil)
                } label: {
                    StatTile(
                        title: "Blobs",
                        value: Format.count(stats?.totalBlobCount),
                        help: "Chunks of encrypted data stored in the repository — the pieces snapshots are made of",
                        trailingSymbol: "chevron.forward"
                    )
                }
                .buttonStyle(HoverableButtonStyle())
                .help("What “blobs” means — opens the concepts guide")
                StatTile(
                    title: "Compression saved",
                    value: stats?.compressionSpaceSaving.map {
                        ($0 / 100).formatted(.percent.precision(.fractionLength(1)))
                    } ?? "—"
                )
            }

            listingCaveat(outcome: listingOutcome)

            Card("Details") {
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
            }

            maintenanceCard(repository)

            Card("All Snapshots") {
                SnapshotTable(
                    snapshots: snapshots,
                    isLoading: model.loadingSnapshots.contains(repositoryID),
                    loadOutcome: listingOutcome,
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
                if let loadedAt = model.snapshotsLoadedAt(for: repositoryID),
                   !model.loadingSnapshots.contains(repositoryID) {
                    Text("Updated \(loadedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .detailPane()
    }

    /// "Slow" is a different unit of slow on a 4 TB repository than on a
    /// memory stick, so the check dialog says which one the user is holding.
    private var checkMessage: String {
        var message = "Structure checks are fast; reading data finds more problems at the cost of time. The repository is locked while the check runs, so backups to it are held back until it finishes."
        if let size = model.repositoryStats[repositoryID]?.totalSize {
            message += " This repository currently holds \(Format.bytes(size))."
        }
        return message
    }

    @ViewBuilder
    private func listingCaveat(outcome: SnapshotListingOutcome) -> some View {
        switch outcome {
        case let .failed(message):
            Label(
                "Snapshots could not be read — \(Format.firstSentence(message))",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.warning)
        case .idle:
            Label("The snapshot list has not finished loading.", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func maintenanceCard(_ repository: Repository) -> some View {
        Card("Maintenance") {
            VStack(alignment: .leading, spacing: 10) {
                if let activity = model.maintenance[repositoryID] {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            // An indeterminate spinner plus a live elapsed
                            // time: a check can legitimately run for hours,
                            // and "14 min" is what separates working from hung.
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(
                                    "\(activity.task.displayName) running — \(Format.duration(context.date.timeIntervalSince(activity.startedAt)))"
                                )
                                .monospacedDigit()
                            }
                            Spacer()
                            Button("Cancel", role: .destructive) {
                                model.cancelMaintenance(repositoryID: repositoryID)
                            }
                            .controlSize(.small)
                        }
                        if let last = activity.lastOutput {
                            Text(last)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(last)
                        }
                        Text("You can keep working while it runs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        systemImage: "key.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // The confirmations own the lock warning at the moment it
                // decides anything; here it stays one line, with the full
                // sentence on demand.
                ExpandableCaption(
                    summary: "Maintenance locks the repository — backups wait rather than fail.",
                    detail: "Both operations lock the repository — prune exclusively — so backups to it are held back until they finish rather than failing."
                )
            }
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
