import Foundation

extension AppModel {
    // MARK: - Restore

    var isRestoring: Bool { restoreActivity != nil }

    /// The restore progress reporter for the run the model is on right now.
    /// Progress fires from the runner's reader threads, so a hop can still be
    /// in flight when a cancelled restore unwinds — the token (rotated at
    /// unwind) is what keeps such a late hop from resurrecting the strip,
    /// which nothing else would ever clear.
    func restoreProgressReporter() -> @Sendable (OperationProgress) -> Void {
        let token = restoreRunToken
        return { [weak self] progress in
            Task { @MainActor in
                guard let self, self.restoreRunToken == token else { return }
                self.restoreActivity = progress
            }
        }
    }

    func restore(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode,
        to destination: URL
    ) {
        let reporter = restoreProgressReporter()
        beginRestore(repositoryID: repositoryID, label: node.name) { service, context in
            try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination,
                onProgress: reporter
            )
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
        let reporter = restoreProgressReporter()
        beginRestore(repositoryID: repositoryID, label: "snapshot \(snapshotID.prefix(8))") { service, context in
            try await service.restoreWholeSnapshot(
                context,
                snapshotID: snapshotID,
                destinationDirectory: destination,
                onProgress: reporter
            )
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
        operation: @escaping @Sendable (any ResticClient, RepositoryContext) async throws -> ResticSummary?,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard !tasks.isOccupied(.restore) else {
            // Every other refused start says why; a restore request that
            // silently does nothing reads as a broken drop.
            post(Banner(
                title: "A restore is already running",
                message: "One restore at a time — the current one is still in progress.",
                isError: false
            ))
            return
        }
        restoreActivity = OperationProgress()
        restoreDescription = "Restoring \(label)"
        restoreRepositoryID = repositoryID

        tasks.install(Task { [weak self] in
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
                self.noteAuthFailure(error, repositoryID: repositoryID)
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
            // After the strip clears: any progress hop from this run still
            // in flight must find a changed token and drop.
            self.restoreRunToken = UUID()
            self.tasks.clear(.restore)
        }, in: .restore)
    }

    func cancelRestore() { tasks.cancel(.restore) }

    /// The Arq-style drag restore: restores one node into a fresh throwaway
    /// directory and returns the restored item's URL, which the drag's
    /// promised-file provider hands to Finder.
    ///
    /// `nonisolated`, and handed everything it needs as values, because the
    /// promise's load handler runs *during* the drag session — while the
    /// main thread is synchronously waiting on it (measured:
    /// `NSItemProvider.loadURLSynchronously` → semaphore, under
    /// `_dragUntilMouseUp`). Any hop to the main actor from there is a
    /// self-deadlock; the caller captures the model-derived inputs before
    /// the session starts. Deliberately outside `beginRestore`: that path
    /// owns the progress strip, the run history and the "Restored…" banner,
    /// none of which describe a drop whose destination the drag itself
    /// chose. A failed drag posts its banner from the caller, which hops to
    /// main only after the promise resolves — by then the drag has ended
    /// and the main actor drains again.
    nonisolated static func restoredFileForDrag(
        service: any ResticClient,
        secrets: SecretStore,
        repository: Repository,
        settings: AppSettings,
        snapshotID: String,
        node: SnapshotNode
    ) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(dragRestorePrefix)\(UUID().uuidString)")
        _ = try await service.restore(
            await Self.dragContext(repository: repository, settings: settings, secrets: secrets),
            snapshotID: snapshotID,
            node: node,
            destinationDirectory: destination,
            // No progress through the drag path: the drop is the feedback.
            onProgress: nil
        )
        // The same name rule the service's restore branches use: the snapshot
        // names the item, the destination directory decides where it lands.
        return destination.appendingPathComponent(ResticService.sanitizedRestoreName(node.name))
    }

    /// Everything a restic command needs, from pre-captured values, with no
    /// main-actor dependency. One definition of the rules, shared by the
    /// drag path above and the instance `context(for:)`.
    nonisolated static func dragContext(
        repository: Repository,
        settings: AppSettings,
        secrets: SecretStore
    ) async throws -> RepositoryContext {
        #if DEBUG
        // Capture and CI runs hand over the password through the environment
        // so they never touch the login Keychain. Gated on the throwaway-config
        // override as well, so a stale variable in a developer's shell cannot
        // silently feed the wrong password to a normal debug run.
        if let injected = ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_PASSWORD"],
           !injected.isEmpty,
           ProcessInfo.processInfo.environment["SWIFTRESTIC_CONFIG_DIR"] != nil
        {
            return RepositoryContext(
                repository: repository,
                password: injected,
                providerSecret: ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_SECRET"],
                settings: settings
            )
        }
        #endif
        // A Keychain failure surfaces as itself — reading it as nil would
        // re-dress the error as "no password stored" and send the user to
        // fix a password that is sitting right there.
        let stored = try await secrets.load(repository.id)
        guard let password = stored.password, !password.isEmpty else {
            // Deleting a repository cancels its running plans first and
            // removes the secret last, in a detached task — a run suspended
            // at this actor hop can resume after that removal, and the
            // missing password is the race's echo, not the cause. Honouring
            // the cancellation here keeps the run's record `.cancelled`
            // instead of a failure nobody can act on.
            try Task.checkCancellation()
            throw ResticError.passwordMissing(repositoryName: repository.name)
        }
        return RepositoryContext(
            repository: repository,
            password: password,
            providerSecret: stored.providerSecret,
            settings: settings
        )
    }

    /// Prefix shared by every drag-restore staging directory, so the launch
    /// sweep in `bootstrap` and the creator above can never drift apart.
    nonisolated static let dragRestorePrefix = "SwiftRestic-Drag-"

    /// Removes drag-restore staging directories left behind by earlier
    /// sessions. Run at launch only, never at shutdown: Finder may still be
    /// copying from a directory a just-finished drop handed over, and no
    /// callback says when that ends — deleting on our side of the handoff
    /// is a race. A launch sweep has no such window: nothing from a previous
    /// session can still be mid-copy.
    nonisolated static func sweepDragRestoreStaging(fileManager: FileManager = .default) {
        let temp = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(dragRestorePrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}
