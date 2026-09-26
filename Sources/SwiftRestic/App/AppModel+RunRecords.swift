import Foundation

extension AppModel {
    // MARK: - Run records (shared by backup, maintenance and restore)

    /// Why a run was cancelled, for the run record: the user's own stop and the
    /// app quitting mid-run are different events worth telling apart.
    var cancellationMessage: String {
        isShuttingDown ? "Interrupted by quitting SwiftRestic" : "Cancelled"
    }

    // MARK: - Run logs

    /// `Logs/` beside `config.json` — so `SWIFTRESTIC_CONFIG_DIR` moves it
    /// with the configuration, and a capture or test run never writes the
    /// real one.
    var runLogs: RunLogStore {
        RunLogStore(directory: store.directory.appendingPathComponent("Logs", isDirectory: true))
    }

    /// Stamps the restic version and writes the run's log, before the
    /// record joins the history: the two land together, and `hasLog` says
    /// only what the write actually did (a full disk leaves it false, and
    /// Show Log… says why). Rendering and writing both run detached — a
    /// log can be hundreds of kilobytes — while the names are read here.
    func seal(_ record: inout RunRecord, transcript: RunTranscript.Contents) async {
        let versions = RunLogVersions.current(resticVersion: resticVersion)
        if !resticVersion.isEmpty { record.resticVersion = versions.restic }
        let repository = repository(id: record.repositoryID)
        let name = repository?.name
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

    /// A run's log text, read off the main actor; nil when the file is gone.
    func loadRunLog(_ run: RunRecord) async -> String? {
        let logs = runLogs
        let id = run.id
        return await Task.detached(priority: .userInitiated) { logs.read(id) }.value
    }

    /// Where the drawer's snapshot row can take the user. Nil for a run
    /// that names no snapshot.
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
        configuration.runs.insert(record, at: 0)
        let limit = max(20, configuration.settings.maxRunHistory)
        if configuration.runs.count > limit {
            let trimmed = configuration.runs.suffix(configuration.runs.count - limit).map(\.id)
            configuration.runs.removeLast(configuration.runs.count - limit)
            removeRunLogs(trimmed)
        }
    }

    /// Wipes the run history, and the logs with it. The view-facing name
    /// for the destructive action, so the mutation lives with its siblings
    /// instead of a view reaching straight into the configuration.
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

    /// Tells the configured webhooks and chat channels how the run went.
    ///
    /// Awaited rather than detached so that quitting straight after a failed
    /// backup still gets the alert out; a failure to deliver is shown to the user
    /// but never written into the run record, which describes the backup itself.
    func broadcast(record: RunRecord, plan: BackupPlan?) async {
        let channels = configuration.settings.notificationChannels
        guard channels.contains(where: \.isUsable) else { return }

        if let planID = plan?.id { activity[planID]?.phase = .notifying }

        let event = Self.notificationEvent(for: record, repositoryName: repository(id: record.repositoryID)?.name ?? "")

        let failures = await NotificationPoster.broadcast(event, to: channels)
        if !failures.isEmpty {
            post(Banner(
                title: "Could not send \(failures.count) notification(s)",
                message: failures.joined(separator: "\n"),
                isError: true
            ))
        }
    }

    /// Maps a finished run onto what notifications report. Static so the
    /// mapping (outcome → stage, the sampled excerpts, the full warning
    /// count) is testable without driving a whole run.
    static func notificationEvent(for record: RunRecord, repositoryName: String) -> NotificationEvent {
        let stage: NotificationEvent.Stage
        switch record.outcome {
        case .succeeded: stage = .succeeded
        case .completedWithErrors: stage = .warned
        case .failed: stage = .failed
        case .cancelled: stage = .cancelled
        }
        return NotificationEvent(
            stage: stage,
            planName: record.planName,
            repositoryName: repositoryName,
            operation: record.kind.rawValue.capitalized,
            snapshotID: record.snapshotID,
            errorMessage: record.failureMessage,
            // restic's own warnings only. `hookMessages` deliberately does not
            // leave the machine. The excerpts are for the message body; the
            // count is what the summary announces.
            warnings: Array(record.itemErrors.prefix(5)),
            warningCount: record.itemErrorCount > 0 ? record.itemErrorCount : nil,
            filesNew: record.filesNew,
            bytesProcessed: record.bytesProcessed,
            dataAdded: record.dataAdded,
            duration: record.duration
        )
    }
}

/// Whether a run's snapshot can still be opened, and why not when it cannot.
enum RunSnapshotLink: Equatable {
    case available(Snapshot)
    /// The listing is loaded and the snapshot is not in it: removed after
    /// the run — by retention, a prune, or another restic client, which all
    /// look the same from here.
    case removed
    /// The listing is not loaded (or could not be read), so nobody knows.
    case unavailable
    /// The repository is no longer set up in SwiftRestic.
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
