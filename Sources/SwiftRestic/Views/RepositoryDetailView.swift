import SwiftUI

/// A repository's page, and its overview: protection in one line, the
/// adoptable history a repository may have arrived with, and the week's
/// problems against it — the questions asked of a backup destination, in
/// the order they are asked — then the facts about the destination itself,
/// Details and Maintenance.
struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var searchText = ""
    /// The window's minute clock.
    @Environment(\.now) private var now
    let repositoryID: UUID
    let onAddPlan: () -> Void
    /// Opens the adopt sheet for a group row on this page — the root owns
    /// the presenting state, as for every sheet a pane raises.
    let onAdoptGroup: (_ repositoryID: UUID, _ planID: UUID) -> Void

    /// Read off the body: `resourceValues` is synchronous filesystem IO, and
    /// a spun-down external disk can take seconds to answer — re-run on every
    /// re-eval (progress ticks, banners) that would also stall the main
    /// thread each time.
    @State private var volumeCapacity: VolumeCapacity?
    /// Read off the body for `volumeCapacity`'s reason, again each minute.
    @State private var driveAway = false

    private struct DriveReadKey: Equatable {
        let repositoryID: UUID
        let minute: Date
    }

    private var repository: Repository? { model.repository(id: repositoryID) }

    var body: some View {
        Group {
            if let repository {
                content(repository)
            } else {
                ContentUnavailableView("Repository not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(repository.map { model.label(of: $0) } ?? "Repository")
        // The toolbar holds the search field alone; the page's verbs are the
        // menus' — the HIG's macOS toolbars: "it doesn't make sense to
        // provide a toolbar item for every menu item".
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search all backups"))
        .onSubmit(of: .search) {
            router.openFind(repositoryID: repositoryID, query: searchText, run: true)
            searchText = ""
        }
    }

    @ViewBuilder
    private func content(_ repository: Repository) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ProtectionCard(repositoryID: repositoryID, onAddPlan: onAddPlan)
            OtherBackupsCard(repositoryID: repositoryID, onAdoptGroup: onAdoptGroup)

            // Arq's storage-location page, plus the two numbers a backup
            // user asks of a destination: how big, and how full is its disk.
            // The backups themselves are on each plan's or group's page,
            // its Backups tab.
            Card("Details") {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGrid {
                        DetailRow("Type", repository.kind.displayName)
                        DetailRow("Location") {
                            Text(repository.displayLocation)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .help(repository.displayLocation)
                        }
                        // Facts read from the repository, only once it has
                        // been read: a row of dashes says nothing the
                        // Protection card doesn't.
                        if case .loaded = model.snapshotListingOutcome(for: repositoryID) {
                            DetailRow("Size", Format.bytes(model.repositoryStats[repositoryID]?.totalSize))
                            DetailRow("Backups") { snapshotsValue }
                        }
                    }
                    volumeStrip(repository)
                }
            }

            maintenanceCard(repository)
        }
        .detailPane()
        // On the pane itself, not the strip: the strip renders nothing until
        // a capacity exists, and a lifecycle modifier on a view that renders
        // nothing never fires — the load would never start. Off the main
        // actor (see `volumeCapacity`): nil first, then a cancelled-check
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
        .task(id: DriveReadKey(repositoryID: repository.id, minute: now)) {
            guard repository.kind == .local else {
                driveAway = false
                return
            }
            let path = repository.resolvedLocalPath
            let away = await Task.detached { VolumePresence.isMounted(volumeOf: path) == false }.value
            if !Task.isCancelled { driveAway = away }
        }
    }

    @ViewBuilder
    private var snapshotsValue: some View {
        switch model.snapshotListingOutcome(for: repositoryID) {
        case .loaded:
            let snapshots = model.snapshots(for: repositoryID)
            let shelves = model.shelves(for: repositoryID)
            let tile = OverviewMetrics.snapshotsTile(
                total: model.repositoryStats[repositoryID]?.snapshotsCount ?? snapshots.count,
                otherBackups: shelves.otherBackupsCount,
                repositoryHasPlans: !shelves.plans.isEmpty,
                snapshots: snapshots,
                subject: "here"
            )
            Text(tile.value)
                .monospacedDigit()
                .modifier(TileHelp(help: tile.help))
        case let .failed(message):
            Text("—").help(message)
        case .idle:
            Text("—").help(OverviewMetrics.listingIdleText)
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
                    .accessibilityLabel(Text("Space on this disk"))
                Text("\(Format.bytes(capacity.freeBytes)) free of \(Format.bytes(capacity.totalBytes)) on this disk")
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
                                    "\(activity.task.inFlightTitle) \(Format.duration(context.date.timeIntervalSince(activity.startedAt)))"
                                )
                                .monospacedDigit()
                            }
                            Spacer()
                            Button("Cancel") {
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
                    }
                }

                let runs = model.configuration.runs
                let check = Scheduler.newestMaintenanceRun(.check, of: repository, runs: runs)
                let prune = Scheduler.newestMaintenanceRun(.prune, of: repository, runs: runs)
                DetailGrid {
                    DetailRow("Last check") {
                        MaintenanceRunValue(
                            text: Scheduler.lastMaintenanceText(.check, of: repository, newest: check, now: now),
                            run: check
                        )
                    }
                    let hold = model.scheduleHold
                    let awaitingServer = model.maintenanceAwaitingServer.contains(repositoryID)
                    DetailRow("Next check", Scheduler.nextMaintenanceText(
                        .check, of: repository, among: model.configuration.repositories,
                        hold: hold, driveAway: driveAway, awaitingServer: awaitingServer,
                        isRunning: model.maintenance[repositoryID]?.task == .check, now: now
                    ))
                    if Scheduler.cleansUp(repository, plans: model.configuration.plans) {
                        DetailRow("Last cleanup") {
                            MaintenanceRunValue(
                                text: Scheduler.lastMaintenanceText(.prune, of: repository, newest: prune, now: now),
                                run: prune
                            )
                        }
                        DetailRow("Next cleanup", Scheduler.nextMaintenanceText(
                            .prune, of: repository, among: model.configuration.repositories,
                            hold: hold, driveAway: driveAway, awaitingServer: awaitingServer,
                            isRunning: model.maintenance[repositoryID]?.task == .prune, now: now
                        ))
                    }
                }

                // A check that found damage: the console, where `restic
                // repair` runs with the password supplied, beside the
                // verdict. A route, as the drawer offers it — the page keeps
                // no maintenance controls.
                if let check, RunRecordPresentation.repairRoute(for: check, repositoryExists: true) != nil {
                    ConsoleRouteButton(repositoryID: repositoryID)
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

/// The Last check / Last cleanup value: the words alone after a run that
/// succeeded, else the same words as a route to the run in Activity — its
/// drawer holds Check Again or Clean Up Again, the log and Copy
/// Details, so the page gains no maintenance control.
private struct MaintenanceRunValue: View {
    @Environment(AppRouter.self) private var router
    let text: String
    let run: RunRecord?

    var body: some View {
        if let run, run.outcome != .succeeded {
            Button { router.focusRun(run.id) } label: {
                HStack(spacing: 6) {
                    Text(text)
                    RowChevron()
                }
            }
            .buttonStyle(HoverableButtonStyle())
            .help("Show this run in Activity")
        } else {
            Text(text)
        }
    }
}
