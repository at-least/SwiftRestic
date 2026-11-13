import Foundation

extension AppModel {
    var cancellationMessage: String {
        isShuttingDown ? "Interrupted by quitting SwiftRestic" : "Stopped"
    }

    /// Beside `config.json`, so `SWIFTRESTIC_CONFIG_DIR` moves it too.
    var runLogs: RunLogStore {
        RunLogStore(directory: store.directory.appendingPathComponent("Logs", isDirectory: true))
    }

    /// Call before the record joins the history, so the two land together;
    /// `hasLog` is false when the write failed. Detached: a log can be
    /// hundreds of kilobytes.
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
        // A continuing skip or standing failure replaces the plan's last
        // record, counting it.
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
            // Records a standing problem still reads survive the cap.
            let standing = OverviewMetrics.standingProblemIDs(in: configuration.runs, now: .now)
            let trimmed = Set(configuration.runs.dropFirst(limit).map(\.id).filter { !standing.contains($0) })
            configuration.runs.removeAll { trimmed.contains($0.id) }
            removeRunLogs(Array(trimmed))
        }
    }

    /// On the background lane, so quitting drains it.
    private func removeRunLogs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let logs = runLogs
        tasks.addBackground(Task.detached(priority: .utility) { logs.remove(ids) })
    }
}

enum RunSnapshotLink: Equatable {
    case available(Snapshot)
    /// Absent from a loaded listing; retention, a prune and another restic
    /// client look the same from here.
    case removed
    case unavailable
    case repositoryGone

    /// A record may name its snapshot by full or short ID. Only a loaded
    /// listing proves a snapshot gone; a stale one still opens it.
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
