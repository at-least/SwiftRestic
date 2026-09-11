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
            } catch {
                record.setOutcome(from: error, cancellationMessage: self.cancellationMessage)
                if record.outcome == .cancelled {
                    // The strip vanishing is the only signal a cancelled
                    // restore otherwise leaves — including when it is the
                    // repository's removal that cancelled it. During shutdown
                    // the banner would die with the process, and the quit
                    // confirmation has already said it.
                    if !self.isShuttingDown {
                        self.post(Banner(
                            title: "Restore cancelled",
                            message: "The restore was cancelled before it finished.",
                            isError: false
                        ))
                    }
                } else {
                    self.post(Banner(
                        title: "Restore failed",
                        message: record.failureMessage ?? "",
                        isError: true
                    ))
                }
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

    /// The Arq-style drag restore: restores one node into a fresh throwaway
    /// directory and returns the restored item's URL, which the drag's
    /// promised-file provider hands to Finder.
    ///
    /// Deliberately outside `beginRestore`: that path owns the app-level
    /// progress strip, the run history and the "Restored…" banner, none of
    /// which describe a drop whose destination the user chose with the drag
    /// itself. A failed drag still posts a banner, because Finder's own
    /// "couldn't complete the operation" says nothing about restic.
    func restoredFileForDrag(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode
    ) async throws -> URL {
        guard let repository = repository(id: repositoryID) else {
            throw ResticError.repositoryMissing
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftRestic-Drag-\(UUID().uuidString)")
        do {
            _ = try await service().restore(
                try await context(for: repository),
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination
            )
        } catch {
            let message = (error as? ResticError)?.errorDescription ?? error.localizedDescription
            post(Banner(title: "Drag restore failed", message: message, isError: true))
            throw error
        }
        // Same name rule the service applies for both restore shapes.
        return destination.appendingPathComponent(node.name.isEmpty ? "restored" : node.name)
    }
}
