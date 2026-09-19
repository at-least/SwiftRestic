import Foundation

extension AppModel {
    // MARK: - Run records (shared by backup, maintenance and restore)

    /// Why a run was cancelled, for the run record: the user's own stop and the
    /// app quitting mid-run are different events worth telling apart.
    var cancellationMessage: String {
        isShuttingDown ? "Interrupted by quitting SwiftRestic" : "Cancelled"
    }

    func append(record: RunRecord) {
        configuration.runs.insert(record, at: 0)
        let limit = max(20, configuration.settings.maxRunHistory)
        if configuration.runs.count > limit {
            configuration.runs.removeLast(configuration.runs.count - limit)
        }
    }

    /// Wipes the run history. The view-facing name for the destructive
    /// action, so the mutation lives with its siblings instead of a view
    /// reaching straight into the configuration.
    func clearRunHistory() {
        configuration.runs.removeAll()
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
