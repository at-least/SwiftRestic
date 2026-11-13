import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    var isRestoring: Bool { restoreActivity != nil }

    /// A progress hop can still be in flight when a cancelled restore
    /// unwinds; the run token, rotated at unwind, drops it so it cannot
    /// resurrect the strip.
    func restoreProgressReporter() -> @Sendable (OperationProgress) -> Void {
        hopWriter(for: .restore) { model, progress in
            model.restoreActivity = progress
        }
    }

    /// `overwrite` has no default, like the service's: no caller should
    /// inherit a destructive one.
    func restore(
        repositoryID: UUID,
        snapshotID: String,
        node: SnapshotNode,
        to destination: URL,
        overwrite: RestoreOverwritePolicy
    ) {
        let reporter = restoreProgressReporter()
        let landing = ResticService.restoredItemURL(named: node.name, in: destination)
        let step = RestoreStep(
            label: node.name,
            description: "Restoring “\(node.name)”",
            snapshotID: snapshotID,
            sourcePath: node.path,
            sourcePaths: nil,
            destinationPath: landing.path,
            itemCount: 1
        ) { service, context in
            try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: destination,
                overwrite: overwrite,
                onProgress: reporter
            )
        }
        beginRestore(repositoryID: repositoryID, steps: [step]) { [weak self] summaries in
            let summary = summaries[0]
            self?.post(Self.restoreBanner(
                itemName: node.name,
                isDirectory: node.isDirectory,
                landing: landing,
                summary: summary,
                policy: overwrite
            ))
        }
    }

    func restore(
        _ selection: RestoreSelection,
        repositoryID: UUID,
        into directories: [URL],
        overwrite: RestoreOverwritePolicy
    ) async {
        precondition(directories.count == selection.sources.count, "one directory per item")
        var items: [(snapshotID: String, node: SnapshotNode, directory: URL)] = []
        do {
            for (source, directory) in zip(selection.sources, directories) {
                let node: SnapshotNode
                if let known = source.node {
                    node = known
                } else if let indexed = try await indexedNode(
                    repositoryID: repositoryID, snapshotID: source.snapshotID, path: source.path
                ) {
                    node = indexed
                } else {
                    node = try await listedNode(repositoryID: repositoryID, snapshotID: source.snapshotID, path: source.path)
                }
                items.append((snapshotID: source.snapshotID, node: node, directory: directory))
            }
        } catch {
            let subject = selection.sources.count == 1 ? "“\(selection.sources[0].name)”" : "the selected items"
            post(Banner(title: "Couldn’t restore \(subject)", message: error.localizedDescription, level: .error))
            return
        }
        guard items.count > 1 else {
            restore(
                repositoryID: repositoryID,
                snapshotID: items[0].snapshotID,
                node: items[0].node,
                to: items[0].directory,
                overwrite: overwrite
            )
            return
        }
        restore(repositoryID: repositoryID, items: items, overwrite: overwrite)
    }

    /// Expects items already deduplicated by `RestoreSelection` and checked
    /// by `RestoreBatch.collidingNames`.
    func restore(
        repositoryID: UUID,
        items: [(snapshotID: String, node: SnapshotNode, directory: URL)],
        overwrite: RestoreOverwritePolicy
    ) {
        let reporter = restoreProgressReporter()
        var backups: [String] = []
        for item in items where !backups.contains(item.snapshotID) { backups.append(item.snapshotID) }
        let steps = backups.flatMap { snapshotID in
            RestoreBatch.groups(items.filter { $0.snapshotID == snapshotID }.map { (node: $0.node, directory: $0.directory) })
                .map { group in
                    let label = Self.itemsLabel(group.nodes.map(\.name))
                    return RestoreStep(
                        label: label,
                        description: group.nodes.count == 1
                            ? "Restoring “\(label)”"
                            : "Restoring “\(group.nodes[0].name)” and \(Format.count(group.nodes.count - 1)) more",
                        snapshotID: snapshotID,
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
        }
        let landings = items.map { ResticService.restoredItemURL(named: $0.node.name, in: $0.directory) }
        let directories = Set(items.map(\.directory))
        beginRestore(repositoryID: repositoryID, steps: steps) { [weak self] summaries in
            self?.post(Self.itemsRestoreBanner(
                landings: landings,
                directory: directories.count == 1 ? directories.first : nil,
                summaries: summaries,
                policy: overwrite
            ))
        }
    }

    nonisolated private static func itemsLabel(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names[0]) and \(Format.count(names.count - 1)) more"
    }

    /// restic's files_restored counts directories too, so only files_skipped
    /// means kept. Under Replace a skipped file already matched the backup,
    /// which is not worth a line.
    nonisolated static func restoreBanner(
        itemName: String,
        isDirectory: Bool,
        landing: URL,
        summary: ResticSummary?,
        policy: RestoreOverwritePolicy
    ) -> Banner {
        let kept = policy == .keepExisting ? summary?.filesSkipped ?? 0 : 0
        if !isDirectory, kept > 0, (summary?.filesRestored ?? 0) == 0 {
            return Banner(
                title: "Kept the existing “\(itemName)”",
                message: "\(landing.path)\nA file with this name was already there, so nothing was restored.",
                level: .notice,
                revealPaths: [landing.path]
            )
        }
        return Banner(
            title: "Restored “\(itemName)”",
            message: [landing.path, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
            level: .notice,
            revealPaths: [landing.path]
        )
    }

    nonisolated static func itemsRestoreBanner(
        landings: [URL],
        directory: URL?,
        summaries: [ResticSummary?],
        policy: RestoreOverwritePolicy
    ) -> Banner {
        let restored = summaries.reduce(0) { $0 + ($1?.filesRestored ?? 0) }
        let kept = policy == .keepExisting ? summaries.reduce(0) { $0 + ($1?.filesSkipped ?? 0) } : 0
        let place = directory?.path ?? "Each item went back to the folder it was backed up from."
        let reveal = landings.map(\.path)
        if kept > 0, restored == 0 {
            return Banner(
                title: "Kept the existing items",
                message: "\(place)\nThey were already there, so nothing was restored.",
                level: .notice,
                revealPaths: reveal
            )
        }
        return Banner(
            title: "Restored \(Format.plural(landings.count, "item"))",
            message: [place, keptLine(kept)].compactMap { $0 }.joined(separator: "\n"),
            level: .notice,
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

    private func beginRestore(
        repositoryID: UUID,
        steps: [RestoreStep],
        onSuccess: @escaping @MainActor ([ResticSummary?]) -> Void
    ) {
        guard !tasks.isOccupied(.restore) else {
            post(Banner(
                title: "A restore is already running",
                message: "Wait for it to finish, or stop it.",
                level: .notice
            ))
            return
        }
        let titles = steps.enumerated().map { index, step in
            steps.count > 1 ? "\(step.description) (\(index + 1) of \(steps.count))…" : "\(step.description)…"
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
                    restoredBefore: steps.count > 1 ? (itemsRestored, itemTotal) : nil
                ) else { break }
                summaries.append(summary)
                itemsRestored += step.itemCount
            }
            if summaries.count == steps.count { onSuccess(summaries) }
            self.restoreActivity = nil
            self.restoreDescription = ""
            self.restoreRepositoryID = nil
            // After the strip clears, so a late progress hop drops. Rotated,
            // not retired: the next restore's reporter is built before its
            // strip is installed.
            self.rotateRunToken(for: .restore)
            self.tasks.clear(.restore)
        }, in: .restore)
    }

    private func runRestoreStep(
        _ step: RestoreStep,
        repositoryID: UUID,
        restoredBefore: (count: Int, total: Int)?
    ) async -> RestoreStepOutcome {
        let snapshotID = step.snapshotID
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
        let transcript = RunTranscript()
        var outcome = RestoreStepOutcome.stopped
        do {
            guard let repository = repository(id: repositoryID) else {
                throw ResticError.repositoryRemoved
            }
            let (service, context) = try await resticContext(for: repository)
            let summary = try await RunTranscript.$current.withValue(transcript) {
                try await step.operation(service, context)
            }
            record.outcome = .succeeded
            // A repeat restore's summary has files_skipped and no
            // files_restored key.
            record.filesRestored = summary?.filesRestored ?? 0
            record.filesSkipped = summary?.filesSkipped ?? 0
            record.bytesProcessed = summary?.bytesRestored ?? 0
            outcome = .succeeded(summary)
        } catch {
            record.setOutcome(
                from: error, cancellationMessage: cancellationMessage,
                location: repository(id: repositoryID).map { (label(of: $0), $0.kind) }
            )
            noteAuthFailure(error, repositoryID: repositoryID)
            let partial = restoredBefore.map {
                "\(Format.count($0.count)) of \(Format.plural($0.total, "item")) were restored before it stopped."
            }
            // nil when the repository's removal cancelled the restore; the
            // removal dialog already said so.
            let repositoryName = repository(id: repositoryID).map { label(of: $0) }
            if record.outcome == .cancelled {
                // Not during shutdown: the quit confirmation already said it.
                if !isShuttingDown {
                    let title = repositoryName.map { "Restore from “\($0)” stopped" } ?? "Restore stopped"
                    post(Banner(
                        title: title,
                        // BannerView hides an empty message.
                        message: partial ?? "",
                        level: .notice
                    ))
                }
            } else {
                let title = repositoryName.map { "Restore from “\($0)” failed" } ?? "Restore failed"
                post(Banner(
                    title: title,
                    message: [record.failureMessage ?? "", partial].compactMap { $0 }.joined(separator: "\n"),
                    level: .error
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

    /// Lists ask on every row mouse-down, so they offer no drag when this is
    /// false instead of `dragRestoreProvider` posting a banner per click.
    func canDragRestore(repositoryID: UUID) -> Bool {
        repository(id: repositoryID) != nil && isResticAvailable
    }

    /// A promised file: the restore runs when Finder's drop asks for the
    /// contents. The load handler must not touch the main actor: the drag
    /// session blocks the main thread on this promise, so a hop deadlocks.
    /// Only the failure banner hops to main, after the drag ends.
    func dragRestoreProvider(repositoryID: UUID, snapshotID: String, node: SnapshotNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        // Finder refuses an empty provider without saying why, so the
        // banner says it at drag start.
        guard let repository = repository(id: repositoryID) else {
            postDragImpossibleBanner(node.name, "This backup location no longer exists. Select a backup from one in the sidebar.")
            return provider
        }
        let service: any ResticClient
        do {
            service = try self.service()
        } catch {
            postDragImpossibleBanner(node.name, error.localizedDescription)
            return provider
        }
        let secrets = self.secrets
        let repositoryLabel = label(of: repository)
        let staging = stagingDirectory
        let itemName = node.name

        // Typed by content, not `public.file-url`: Finder reads that as a
        // URL bookmark (.webloc) and shows the prohibited cursor.
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
                        repositoryLabel: repositoryLabel,
                        snapshotID: snapshotID,
                        node: node,
                        stagingDirectory: staging
                    )
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                    // The drag is over once the promise resolved, so the
                    // main actor drains again.
                    await MainActor.run { [weak self] in
                        guard let self, !self.isShuttingDown else { return }
                        let message = error.localizedDescription
                        self.post(Banner(title: "Couldn’t restore “\(itemName)”", message: message, level: .error))
                    }
                }
            }
            return nil
        }
        return provider
    }

    private func postDragImpossibleBanner(_ itemName: String, _ message: String) {
        post(Banner(title: "Couldn’t restore “\(itemName)”", message: message, level: .error))
    }

    /// `nonisolated` with value inputs: it runs while the main thread waits
    /// on the drag session (see `dragRestoreProvider`). Not a restore run:
    /// no progress strip, run record or banner.
    nonisolated static func restoredFileForDrag(
        service: any ResticClient,
        secrets: SecretStore,
        repository: Repository,
        repositoryLabel: String,
        snapshotID: String,
        node: SnapshotNode,
        stagingDirectory: URL
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let destination = stagingDirectory
            .appendingPathComponent("\(dragRestorePrefix)\(UUID().uuidString)")
        _ = try await service.restore(
            await Self.readContext(for: repository, label: repositoryLabel, secrets: secrets),
            snapshotID: snapshotID,
            node: node,
            destinationDirectory: destination,
            overwrite: .keepExisting,
            onProgress: nil
        )
        return ResticService.restoredItemURL(named: node.name, in: destination)
    }

    /// Off the main actor for the drag path; `context(for:)` caches its
    /// answer.
    nonisolated static func readContext(
        for repository: Repository,
        label: String,
        secrets: SecretStore
    ) async throws -> RepositoryContext {
        // A Keychain failure must throw as itself, not read as "no
        // password stored".
        let stored = try await secrets.load(repository.id)
        guard let password = stored.password, !password.isEmpty else {
            // Deleting a repository cancels its runs, then removes the
            // secret; a run resuming here after that must record cancelled.
            try Task.checkCancellation()
            throw ResticError.passwordMissing(repositoryName: label)
        }
        return RepositoryContext(
            repository: repository,
            password: password,
            providerSecret: stored.providerSecret
        )
    }

    nonisolated static let previewPrefix = "SwiftRestic-Preview-"

    /// A read-only copy for Quick Look, in a folder of its own. Not a
    /// restore run. The caller removes it with `removePreviewCopy`; a
    /// session that ends first leaves it to the launch sweep.
    func previewCopy(repositoryID: UUID, snapshotID: String, node: SnapshotNode) async throws -> URL {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryRemoved }
        let (service, context) = try await resticContext(for: repository)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let folder = stagingDirectory
            .appendingPathComponent("\(Self.previewPrefix)\(UUID().uuidString)")
        do {
            _ = try await service.restore(
                context,
                snapshotID: snapshotID,
                node: node,
                destinationDirectory: folder,
                overwrite: .keepExisting,
                onProgress: nil
            )
            // Quick Look offers to open the copy in an app, and edits saved
            // there would be deleted with it.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: ResticService.restoredItemURL(named: node.name, in: folder).path
            )
        } catch {
            // The restore's error is the one to report; a missed folder is
            // the launch sweep's.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return ResticService.restoredItemURL(named: node.name, in: folder)
    }

    nonisolated static func removePreviewCopy(_ url: URL) throws {
        let folder = url.deletingLastPathComponent()
        precondition(folder.lastPathComponent.hasPrefix(previewPrefix), "not a preview copy: \(url.path)")
        try FileManager.default.removeItem(at: folder)
    }

    nonisolated static let dragRestorePrefix = "SwiftRestic-Drag-"

    /// One per configuration, not the temporary folder itself: every
    /// SwiftRestic instance of this user (scratch, test run) shares that,
    /// and one's launch sweep would delete another's copies.
    nonisolated static func stagingDirectory(for configDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(configDirectory.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.temporaryDirectory.appendingPathComponent("SwiftRestic-Staging-\(name)")
    }

    /// Launch only, never at shutdown: Finder may still be copying from a
    /// just-finished drop, and no callback says when that ends.
    nonisolated static func sweepDragRestoreStaging(in directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in contents where url.lastPathComponent.hasPrefix(dragRestorePrefix)
            || url.lastPathComponent.hasPrefix(previewPrefix) {
            try? fileManager.removeItem(at: url)
        }
    }
}

private struct RestoreStep {
    var label: String
    var description: String
    var snapshotID: String
    var sourcePath: String?
    var sourcePaths: [String]?
    var destinationPath: String
    var itemCount: Int
    var operation: @Sendable (any ResticClient, RepositoryContext) async throws -> ResticSummary?
}

private enum RestoreStepOutcome {
    case succeeded(ResticSummary?)
    case stopped
}
