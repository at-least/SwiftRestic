import Foundation

extension AppModel {
    // MARK: - Restore

    var isRestoring: Bool { restoreActivity != nil }

    func restore(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode,
        to destination: URL
    ) {
        beginRestore(repositoryID: repositoryID, label: node.name) { service, context in
            try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination
            ) { [weak self] progress in
                Task { @MainActor in self?.restoreActivity = progress }
            }
        } onSuccess: { [weak self] in
            self?.post(Banner(
                title: "Restored \(node.name)",
                message: destination.path,
                isError: false,
                revealPath: destination.path
            ))
        }
    }

    /// Restores every file in a snapshot, keeping the original absolute layout
    /// beneath `destination`.
    func restoreWholeSnapshot(repositoryID: UUID, snapshotID: String, to destination: URL) {
        beginRestore(repositoryID: repositoryID, label: "snapshot \(snapshotID.prefix(8))") { service, context in
            try await service.restoreWholeSnapshot(
                context,
                snapshotID: snapshotID,
                destinationDirectory: destination
            ) { [weak self] progress in
                Task { @MainActor in self?.restoreActivity = progress }
            }
        } onSuccess: { [weak self] in
            self?.post(Banner(
                title: "Restored snapshot",
                message: destination.path,
                isError: false,
                revealPath: destination.path
            ))
        }
    }

    /// Shared bookkeeping for both restore shapes: one at a time, progress
    /// published, and the outcome written to the run history either way.
    private func beginRestore(
        repositoryID: UUID,
        label: String,
        operation: @escaping @Sendable (ResticService, RepositoryContext) async throws -> ResticSummary?,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard restoreTask == nil else { return }
        restoreActivity = OperationProgress()
        restoreDescription = "Restoring \(label)"
        restoreRepositoryID = repositoryID

        restoreTask = Task { [weak self] in
            guard let self else { return }
            var record = RunRecord(
                kind: .restore,
                planName: label,
                repositoryID: repositoryID
            )
            do {
                guard let repository = self.repository(id: repositoryID) else {
                    throw ResticError.repositoryMissing
                }
                let summary = try await operation(self.service(), self.context(for: repository))
                record.outcome = .succeeded
                record.bytesProcessed = summary?.bytesRestored ?? 0
                onSuccess()
            } catch ResticError.cancelled {
                record.outcome = .cancelled
                record.failureMessage = self.cancellationMessage
            } catch is CancellationError {
                record.outcome = .cancelled
                record.failureMessage = self.cancellationMessage
            } catch {
                record.outcome = .failed
                record.failureMessage = error.localizedDescription
                self.post(Banner(
                    title: "Restore failed",
                    message: error.localizedDescription,
                    isError: true
                ))
            }
            record.finishedAt = .now
            self.append(record: record)
            self.restoreActivity = nil
            self.restoreDescription = ""
            self.restoreRepositoryID = nil
            self.restoreTask = nil
        }
    }

    func cancelRestore() { restoreTask?.cancel() }
}
