import Foundation
import UniformTypeIdentifiers

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

    /// `overwrite` is the destination sheet's choice for files already at
    /// the landing — required, like the service's, so no caller inherits a
    /// destructive default.
    func restore(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode,
        to destination: URL,
        overwrite: RestoreOverwritePolicy
    ) {
        let reporter = restoreProgressReporter()
        let landing = ResticService.restoredItemURL(for: node, in: destination)
        beginRestore(
            repositoryID: repositoryID,
            label: node.name,
            description: "Restoring \(node.name)",
            snapshotID: snapshotID,
            sourcePath: node.path,
            destinationPath: landing.path
        ) { service, context in
            try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination,
                overwrite: overwrite,
                onProgress: reporter
            )
        } onSuccess: { [weak self] summary in
            self?.post(Self.restoreBanner(
                itemName: node.name,
                isDirectory: node.isDirectory,
                landing: landing,
                summary: summary,
                policy: overwrite
            ))
        }
    }

    /// Restores every file in a snapshot, keeping the original absolute layout
    /// beneath `destination`.
    func restoreWholeSnapshot(
        repositoryID: UUID,
        snapshotID: String,
        to destination: URL,
        overwrite: RestoreOverwritePolicy
    ) {
        let reporter = restoreProgressReporter()
        // The strip over every pane, the Restore pane's included, names the
        // backup as the sheet that started it did (SnapshotLineage's one
        // naming rule); the record keeps the ID, the drawer's vocabulary.
        let backup = snapshots(for: repositoryID).first { $0.id == snapshotID || $0.shortID == snapshotID }
        let name = backup.map { SnapshotLineage.displayName(of: $0, label: recordLabel(of: $0, repositoryID: repositoryID)) }
        beginRestore(
            repositoryID: repositoryID,
            label: "snapshot \(snapshotID.prefix(8))",
            description: name.map { "Restoring the whole “\($0)” backup" } ?? "Restoring the whole backup",
            snapshotID: snapshotID,
            sourcePath: nil,
            destinationPath: destination.path
        ) { service, context in
            try await service.restoreWholeSnapshot(
                context,
                snapshotID: snapshotID,
                destinationDirectory: destination,
                overwrite: overwrite,
                onProgress: reporter
            )
        } onSuccess: { [weak self] summary in
            self?.post(Self.restoreBanner(
                itemName: nil,
                isDirectory: true,
                landing: destination,
                summary: summary,
                policy: overwrite
            ))
        }
    }

    /// The banner a finished restore posts: where it landed — the item
    /// itself, which Reveal in Finder selects, or the folder a whole backup
    /// went into — and, under Keep, what restic left as it was. restic's
    /// files_restored counts directories too (a repeat whole-backup restore
    /// "restored" 12 while all 4 files were kept), so only files_skipped
    /// means kept. Under Replace a skipped file already matched the backup,
    /// which is not worth a line. "Backup", the restore surfaces' word: the
    /// Restore pane shows this banner too.
    nonisolated static func restoreBanner(
        itemName: String?,
        isDirectory: Bool,
        landing: URL,
        summary: ResticSummary?,
        policy: RestoreOverwritePolicy
    ) -> Banner {
        let kept = policy == .keepExisting ? summary?.filesSkipped ?? 0 : 0
        guard let itemName else {
            return Banner(
                title: "Restored the whole backup",
                message: [landing.path, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
                isError: false,
                revealPath: landing.path
            )
        }
        if !isDirectory, kept > 0, (summary?.filesRestored ?? 0) == 0 {
            return Banner(
                title: "Kept the existing “\(itemName)”",
                message: "\(landing.path)\nA file with this name was already there, so nothing was restored.",
                isError: false,
                revealPath: landing.path
            )
        }
        return Banner(
            title: "Restored \(itemName)",
            message: [landing.path, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
            isError: false,
            revealPath: landing.path
        )
    }

    private nonisolated static func keptLine(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "Kept 1 existing file as it was."
        default: "Kept \(Format.count(count)) existing files as they were."
        }
    }

    /// Shared bookkeeping for both restore shapes: one at a time, progress
    /// published, and the outcome written to the run history either way —
    /// with the backup it read (`snapshotID` as asked for), the item
    /// (`sourcePath`, nil for a whole backup) and where it lands
    /// (`destinationPath`: the restored item itself, or the folder a whole
    /// backup goes into), plus the run's log. `label` is the record's
    /// subject in Activity, `description` the progress strip's title.
    private func beginRestore(
        repositoryID: UUID,
        label: String,
        description: String,
        snapshotID: String,
        sourcePath: String?,
        destinationPath: String,
        operation: @escaping @Sendable (any ResticClient, RepositoryContext) async throws -> ResticSummary?,
        onSuccess: @escaping @MainActor (ResticSummary?) -> Void
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
        restoreDescription = description
        restoreRepositoryID = repositoryID

        tasks.install(Task { [weak self] in
            guard let self else { return }
            var record = RunRecord(
                kind: .restore,
                planName: label,
                repositoryID: repositoryID
            )
            record.snapshotID = snapshotID
            record.snapshotTime = self.snapshots(for: repositoryID)
                .first { $0.id == snapshotID || $0.shortID == snapshotID }?.time
            record.sourcePath = sourcePath
            record.destinationPath = destinationPath
            // Bound around the restore's own restic call only, like the
            // run engines'.
            let transcript = RunTranscript()
            do {
                guard let repository = self.repository(id: repositoryID) else {
                    throw ResticError.repositoryMissing
                }
                let service = try self.service()
                let context = try await self.context(for: repository)
                let summary = try await RunTranscript.$current.withValue(transcript) {
                    try await operation(service, context)
                }
                record.outcome = .succeeded
                // A repeat restore answers with files_skipped alone — no
                // files_restored key — so both are kept, zero when absent.
                record.filesRestored = summary?.filesRestored ?? 0
                record.filesSkipped = summary?.filesSkipped ?? 0
                record.bytesProcessed = summary?.bytesRestored ?? 0
                onSuccess(summary)
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
            record.exitCode = transcript.contents.firstExitCode
            await self.seal(&record, transcript: transcript.contents)
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

    /// Arq's signature restore gesture — drag an item out of the Restore
    /// pane into Finder — as a promised-file provider: the file does not
    /// exist yet, so the drag hands Finder a promise and the restore runs
    /// when the drop asks for the contents. The drop location is the
    /// destination.
    ///
    /// The load handler must not touch the main actor: it runs while the
    /// drag session holds the main thread synchronously waiting on this
    /// promise (`loadURLSynchronously` → semaphore, under
    /// `_dragUntilMouseUp` — measured deadlock), so everything model-derived
    /// is captured here, *before* the session starts, and the restore runs
    /// entirely in the background. Only the failure banner hops to main,
    /// after the promise resolves and the drag has ended.
    func dragRestoreProvider(repositoryID: UUID, snapshotID: String, node: SnapshotNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        // A provider with nothing registered offers the drop nothing — and
        // saying *why* right here, at drag start, beats a drop that Finder
        // refuses with no explanation of its own.
        guard let repository = repository(id: repositoryID) else {
            postDragImpossibleBanner("The repository no longer exists — pick a backup from a current repository in the sidebar.")
            return provider
        }
        guard let service = try? service() else {
            postDragImpossibleBanner(binaryProblem ?? "restic could not be found.")
            return provider
        }
        let secrets = self.secrets
        let settings = configuration.settings

        // The promise is typed by *content*, not as a file URL: `public.file-url`
        // declares the file's contents are a URL bookmark (what a .webloc is),
        // and Finder answers that with the prohibited cursor (measured live —
        // the drag offered, the drop refused). A content-typed promise is the
        // shape Finder's drop sites accept. `public.data` is the root physical
        // type every file conforms to; a directory's content type is `folder`.
        let contentType: UTType = node.isDirectory ? .folder : .data
        provider.registerFileRepresentation(
            forTypeIdentifier: contentType.identifier,
            fileOptions: [],
            visibility: .all
        ) { [weak self] completion in
            Task<Void, Never>(priority: .userInitiated) {
                do {
                    let url = try await AppModel.restoredFileForDrag(
                        service: service,
                        secrets: secrets,
                        repository: repository,
                        settings: settings,
                        snapshotID: snapshotID,
                        node: node
                    )
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                    // The drag is over by now (the promise resolved or
                    // failed), so the main actor is draining again — and a
                    // drag failing during shutdown stays as quiet as the
                    // UI restore's own failure path.
                    await MainActor.run { [weak self] in
                        guard let self, !self.isShuttingDown else { return }
                        let message = (error as? ResticError)?.errorDescription ?? error.localizedDescription
                        self.post(Banner(title: "Drag restore failed", message: message, isError: true))
                    }
                }
            }
            return nil
        }
        return provider
    }

    /// Dragging is possible but the drop can never land (no repository, no
    /// binary) — named at the moment the drag begins, since the provider
    /// itself has nothing to say.
    private func postDragImpossibleBanner(_ message: String) {
        post(Banner(title: "Cannot drag to restore", message: message, isError: true))
    }

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
            // A fresh UUID directory holds nothing to keep or replace; keep
            // is the mode that cannot clobber if that ever changes.
            overwrite: .keepExisting,
            // No progress through the drag path: the drop is the feedback.
            onProgress: nil
        )
        // The one landing rule the service's restore branches and the run
        // record use: the snapshot names the item, the destination
        // directory decides where it lands.
        return ResticService.restoredItemURL(for: node, in: destination)
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
