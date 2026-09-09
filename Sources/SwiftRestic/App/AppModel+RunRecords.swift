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

    /// Tells the configured webhooks and chat channels how the run went.
    ///
    /// Awaited rather than detached so that quitting straight after a failed
    /// backup still gets the alert out; a failure to deliver is shown to the user
    /// but never written into the run record, which describes the backup itself.
    func broadcast(record: RunRecord, plan: BackupPlan?) async {
        let channels = configuration.settings.notificationChannels
        guard channels.contains(where: \.isUsable) else { return }

        let stage: NotificationEvent.Stage
        switch record.outcome {
        case .succeeded: stage = .succeeded
        case .completedWithErrors: stage = .warned
        case .failed: stage = .failed
        case .cancelled: stage = .cancelled
        }

        if let planID = plan?.id { activity[planID]?.phase = .notifying }

        let event = NotificationEvent(
            stage: stage,
            planName: record.planName,
            repositoryName: repository(id: record.repositoryID)?.name ?? "",
            operation: record.kind.rawValue.capitalized,
            snapshotID: record.snapshotID,
            errorMessage: record.failureMessage,
            // restic's own warnings only. `hookMessages` deliberately does not
            // leave the machine.
            warnings: Array(record.itemErrors.prefix(5)),
            filesNew: record.filesNew,
            bytesProcessed: record.bytesProcessed,
            dataAdded: record.dataAdded,
            duration: record.duration
        )

        let failures = await NotificationPoster.broadcast(event, to: channels)
        if !failures.isEmpty {
            post(Banner(
                title: "Could not send \(failures.count) notification(s)",
                message: failures.joined(separator: "\n"),
                isError: true
            ))
        }
    }
}
