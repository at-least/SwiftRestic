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

    /// Several items of one backup, each into its directory — one folder for
    /// all, or each back into its own parent — in one restic call per folder
    /// of the backup and directory (`RestoreBatch.groups`,
    /// `ResticService.restoreItems`). Each call is a step of one run with a
    /// record of its own; one banner names the lot. The caller has already
    /// dropped items inside other selected folders and refused names that
    /// would land twice in one directory (`RestoreBatch.covering`,
    /// `collidingNames`).
    func restore(
        repositoryID: UUID,
        snapshotID: String,
        items: [(node: SnapshotNode, directory: URL)],
        overwrite: RestoreOverwritePolicy
    ) {
        let reporter = restoreProgressReporter()
        let steps = RestoreBatch.groups(items).map { group in
            let label = Self.itemsLabel(group.nodes.map(\.name))
            return RestoreStep(
                label: label,
                description: "Restoring \(label)",
                sourcePath: nil,
                sourcePaths: group.nodes.map(\.path),
                destinationPath: group.directory.path,
                itemCount: group.nodes.count,
                operation: { service, context in
                    try await service.restoreItems(
                        context,
                        snapshotID: snapshotID,
                        parent: group.parent,
                        nodes: group.nodes,
                        destinationDirectory: group.directory,
                        overwrite: overwrite,
                        onProgress: reporter
                    )
                }
            )
        }
        let landings = items.map { ResticService.restoredItemURL(for: $0.node, in: $0.directory) }
        let directories = Set(items.map(\.directory))
        beginRestore(repositoryID: repositoryID, snapshotID: snapshotID, steps: steps) { [weak self] summaries in
            self?.post(Self.itemsRestoreBanner(
                landings: landings,
                directory: directories.count == 1 ? directories.first : nil,
                summaries: summaries,
                policy: overwrite
            ))
        }
    }

    /// Several items as one subject — Activity's record, the progress
    /// strip: the first by name, the rest counted.
    nonisolated static func itemsLabel(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names[0]) and \(Format.count(names.count - 1)) more"
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
        // The strip names the backup by SnapshotLineage's one naming rule,
        // as the sheet that started it did; the record keeps the ID, the
        // drawer's vocabulary.
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
    /// files_restored counts directories too, so only files_skipped means
    /// kept. Under Replace a skipped file already matched the backup, which
    /// is not worth a line. "Backup", the restore surfaces' word: the
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
                revealPaths: [landing.path]
            )
        }
        if !isDirectory, kept > 0, (summary?.filesRestored ?? 0) == 0 {
            return Banner(
                title: "Kept the existing “\(itemName)”",
                message: "\(landing.path)\nA file with this name was already there, so nothing was restored.",
                isError: false,
                revealPaths: [landing.path]
            )
        }
        return Banner(
            title: "Restored \(itemName)",
            message: [landing.path, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
            isError: false,
            revealPaths: [landing.path]
        )
    }

    /// The banner a restore of several items posts: how many, where — the
    /// folder they went into, or each back where it was backed up from —
    /// and what Keep left as it was, counted as `restoreBanner` counts it.
    /// Reveal in Finder selects every one of them.
    nonisolated static func itemsRestoreBanner(
        landings: [URL],
        directory: URL?,
        summaries: [ResticSummary?],
        policy: RestoreOverwritePolicy
    ) -> Banner {
        let restored = summaries.reduce(0) { $0 + ($1?.filesRestored ?? 0) }
        let kept = policy == .keepExisting ? summaries.reduce(0) { $0 + ($1?.filesSkipped ?? 0) } : 0
        let place = directory?.path ?? "Each back in the folder it was backed up from."
        let reveal = landings.map(\.path)
        if kept > 0, restored == 0 {
            return Banner(
                title: "Kept the existing items",
                message: "\(place)\nThey were already there, so nothing was restored.",
                isError: false,
                revealPaths: reveal
            )
        }
        return Banner(
            title: "Restored \(Format.plural(landings.count, "item"))",
            message: [place, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
            isError: false,
            revealPaths: reveal
        )
    }

    private nonisolated static func keptLine(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "Kept 1 existing file as it was."
        default: "Kept \(Format.count(count)) existing files as they were."
        }
    }

    /// One item, or a whole backup: a run of one restic restore. See
    /// `beginRestore(repositoryID:snapshotID:steps:onSuccess:)`.
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
        beginRestore(
            repositoryID: repositoryID,
            snapshotID: snapshotID,
            steps: [RestoreStep(
                label: label,
                description: description,
                sourcePath: sourcePath,
                sourcePaths: nil,
                destinationPath: destinationPath,
                itemCount: 1,
                operation: operation
            )],
            onSuccess: { onSuccess($0[0]) }
        )
    }

    /// Shared bookkeeping for every restore shape: one run at a time,
    /// progress published, and each step's outcome written to the run
    /// history either way — with the backup it read (`snapshotID`), the
    /// items (`sourcePath`, `sourcePaths`, neither for a whole backup) and
    /// where they land (`destinationPath`: the restored item itself, or the
    /// folder several items or a whole backup go into), plus the step's
    /// log. A step's `label` is its record's subject in Activity, its
    /// `description` the progress strip's title. The steps run in order and
    /// the first that fails or is cancelled ends the run: its banner says
    /// how many items the steps before it restored, and `onSuccess` (handed
    /// every step's summary) runs only when all of them succeeded.
    private func beginRestore(
        repositoryID: UUID,
        snapshotID: String,
        steps: [RestoreStep],
        onSuccess: @escaping @MainActor ([ResticSummary?]) -> Void
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
        // The strip's title for each step; "(2 of 3)" only when there are
        // several.
        let titles = steps.enumerated().map { index, step in
            steps.count > 1 ? "\(step.description) (\(index + 1) of \(steps.count))" : step.description
        }
        restoreActivity = OperationProgress()
        restoreDescription = titles[0]
        restoreRepositoryID = repositoryID

        tasks.install(Task { [weak self] in
            guard let self else { return }
            var summaries: [ResticSummary?] = []
            let itemTotal = steps.reduce(0) { $0 + $1.itemCount }
            var itemsRestored = 0
            for (index, step) in steps.enumerated() {
                if index > 0 {
                    self.restoreActivity = OperationProgress()
                    self.restoreDescription = titles[index]
                }
                guard case let .succeeded(summary) = await self.runRestoreStep(
                    step,
                    repositoryID: repositoryID,
                    snapshotID: snapshotID,
                    restoredBefore: steps.count > 1 ? (itemsRestored, itemTotal) : nil
                ) else { break }
                summaries.append(summary)
                itemsRestored += step.itemCount
            }
            if summaries.count == steps.count { onSuccess(summaries) }
            self.restoreActivity = nil
            self.restoreDescription = ""
            self.restoreRepositoryID = nil
            // After the strip clears: any progress hop from this run still
            // in flight must find a changed token and drop.
            self.restoreRunToken = UUID()
            self.tasks.clear(.restore)
        }, in: .restore)
    }

    /// One step of a restore run: its record, built, sealed and appended
    /// whatever happens, and its banner when it fails or is cancelled —
    /// saying, in a run of several steps, how many items the earlier ones
    /// restored.
    private func runRestoreStep(
        _ step: RestoreStep,
        repositoryID: UUID,
        snapshotID: String,
        restoredBefore: (count: Int, total: Int)?
    ) async -> RestoreStepOutcome {
        var record = RunRecord(
            kind: .restore,
            planName: step.label,
            repositoryID: repositoryID
        )
        record.snapshotID = snapshotID
        record.snapshotTime = snapshots(for: repositoryID)
            .first { $0.id == snapshotID || $0.shortID == snapshotID }?.time
        record.sourcePath = step.sourcePath
        record.sourcePaths = step.sourcePaths
        record.destinationPath = step.destinationPath
        // Bound around the restore's own restic call only, like the
        // run engines'.
        let transcript = RunTranscript()
        var outcome = RestoreStepOutcome.stopped
        do {
            guard let repository = repository(id: repositoryID) else {
                throw ResticError.repositoryMissing
            }
            let service = try service()
            let context = try await context(for: repository)
            let summary = try await RunTranscript.$current.withValue(transcript) {
                try await step.operation(service, context)
            }
            record.outcome = .succeeded
            // A repeat restore answers with files_skipped alone — no
            // files_restored key — so both are kept, zero when absent.
            record.filesRestored = summary?.filesRestored ?? 0
            record.filesSkipped = summary?.filesSkipped ?? 0
            record.bytesProcessed = summary?.bytesRestored ?? 0
            outcome = .succeeded(summary)
        } catch {
            record.setOutcome(from: error, cancellationMessage: cancellationMessage)
            noteAuthFailure(error, repositoryID: repositoryID)
            let partial = restoredBefore.map {
                "\(Format.count($0.count)) of \(Format.plural($0.total, "item")) were restored before it stopped."
            }
            // The queue is global, so the title names the repository the
            // restore read from — a long restore can outlive the pane that
            // started it. Removing the repository is one thing that cancels
            // a restore, and by then there is no name to say; the removal
            // dialog has already disclosed it.
            let repositoryName = repository(id: repositoryID)?.name
            if record.outcome == .cancelled {
                // The strip vanishing is the only signal a cancelled
                // restore otherwise leaves — including when it is the
                // repository's removal that cancelled it. During shutdown
                // the banner would die with the process, and the quit
                // confirmation has already said it.
                if !isShuttingDown {
                    let title = repositoryName.map { "Restore from “\($0)” cancelled" } ?? "Restore cancelled"
                    post(Banner(
                        title: title,
                        message: ["The restore was cancelled before it finished.", partial]
                            .compactMap { $0 }.joined(separator: " "),
                        isError: false
                    ))
                }
            } else {
                let title = repositoryName.map { "Restore from “\($0)” failed" } ?? "Restore failed"
                post(Banner(
                    title: title,
                    message: [record.failureMessage ?? "", partial].compactMap { $0 }.joined(separator: "\n"),
                    isError: true
                ))
            }
        }
        record.finishedAt = .now
        record.exitCode = transcript.contents.firstExitCode
        await seal(&record, transcript: transcript.contents)
        append(record: record)
        return outcome
    }

    func cancelRestore() { tasks.cancel(.restore) }

    /// Arq's signature restore gesture — drag an item out of the Restore
    /// pane into Finder — as a promised-file provider: the file does not
    /// exist yet, so the drag hands Finder a promise and the restore runs
    /// when the drop asks for the contents. The drop location is the
    /// destination.
    ///
    /// The load handler must not touch the main actor: the drag session
    /// blocks the main thread waiting on this promise, so a hop there
    /// deadlocks. Everything model-derived is captured before the session
    /// starts; only the failure banner hops to main, after the drag ends.
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

        // The promise is typed by *content*, not as a file URL:
        // `public.file-url` declares the file's contents are a URL bookmark
        // (what a .webloc is), and Finder answers that with the prohibited
        // cursor — a content-typed promise is the shape Finder's drop sites
        // accept. `public.data` is the root physical type every file
        // conforms to; a directory's content type is `folder`.
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

    /// The drag restore: restores one node into a fresh throwaway directory
    /// and returns the restored item's URL, which the drag's promised-file
    /// provider hands to Finder.
    ///
    /// `nonisolated`, and handed everything it needs as values, because the
    /// promise's load handler runs *during* the drag session, while the
    /// main thread synchronously waits on it — any hop to the main actor
    /// from there is a self-deadlock. The caller captures the model-derived
    /// inputs before the session starts. Outside `beginRestore`: that path
    /// owns the progress strip, the run history and the "Restored…"
    /// banner, none of which describe a drop whose destination the drag
    /// itself chose. A failed drag posts its banner from the caller, which
    /// hops to main only after the promise resolves — the drag has ended by
    /// then, and the main actor drains again.
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

    /// Prefix of every preview's temporary folder, shared with the launch
    /// sweep and with `removePreviewCopy`, which deletes nothing else.
    nonisolated static let previewPrefix = "SwiftRestic-Preview-"

    /// One version of a file, copied out for Quick Look: dumped into a
    /// fresh temporary folder of its own under its own name, so it opens as
    /// what it is, and read-only. Like the drag restore, not a restore run
    /// — no progress strip, no history, no banner; the preview is the
    /// feedback. A dump that fails takes its folder with it. The caller removes the copy
    /// when the preview closes (`removePreviewCopy`); a session that ends
    /// first leaves it to the launch sweep.
    func previewCopy(repositoryID: UUID, snapshotID: String, node: SnapshotNode) async throws -> URL {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let (service, context) = try await resticContext(for: repository)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.previewPrefix)\(UUID().uuidString)")
        do {
            _ = try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: folder,
                // A fresh folder holds nothing to keep or replace.
                overwrite: .keepExisting,
                onProgress: nil
            )
            // Read-only: Quick Look offers to open the copy in an app, and
            // edits saved there would be deleted with it.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: ResticService.restoredItemURL(for: node, in: folder).path
            )
        } catch {
            // The dump's own error is the one to report; a folder this
            // removal misses is the launch sweep's.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return ResticService.restoredItemURL(for: node, in: folder)
    }

    /// Deletes a preview's copy and its folder — only ever a folder
    /// `previewCopy` made.
    nonisolated static func removePreviewCopy(_ url: URL) throws {
        let folder = url.deletingLastPathComponent()
        precondition(folder.lastPathComponent.hasPrefix(previewPrefix), "not a preview copy: \(url.path)")
        try FileManager.default.removeItem(at: folder)
    }

    /// Prefix shared by every drag-restore staging directory, so the launch
    /// sweep in `bootstrap` and the creator above can never drift apart.
    nonisolated static let dragRestorePrefix = "SwiftRestic-Drag-"

    /// Removes drag-restore staging directories and preview copies left
    /// behind by earlier sessions. Run at launch only, never at shutdown:
    /// Finder may still be copying from a directory a just-finished drop
    /// handed over, and no callback says when that ends — deleting on our
    /// side of the handoff is a race. A launch sweep has no such window:
    /// nothing from a previous session can still be mid-copy.
    nonisolated static func sweepDragRestoreStaging(fileManager: FileManager = .default) {
        let temp = fileManager.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(dragRestorePrefix)
            || url.lastPathComponent.hasPrefix(previewPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}

/// One restic restore in a restore run, with what its run record says
/// about it. See `AppModel.beginRestore(repositoryID:snapshotID:steps:onSuccess:)`.
private struct RestoreStep {
    var label: String
    var description: String
    var sourcePath: String?
    var sourcePaths: [String]?
    var destinationPath: String
    /// How many of the run's items this step restores, for the banner of a
    /// run that stops part-way.
    var itemCount: Int
    var operation: @Sendable (any ResticClient, RepositoryContext) async throws -> ResticSummary?
}

/// How one step of a restore run ended: with restic's summary (which can
/// itself be absent), or failed or cancelled, which ends the run.
private enum RestoreStepOutcome {
    case succeeded(ResticSummary?)
    case stopped
}
