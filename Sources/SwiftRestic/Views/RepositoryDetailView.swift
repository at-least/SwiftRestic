import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let repositoryID: UUID
    let onEdit: () -> Void

    @State private var comparing: SnapshotDiffTarget?
    /// Read off the body: `resourceValues` is synchronous filesystem IO, and
    /// a spun-down external disk can take seconds to answer — re-run on every
    /// re-eval (progress ticks, banners) that would also stall the main
    /// thread each time.
    @State private var volumeCapacity: VolumeCapacity?

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
                // The Repository menu's items and rule, item for item: restic
                // work waits while the repository is busy; removal never
                // does — its dialog names the work it will cancel. Each asks
                // through the one shared confirmation.
                let commands = model.repositoryCommands(for: .repository(repositoryID))
                Menu("Maintenance", systemImage: "wrench.and.screwdriver") {
                    Button("Check…") { router.request(.confirm(.check(repositoryID))) }
                        .disabled(!commands.canMaintain)
                    Divider()
                    Button("Prune Now…", role: .destructive) { router.request(.confirm(.prune(repositoryID))) }
                        .disabled(!commands.canMaintain)
                    Button("Remove Stale Locks…", role: .destructive) { router.request(.confirm(.unlock(repositoryID))) }
                        .disabled(!commands.canMaintain)
                    Button("Rebuild Search Index…", role: .destructive) {
                        router.request(.confirm(.rebuildIndex(repositoryID)))
                    }
                    .disabled(!commands.canMaintain)
                    Divider()
                    // The most destructive act on this pane — it pauses every
                    // plan pointing here — sits with the pane's other
                    // consequential actions, not at the bottom of a scroll.
                    Button("Remove from SwiftRestic…", role: .destructive) {
                        router.request(.confirm(.removeRepository(repositoryID)))
                    }
                    .disabled(!commands.canRemove)
                }
                .labelStyle(.titleAndIcon)
                .help("Verify the repository's integrity, or run destructive maintenance")
                Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                    .labelStyle(.titleAndIcon)
                    .help("Change this repository's location, credentials and maintenance")
            }
        }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target).environment(model)
        }
        #if DEBUG
        .onChange(of: model.snapshots(for: repositoryID).count, initial: true) { _, _ in
            applyCaptureSheetOverride()
        }
        #endif
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
                StatTile.snapshots(
                    outcome: listingOutcome,
                    loadedCount: stats?.snapshotsCount ?? snapshots.count
                )
                // A word restic owns, defined in the Concepts sheet: the tile
                // is a button so the definition is one click from the word,
                // not a Help-menu hunt.
                Button {
                    router.request(.showConcepts)
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

            SnapshotListingCaveat(outcome: listingOutcome)

            volumeStrip(repository)

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
                        router.showRestore(repositoryID: repositoryID, snapshotID: snapshot.id)
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
                    // Arq's restore entry: expand the sidebar's Restore
                    // section on this repository and select its newest
                    // backup record — the pane does the rest. The button is
                    // disabled while no records exist; loading them is the
                    // toolbar Refresh's job, not a silent side effect.
                    Button("Restore Files…") {
                        if let latest = model.newestRecord(repositoryID: repositoryID) {
                            router.showRestore(repositoryID: repositoryID, snapshotID: latest.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(snapshots.isEmpty)
                    .help("Browse backups and restore files — expands Restore on the left and selects the newest backup")
                    if let loadedAt = model.snapshotsLoadedAt(for: repositoryID) {
                        SnapshotFreshnessLabel(
                            loadedAt: loadedAt,
                            isLoading: model.loadingSnapshots.contains(repositoryID),
                            showsSpinner: false
                        )
                    }
                }
            }
        }
        .detailPane()
        // On the pane itself, not the strip: the strip renders nothing until
        // a capacity exists, and a lifecycle modifier on a view that renders
        // nothing never fires — the load would never start. Also off-main on
        // purpose (see `volumeCapacity`): nil first, then a cancelled-check
        // after the await, so a slow answer from the old disk can neither
        // render under the new one's caption nor overwrite its numbers.
        .task(id: repository.id) {
            volumeCapacity = nil
            // Expanded, or `~/Backups` would probe a literal tilde directory
            // that can never exist.
            let path = repository.resolvedLocalPath
            let read = await Task.detached { VolumeCapacity.of(path: path) }.value
            if !Task.isCancelled {
                volumeCapacity = read
            }
        }
    }

    /// Arq's "Used Space / Free Space" bar, for the one kind of repository
    /// whose backing disk the app can actually see. The bar is the *volume's*
    /// usage, not the repository's — the caption says so, because a small
    /// repository on a full disk and a large one on an empty one must not
    /// render as the same picture.
    @ViewBuilder
    private func volumeStrip(_ repository: Repository) -> some View {
        if repository.kind == .local,
           let capacity = volumeCapacity {
            Card("Volume") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: capacity.usedFraction)
                        .tint(Theme.tint)
                    Text(
                        "The disk holding this repository: \(Format.bytes(capacity.usedBytes)) used of \(Format.bytes(capacity.totalBytes)), \(Format.bytes(capacity.freeBytes)) free."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                    // As the scheduler will start them: the hold holds upkeep
                    // too, so a due task reads "Waiting", never "Due now".
                    let hold = model.scheduleHold
                    DetailRow("Next check", Scheduler.nextMaintenanceText(.check, of: repository, hold: hold))
                    if repository.maintenance.pruneEnabled {
                        DetailRow("Last prune", Format.relative(repository.maintenance.lastPruneAt))
                        DetailRow("Next prune", Scheduler.nextMaintenanceText(.prune, of: repository, hold: hold))
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
