import SwiftUI

struct RepositoryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(\.now) private var now
    let repositoryID: UUID
    let onAddPlan: () -> Void
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
                ContentUnavailableView("Backup location not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(repository.map { model.label(of: $0) } ?? "Backup Location")
        .allBackupsSearch()
    }

    private func content(_ repository: Repository) -> some View {
        Form {
            StatusSection(repositoryID: repositoryID, onAddPlan: onAddPlan, onAdoptGroup: onAdoptGroup)

            Section("Details") {
                LabeledContent("Location") {
                    Text(repository.displayLocation)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(repository.displayLocation)
                }
                // Only once read: a row of dashes says nothing the Status
                // section doesn't.
                if case .loaded = model.snapshotListingOutcome(for: repositoryID) {
                    LabeledContent("Size") {
                        Text(Format.bytes(model.repositoryStats[repositoryID]?.totalSize))
                            .accessibilityIdentifier(AccessibilityID.Repository.size)
                    }
                    LabeledContent("Backups") { snapshotsValue }
                }
                diskRow(repository)
            }

            maintenanceSection(repository)
        }
        .formStyle(.grouped)
        // On the form, not the disk row: the row renders nothing until a
        // capacity exists, and a lifecycle modifier on a view that renders
        // nothing never fires. nil first, then a cancelled-check after the
        // await, so a slow answer from the old disk can neither render under
        // the new one's caption nor overwrite its numbers.
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
        case let .notConnected(volume):
            Text("—").help(SnapshotListingOutcome.connectText(volume: volume))
        case let .failed(message, _):
            Text("—").help(message)
        case let .passwordRefused(name):
            Text("—").help(SnapshotListingOutcome.passwordRefusedText(repositoryName: name))
        case .idle:
            Text("—").help(OverviewMetrics.listingIdleText)
        }
    }

    /// The volume's space, not the location's size: the only kind of location
    /// whose backing disk the app can see.
    @ViewBuilder
    private func diskRow(_ repository: Repository) -> some View {
        if repository.kind == .local, let capacity = volumeCapacity {
            LabeledContent("Disk") {
                HStack(spacing: 4) {
                    if capacity.isLow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .accessibilityLabel("Low on space")
                    }
                    Text("\(Format.bytes(capacity.freeBytes)) free of \(Format.bytes(capacity.totalBytes))")
                }
            }
        }
    }

    private func maintenanceSection(_ repository: Repository) -> some View {
        Section {
            if let activity = model.maintenance[repositoryID] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    // A live elapsed time: a verification can run for
                    // hours, and "14 min" is what separates working from
                    // hung.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(
                            "\(activity.task.inFlightTitle) \(Format.duration(context.date.timeIntervalSince(activity.startedAt)))"
                        )
                        .monospacedDigit()
                    }
                    Spacer()
                    Button("Stop") {
                        model.cancelMaintenance(repositoryID: repositoryID)
                    }
                    .controlSize(.small)
                }
            }

            let runs = model.configuration.runs
            let check = Scheduler.newestMaintenanceRun(.check, of: repository, runs: runs)
            let prune = Scheduler.newestMaintenanceRun(.prune, of: repository, runs: runs)
            LabeledContent("Last verified") {
                MaintenanceRunValue(
                    text: Scheduler.lastMaintenanceText(.check, of: repository, newest: check, now: now),
                    run: check
                )
            }
            if Scheduler.cleansUp(repository, plans: model.configuration.plans) {
                LabeledContent("Last cleanup") {
                    MaintenanceRunValue(
                        text: Scheduler.lastMaintenanceText(.prune, of: repository, newest: prune, now: now),
                        run: prune
                    )
                }
            }

            // A verification that found damage: the console, where `restic
            // repair` runs with the password supplied.
            if let check, RunRecordPresentation.repairRoute(for: check, repositoryExists: true) != nil {
                ConsoleRouteButton(repositoryID: repositoryID)
            }

            if model.repositoriesMissingPassword.contains(repositoryID) {
                WarningLine(text: "Waiting for a password. Nothing is scheduled until one is saved.")
            }
        } header: {
            HStack {
                Text("Maintenance")
                Spacer()
                Button("Verify Backups") { router.request(.verifyBackups(repositoryID)) }
                    .disabled(!model.repositoryCommands(for: .repository(repositoryID)).canMaintain)
            }
            .controlSize(.small)
        }
    }
}

/// The words alone after a run that succeeded, else a link to the run in
/// Activity, whose drawer holds the retry and the log.
private struct MaintenanceRunValue: View {
    @Environment(AppRouter.self) private var router
    let text: String
    let run: RunRecord?

    var body: some View {
        if let run, run.outcome != .succeeded {
            Button(text) { router.focusRun(run.id) }
                .buttonStyle(.link)
                .help("Show in Activity")
        } else {
            Text(text)
        }
    }
}
