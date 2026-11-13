import Foundation

extension AppModel {
    /// A black-holed SFTP host or S3 endpoint would otherwise hang the
    /// refresh, and that location's due work, forever.
    static let refreshTimeout: TimeInterval = 300

    /// `--snapshot` plus a 64-character ID is 92 bytes a backup, and macOS
    /// caps arguments and environment together at 1 MiB (`ARG_MAX`).
    private static let fileHistoryNamedLimit = 2_000

    /// Activation re-reads older listings, so backups written elsewhere show
    /// up, without spawning restic on every app switch.
    nonisolated static let listingStaleAfter: TimeInterval = 5 * 60

    /// Only read listings: a failed one has its own triggers (Try Again, a
    /// mount, a network change), and re-reading it on activation would
    /// reconnect a share or ask an unreachable server on every switch.
    nonisolated static func isListingStale(
        outcome: SnapshotListingOutcome?, loadedAt: Date?, isLoading: Bool, now: Date
    ) -> Bool {
        guard !isLoading, outcome == .loaded, let loadedAt else { return false }
        return now.timeIntervalSince(loadedAt) >= listingStaleAfter
    }

    func refreshStaleListings(now: Date = .now) {
        guard !isShuttingDown, isResticAvailable else { return }
        for repository in configuration.repositories
            where Self.isListingStale(
                outcome: snapshotListingOutcomes[repository.id],
                loadedAt: snapshotsLoadedAt[repository.id],
                isLoading: loadingSnapshots.contains(repository.id),
                now: now
            )
        {
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
    }

    func readLocationsAtLaunch() async {
        await withTaskGroup(of: Void.self) { group in
            for repository in configuration.repositories {
                group.addTask { await self.readLocationAtLaunch(repositoryID: repository.id) }
            }
        }
    }

    private func readLocationAtLaunch(repositoryID: UUID) async {
        await refreshSnapshots(repositoryID: repositoryID)
        repositoriesAwaitingLaunchListing.remove(repositoryID)
    }

    func refreshSnapshots(repositoryID: UUID) async {
        guard let repository = repository(id: repositoryID) else { return }
        guard !loadingSnapshots.contains(repositoryID) else {
            // Not dropped: the running listing predates what this one needs
            // to see.
            pendingSnapshotRefreshes.insert(repositoryID)
            return
        }
        loadingSnapshots.insert(repositoryID)
        defer {
            loadingSnapshots.remove(repositoryID)
            if pendingSnapshotRefreshes.remove(repositoryID) != nil {
                scheduleSnapshotRefresh(repositoryID: repositoryID)
            }
        }

        // An away drive is not asked about: restic's "does not exist" cannot
        // tell it from a moved folder. No banner: the row and Status section
        // already say it. Earlier rows stay, as for any failed read.
        if await isVolumeMissing(repository) {
            let stayedAway: String?
            do {
                try await reconnectShare(before: repository)
                stayedAway = nil
            } catch {
                stayedAway = error.localizedDescription
            }
            guard configuration.repository(id: repositoryID) != nil else { return }
            if let stayedAway {
                snapshotListingOutcomes[repositoryID] = .failed(stayedAway)
                return
            }
            if await isVolumeMissing(repository), let volume = repository.driveVolumeName {
                snapshotListingOutcomes[repositoryID] = .notConnected(volume: volume)
                return
            }
        }

        // restic retries an unreachable server for about a quarter of an
        // hour, and due work waits for this listing at launch.
        if case let .unreachable(why)? = await probeServer(of: repository) {
            guard configuration.repository(id: repositoryID) != nil else { return }
            snapshotListingOutcomes[repositoryID] = .failed(
                RunRecord.serverUnreachableReason(repositoryName: label(of: repository), why: why)
            )
            return
        }

        do {
            let service = try service()
            let context = try await context(for: repository)
            // Before restic is asked: the number dates the read, not the
            // reconcile.
            let generation = nextListingGeneration()
            let listing = try await service.snapshots(context, planID: nil, timeout: Self.refreshTimeout)
            // Deleted while in flight: no state, rows or banner.
            guard configuration.repository(id: repositoryID) != nil else { return }
            snapshots[repositoryID] = listing
            if let runs = RunRecord.adoptingRewrites(configuration.runs, listing: listing) {
                configuration.runs = runs
            }
            snapshotsGeneration[repositoryID] = generation
            snapshotListingOutcomes[repositoryID] = .loaded
            snapshotsLoadedAt[repositoryID] = .now
            maintenanceAwaitingServer.remove(repositoryID)
            repositoriesMissingPassword.remove(repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing, generation: generation)
            if repository.resticID == nil {
                await recordResticID(of: repositoryID, service: service, context: context)
            }
            // Last: the slower stats walk must not hold back the rows or the
            // upkeep they unblock. Its failure gets a banner, not a failed
            // listing.
            let stats: RepositoryStats?
            do {
                #if DEBUG
                // UI tests delay the size (seconds) to watch rows land first.
                if let seconds = Double(ProcessInfo.processInfo.environment["SWIFTRESTIC_DELAY_STATS"] ?? ""), seconds > 0 {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { throw ResticError.cancelled }
                }
                #endif
                stats = try await service.stats(context, timeout: Self.refreshTimeout)
                statsFailureNoted.remove(repositoryID)
            } catch ResticError.cancelled {
                // Keeps the earlier size, without a banner.
                stats = repositoryStats[repositoryID]
            } catch {
                stats = nil
                if !statsFailureNoted.contains(repositoryID), configuration.repository(id: repositoryID) != nil {
                    statsFailureNoted.insert(repositoryID)
                    post(Banner(
                        title: "Couldn’t read the size of “\(label(of: repository))”",
                        message: error.localizedDescription,
                        level: .warning
                    ))
                }
            }
            guard configuration.repository(id: repositoryID) != nil else { return }
            repositoryStats[repositoryID] = stats
        } catch ResticError.cancelled {
            // No banner and no failed outcome: the next refresh reports.
            return
        } catch ResticError.passwordMissing {
            // Expected before a password is entered: no banner.
            guard configuration.repository(id: repositoryID) != nil else { return }
            repositoriesMissingPassword.insert(repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(
                "No password is saved for “\(label(of: repository))”. Add it to read its backups.",
                fix: .enterPassword(repositoryID)
            )
        } catch let ResticError.commandFailed(code, _) where code == ResticError.repositoryMissingCode {
            // Never shown as empty: the app creates a repository before
            // keeping it, so "does not exist" means it moved. No banner.
            guard configuration.repository(id: repositoryID) != nil else { return }
            snapshotListingOutcomes[repositoryID] = .failed(
                Self.missingRepositoryReason(kind: repository.kind),
                fix: repository.kind == .local ? .locate(repositoryID) : .addRepository
            )
        } catch let ResticError.commandFailed(code, message) where code == ResticError.wrongPasswordCode {
            guard configuration.repository(id: repositoryID) != nil else { return }
            noteAuthFailure(ResticError.commandFailed(exitCode: code, message: message), repositoryID: repositoryID)
            snapshotListingOutcomes[repositoryID] = .passwordRefused(repositoryName: label(of: repository))
        } catch {
            // Earlier rows stay: a blank page reads as "nothing backed up".
            // No banner: the sidebar row and the pages already say it.
            guard configuration.repository(id: repositoryID) != nil else { return }
            noteAuthFailure(error, repositoryID: repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(error.localizedDescription)
        }
    }

    func snapshotListingOutcome(for repositoryID: UUID?) -> SnapshotListingOutcome {
        guard let repositoryID else { return .idle }
        return snapshotListingOutcomes[repositoryID] ?? .idle
    }

    /// Two sentences: the sidebar shows the first alone.
    nonisolated static func missingRepositoryReason(kind: Repository.Kind) -> String {
        kind == .local
            ? ResticError.diskBackupsMissing
            : "Backups not found. If they moved, put them back, or add them where they are now as a new backup location."
    }

    func snapshotsLoadedAt(for repositoryID: UUID?) -> Date? {
        guard let repositoryID else { return nil }
        return snapshotsLoadedAt[repositoryID]
    }

    func shelves(for repositoryID: UUID) -> BackupShelves {
        backupShelves[repositoryID]
            ?? BackupShelves(listing: [], plans: plans(in: repositoryID), allPlans: configuration.plans)
    }

    func backupsLeftBehind(planID: UUID, in repositoryID: UUID) -> Int? {
        guard let count = shelves(for: repositoryID).byPlan[planID]?.count, count > 0
        else { return nil }
        return count
    }

    func recordLabel(of record: Snapshot, repositoryID: UUID) -> SnapshotLineage.Label? {
        shelves(for: repositoryID).label(
            of: record, repositories: configuration.repositories, localHost: localHostname
        )
    }

    func page(ofBackup snapshotID: String, in repositoryID: UUID) -> SidebarItem? {
        snapshots(for: repositoryID).first { $0.id == snapshotID }
            .map { shelves(for: repositoryID).page(of: $0, repositoryID: repositoryID) }
    }

    func snapshots(for repositoryID: UUID?, planID: UUID? = nil) -> [Snapshot] {
        guard let repositoryID, let all = snapshots[repositoryID] else { return [] }
        guard let planID else { return all }
        let tag = ResticService.planTag(planID)
        return all.filter { $0.tags.contains(tag) }
    }

    func latestSnapshot(in repositoryID: UUID?, planID: UUID) -> Snapshot? {
        guard let repositoryID else { return nil }
        let tag = ResticService.planTag(planID)
        return snapshots[repositoryID]?.first { $0.tags.contains(tag) }
    }

    /// The listing is newest first.
    func newestSnapshot(inChain chainKey: String, repositoryID: UUID) -> Snapshot? {
        snapshots(for: repositoryID).first { SnapshotIndex.chainKey(for: $0) == chainKey }
    }

    /// Name, path and kind only: a restore needs nothing else.
    func indexedNode(repositoryID: UUID, snapshotID: String, path: String) async throws -> SnapshotNode? {
        let kinds = try await kinds(of: [path], inSnapshot: snapshotID, repositoryID: repositoryID)
        guard let isDirectory = kinds[PathKey(path)] else { return nil }
        return SnapshotNode(name: ResticPath.basename(of: path), type: isDirectory ? .dir : .file, path: path)
    }

    /// Matched by bytes: a sibling whose name only canonically equals this
    /// one is another file.
    func listedNode(repositoryID: UUID, snapshotID: String, path: String) async throws -> SnapshotNode {
        let siblings = try await children(repositoryID: repositoryID, snapshotID: snapshotID, path: ResticPath.parent(of: path))
        guard let node = siblings.first(where: { PathKey($0.path) == PathKey(path) }) else {
            throw ResticError.itemNotListed(name: ResticPath.basename(of: path))
        }
        return node
    }

    func children(
        repositoryID: UUID,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryRemoved }
        // A snapshot is immutable, so cached listings never go stale.
        if let cached = await indexCoordinator.cachedBrowserListing(
            snapshotID: snapshotID,
            directory: path,
            repositoryID: repositoryID
        ) {
            return cached
        }
        let (service, context) = try await resticContext(for: repository)
        let nodes = try await service.listDirectory(context, snapshotID: snapshotID, path: path)
        // Best-effort, in its own task; the coordinator's shutdown drains it.
        indexCoordinator.cacheListing(
            snapshotID: snapshotID,
            directory: path,
            nodes: nodes,
            repositoryID: repositoryID
        )
        return nodes
    }

    /// One `restic find` of the exact path, matched by bytes. Naming the
    /// backups keeps it quick (unnamed, restic walks every backup); past
    /// `fileHistoryNamedLimit` it names none. Answers are kept in
    /// `fileHistoryAnswers` and the index, and only unanswered backups are
    /// asked.
    func fileHistory(repositoryID: UUID, path: String, snapshotIDs: [String]) async throws -> [String: SnapshotNode] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryRemoved }
        let pathKey = PathKey(path)
        func key(_ snapshotID: String) -> FileHistoryKey {
            FileHistoryKey(repositoryID: repositoryID, snapshotID: snapshotID, path: pathKey)
        }
        var unanswered = snapshotIDs.filter { fileHistoryAnswers[key($0)] == nil }
        unanswered = await answersFromIndexCache(path: path, snapshotIDs: unanswered, repositoryID: repositoryID)
        if !unanswered.isEmpty {
            let (service, context) = try await resticContext(for: repository)
            let results = try await service.find(
                context,
                patterns: [ResticService.globEscaped(path)],
                ignoreCase: false,
                snapshotIDs: unanswered.count <= Self.fileHistoryNamedLimit ? unanswered : []
            )
            // Removed meanwhile: nothing would clear these answers.
            guard self.repository(id: repositoryID) != nil else { throw ResticError.repositoryRemoved }
            var found: [String: SnapshotNode] = [:]
            for result in results {
                if let match = result.matches.first(where: { PathKey($0.path) == pathKey }) {
                    found[result.snapshot] = match.node
                }
            }
            for (snapshotID, node) in found { fileHistoryAnswers[key(snapshotID)] = node }
            indexCoordinator.cacheFileNodes([PathKey(path): found], repositoryID: repositoryID)
        }
        var history: [String: SnapshotNode] = [:]
        for snapshotID in snapshotIDs {
            history[snapshotID] = fileHistoryAnswers[key(snapshotID)]
        }
        return history
    }

    private func answersFromIndexCache(path: String, snapshotIDs: [String], repositoryID: UUID) async -> [String] {
        guard !snapshotIDs.isEmpty else { return [] }
        let pathKey = PathKey(path)
        let kept = await indexCoordinator.cachedFileNodes(path: path, snapshotIDs: snapshotIDs, repositoryID: repositoryID)
        for (snapshotID, node) in kept {
            fileHistoryAnswers[FileHistoryKey(repositoryID: repositoryID, snapshotID: snapshotID, path: pathKey)] = node
        }
        return snapshotIDs.filter { kept[$0] == nil }
    }

    /// What `fileHistory` will be asked for `files` (one folder, one chain),
    /// in one `restic find`. A click never waits for it (one find matching
    /// every path is slower per backup) and runs its own. Not past
    /// `fileHistoryNamedLimit`. A failure reads nothing more; each click
    /// then asks for itself. Returned for tests to await.
    @discardableResult
    func warmFileHistory(_ files: [FileNode]) -> Task<Void, Never> {
        Task { [self] in await readAhead(files) }
    }

    private func readAhead(_ files: [FileNode]) async {
        guard let first = files.first, let repository = repository(id: first.repositoryID) else { return }
        let repositoryID = repository.id
        func key(_ snapshotID: String, _ path: String) -> FileHistoryKey {
            FileHistoryKey(repositoryID: repositoryID, snapshotID: snapshotID, path: PathKey(path))
        }
        func reading(_ path: String) -> Bool {
            fileHistoryReadAheads[FileHistoryFile(repositoryID: repositoryID, path: PathKey(path))] != nil
        }
        var missing: [String: [String]] = [:]
        for file in files where !reading(file.path) {
            guard let versions = try? await indexedContentVersions(
                ofPath: file.path, inChain: file.chainKey, repositoryID: repositoryID
            ) else { return }
            let unanswered = versions.compactMap { $0.snapshots.first?.id }.filter { fileHistoryAnswers[key($0, file.path)] == nil }
            guard !unanswered.isEmpty else { continue }
            let rest = await answersFromIndexCache(path: file.path, snapshotIDs: unanswered, repositoryID: repositoryID)
            if !rest.isEmpty { missing[file.path] = rest }
        }
        // A click answered some meanwhile, or another read-ahead took them.
        for (path, ids) in missing {
            let unanswered = ids.filter { fileHistoryAnswers[key($0, path)] == nil }
            missing[path] = reading(path) || unanswered.isEmpty ? nil : unanswered
        }
        let snapshotIDs = Set(missing.values.joined())
        guard !missing.isEmpty, snapshotIDs.count <= Self.fileHistoryNamedLimit, !isShuttingDown else { return }
        let wanted = Dictionary(uniqueKeysWithValues: missing.map { (PathKey($0.key), (path: $0.key, ids: Set($0.value))) })
        let find = Task<Void, any Error> { [self] in
            guard !isShuttingDown else { return }
            let (service, context) = try await resticContext(for: repository)
            let results = try await service.find(
                context,
                patterns: wanted.values.map { ResticService.globEscaped($0.path) },
                ignoreCase: false,
                snapshotIDs: Array(snapshotIDs)
            )
            guard self.repository(id: repositoryID) != nil else { return }
            var found: [PathKey: [String: SnapshotNode]] = [:]
            for result in results {
                for match in result.matches {
                    // Every backup named holds the folder's other files too.
                    guard let file = wanted[PathKey(match.path)], file.ids.contains(result.snapshot) else { continue }
                    found[PathKey(file.path), default: [:]][result.snapshot] = match.node
                    fileHistoryAnswers[key(result.snapshot, file.path)] = match.node
                }
            }
            indexCoordinator.cacheFileNodes(found, repositoryID: repositoryID)
        }
        let readers = wanted.keys.map { FileHistoryFile(repositoryID: repositoryID, path: $0) }
        for reader in readers { fileHistoryReadAheads[reader] = find }
        _ = await find.result
        for reader in readers where fileHistoryReadAheads[reader] == find { fileHistoryReadAheads[reader] = nil }
    }

}

struct FileHistoryKey: Hashable {
    let repositoryID: UUID
    let snapshotID: String
    let path: PathKey
}

struct FileHistoryFile: Hashable {
    let repositoryID: UUID
    let path: PathKey
}
