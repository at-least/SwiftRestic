import Foundation

extension AppModel {
    /// Why a run was cancelled, for the run record: the user's own stop and the
    /// app quitting mid-run are different events worth telling apart.
    var cancellationMessage: String {
        isShuttingDown ? "Interrupted by quitting SwiftRestic" : "Stopped"
    }

    /// `Logs/` beside `config.json` — so `SWIFTRESTIC_CONFIG_DIR` moves it
    /// with the configuration, and a capture or test run never writes the
    /// real one.
    var runLogs: RunLogStore {
        RunLogStore(directory: store.directory.appendingPathComponent("Logs", isDirectory: true))
    }

    /// Stamps the restic version and writes the run's log, before the
    /// record joins the history: the two land together, and `hasLog` says
    /// only what the write actually did (a full disk leaves it false, and
    /// Show Log says why). Rendering and writing both run detached — a
    /// log can be hundreds of kilobytes — while the names are read here.
    func seal(_ record: inout RunRecord, transcript: RunTranscript.Contents) async {
        let versions = RunLogVersions.current(resticVersion: resticVersion)
        if !resticVersion.isEmpty { record.resticVersion = versions.restic }
        let repository = repository(id: record.repositoryID)
        let name = repository.map { label(of: $0) }
        let kind = repository?.kind.displayName
        let logs = runLogs
        let sealed = record
        record.hasLog = await Task.detached(priority: .utility) {
            let text = RunLog.render(
                record: sealed,
                repositoryName: name,
                repositoryKind: kind,
                versions: versions,
                transcript: transcript
            )
            do {
                try logs.write(text, for: sealed.id)
                return true
            } catch {
                return false
            }
        }.value
    }

    func loadRunLog(_ run: RunRecord) async throws -> String? {
        let logs = runLogs
        let id = run.id
        return try await Task.detached(priority: .userInitiated) { try logs.read(id) }.value
    }

    func snapshotLink(for run: RunRecord) -> RunSnapshotLink? {
        guard let snapshotID = run.snapshotID else { return nil }
        return RunSnapshotLink.resolve(
            snapshotID: snapshotID,
            repositoryExists: repository(id: run.repositoryID) != nil,
            listing: snapshots(for: run.repositoryID),
            outcome: snapshotListingOutcome(for: run.repositoryID)
        )
    }

    func append(record: RunRecord) {
        var record = record
        // A skip, or a failure for the same folders gone or shares refused,
        // continuing the plan's last one replaces it, counting it
        // (`continuingSkip(of:)`, `continuingStandingFailure(of:)`); its log
        // leaves with it.
        if record.outcome == .skipped || record.missingSources != nil || record.refusedShares != nil,
           let index = configuration.runs.firstIndex(where: { $0.isBackup(ofPlan: record.planID) }),
           let merged = record.outcome == .skipped
               ? record.continuingSkip(of: configuration.runs[index])
               : record.continuingStandingFailure(of: configuration.runs[index]) {
            removeRunLogs([configuration.runs.remove(at: index).id])
            record = merged
        }
        configuration.runs.insert(record, at: 0)
        // Counted while the backups before it are still here: the cap below
        // can trim them.
        configuration.runs = RunRecord.fillingProblemStretches(configuration.runs)
        let limit = activityHistoryLimit
        if configuration.runs.count > limit {
            // Past the cap by count, except what a standing problem still
            // reads (`OverviewMetrics.standingProblemIDs`).
            let standing = OverviewMetrics.standingProblemIDs(in: configuration.runs, now: .now)
            let trimmed = Set(configuration.runs.dropFirst(limit).map(\.id).filter { !standing.contains($0) })
            configuration.runs.removeAll { trimmed.contains($0.id) }
            removeRunLogs(Array(trimmed))
        }
    }

    /// The view-facing name for the destructive action, so the mutation
    /// lives with its siblings instead of a view reaching straight into the
    /// configuration.
    func clearRunHistory() {
        let cleared = configuration.runs.map(\.id)
        configuration.runs.removeAll()
        removeRunLogs(cleared)
    }

    /// A log leaves with its record. On the background lane, so quitting
    /// drains the removal instead of stranding it.
    private func removeRunLogs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let logs = runLogs
        tasks.addBackground(Task.detached(priority: .utility) { logs.remove(ids) })
    }
}

enum RunSnapshotLink: Equatable {
    case available(Snapshot)
    /// The listing is loaded and the snapshot is not in it: removed after
    /// the run — by retention, a prune, or another restic client, which all
    /// look the same from here.
    case removed
    /// The listing is not loaded (or could not be read), so nobody knows.
    case unavailable
    case repositoryGone

    /// Matched by full ID or short ID — a record names its snapshot however
    /// its run was asked for it. A stale listing that still holds the
    /// snapshot is good enough to open it; one that does not proves nothing
    /// unless it is freshly loaded.
    static func resolve(
        snapshotID: String,
        repositoryExists: Bool,
        listing: [Snapshot],
        outcome: SnapshotListingOutcome
    ) -> RunSnapshotLink {
        guard repositoryExists else { return .repositoryGone }
        if let snapshot = listing.first(where: { $0.id == snapshotID || $0.shortID == snapshotID }) {
            return .available(snapshot)
        }
        return outcome == .loaded ? .removed : .unavailable
    }
}
