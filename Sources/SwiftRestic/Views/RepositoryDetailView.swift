import SwiftUI

/// A repository's page, and its overview: protection in one line, the
/// adoptable history a repository may have arrived with, and the week's
/// problems against it — the questions asked of a backup destination, in
/// the order they are asked — then the facts about the destination itself,
/// Details and Maintenance.
struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    /// The window's minute clock: the maintenance dates are as of it.
    @Environment(\.now) private var now
    let repositoryID: UUID
    let onEdit: () -> Void
    /// Opens the plan editor with this repository preset.
    let onAddPlan: () -> Void
    /// Opens the adopt sheet for a group row on this page — the root owns
    /// the presenting state, as for every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

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
            // The page's verbs: read it again, start a plan in it, change
            // it. Getting files back starts from the sidebar, where the
            // backups sit under the plans that made them. Check, Prune, the
            // lock and index repairs and Remove from SwiftRestic… are the
            // Repository menu's (all of them, acting on this page's
            // repository) and the sidebar row's (all but the two repairs),
            // each through the one shared confirmation.
            ToolbarItemGroup {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshSnapshots(repositoryID: repositoryID) }
                }
                .help("Re-read snapshots and statistics")
                Button("New Backup Plan…", systemImage: "plus", action: onAddPlan)
                    .labelStyle(.titleAndIcon)
                    .help("Create a backup plan that backs up to “\(repository?.name ?? "Repository")”")
                Button("Edit", systemImage: "slider.horizontal.3", action: onEdit)
                    .labelStyle(.titleAndIcon)
                    .help("Change this repository's location, credentials and maintenance")
            }
        }
    }

    @ViewBuilder
    private func content(_ repository: Repository) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            ProtectionCard(repositoryID: repositoryID, onAddPlan: onAddPlan)
            OtherBackupsCard(repositoryID: repositoryID, onAdoptGroup: onAdoptGroup)
            RecentProblemsCard(repositoryID: repositoryID)

            // Arq's storage-location page, plus the two numbers a backup
            // user asks of a destination: how big, and how full is its disk.
            // The backups themselves are the sidebar's, under the plans
            // that made them.
            Card("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGrid {
                        DetailRow("Type", repository.kind.displayName)
                        DetailRow("Location") {
                            Text(repository.resticRepositoryString)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                        DetailRow("Size", Format.bytes(model.repositoryStats[repositoryID]?.totalSize))
                        DetailRow("Snapshots") { snapshotsValue }
                    }
                    volumeStrip(repository)
                }
            }

            // Why Snapshots may read "—", in words, directly under it.
            SnapshotListingCaveat(outcome: model.snapshotListingOutcome(for: repositoryID))

            maintenanceCard(repository)
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

    /// A count only once the listing it derives from has succeeded; before
    /// that, or after a failure, "—" with the reason as its tooltip — the
    /// caveat under the card says it in words. Loaded, the count splits
    /// when some of the repository's backups belong to no plan of it, by
    /// the same count the sidebar's Other backups node carries.
    @ViewBuilder
    private var snapshotsValue: some View {
        switch model.snapshotListingOutcome(for: repositoryID) {
        case .loaded:
            Text(OverviewMetrics.snapshotsLine(
                total: model.repositoryStats[repositoryID]?.snapshotsCount
                    ?? model.snapshots(for: repositoryID).count,
                otherBackups: model.shelves(for: repositoryID).otherBackupsCount
            ))
            .monospacedDigit()
        case let .failed(message):
            Text("—").help(message)
        case .idle:
            Text("—").help("The snapshot list has not finished loading.")
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
            VStack(alignment: .leading, spacing: 8) {
                Divider()
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

                // When it was last verified, and when next: the policy
                // behind the dates is the editor's, and each run is a
                // record in Activity.
                DetailGrid {
                    DetailRow("Last check", Format.ago(repository.maintenance.lastCheckAt, now: now))
                    // As the scheduler will start them: the hold holds upkeep
                    // too, so a due task reads "Waiting", never "Due now".
                    let hold = model.scheduleHold
                    DetailRow("Next check", Scheduler.nextMaintenanceText(.check, of: repository, hold: hold, now: now))
                    if repository.maintenance.pruneEnabled {
                        DetailRow("Last prune", Format.ago(repository.maintenance.lastPruneAt, now: now))
                        DetailRow("Next prune", Scheduler.nextMaintenanceText(.prune, of: repository, hold: hold, now: now))
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

            }
        }
    }

}
