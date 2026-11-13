import Foundation

extension AppModel {
    /// Generous ceiling on one repository's `snapshots`/`stats` refresh: a
    /// black-holed SFTP host or S3 endpoint would otherwise hang the refresh,
    /// and that location's due work, forever.
    static let refreshTimeout: TimeInterval = 300

    /// The most backups `fileHistory` names to restic: `--snapshot` plus a
    /// 64-character ID is 92 bytes a backup on the command line, and macOS
    /// caps arguments and environment together at 1 MiB (`ARG_MAX`).
    private static let fileHistoryNamedLimit = 2_000

    /// How old a read listing may be before the app's activation reads it
    /// again: backups written by another Mac or by restic itself show up
    /// without a refresh command, and switching apps back and forth does
    /// not spawn restic each time.
    nonisolated static let listingStaleAfter: TimeInterval = 5 * 60

    /// Only listings that were read: a failed one has its own triggers (Try
    /// Again, a mount, a network change), and re-reading it on every
    /// activation would reconnect a share or ask an unreachable server each
    /// time the user switches back.
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
            // A second refresh while one runs (a backup's closing refresh
            // racing the launch refresh, say) must not be dropped: the first
            // one's listing predates whatever the second one needs to see —
            // a drive gone away mid-read too, which the re-run below states
            // after the first one's outcome.
            pendingSnapshotRefreshes.insert(repositoryID)
            return
        }
        loadingSnapshots.insert(repositoryID)
        defer {
            loadingSnapshots.remove(repositoryID)
            // The background lane is what a quit drains, and the helper's
            // guard keeps a shutdown-time unwind from spawning restic work
            // past `terminateAll`.
            if pendingSnapshotRefreshes.remove(repositoryID) != nil {
                scheduleSnapshotRefresh(repositoryID: repositoryID)
            }
        }

        // The run engine's own check: a local repository whose drive is away
        // is not asked about — restic's "does not exist" could not tell it
        // from a moved folder — and its listing says what a skipped backup
        // says, with no banner: the repository's row, the caveat and the
        // Status section already state it. Its saved network share is
        // reconnected first, as a run does — at launch too, so the share
        // mounts when the app starts; still away, the words say why. Earlier
        // rows stay, as for any failed read. A mount re-reads it
        // (`refreshRepositories(onVolume:)`).
        if await isVolumeMissing(repository) {
            let stayedAway: String?
            do {
                try await reconnectShare(before: repository)
                stayedAway = nil
            } catch {
                stayedAway = error.localizedDescription
            }
            // The repository can be deleted while its share reconnects.
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

        // A network repository's server out of reach is not asked about
        // either: restic retries such a server for about a quarter of an
        // hour, and its due work waits for this listing at launch. Its words
        // are a skipped backup's, with no banner; a network change reads it
        // again (`networkPathChanged`).
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
            // Numbered before restic is asked, so the number says when the
            // listing was read, not when its reconcile reaches the index.
            let generation = nextListingGeneration()
            let listing = try await service.snapshots(context, planID: nil, timeout: Self.refreshTimeout)
            // The repository can be deleted while its refresh is in flight; a
            // removed entry gets no state, no rows and no banner.
            guard configuration.repository(id: repositoryID) != nil else { return }
            snapshots[repositoryID] = listing
            if let runs = RunRecord.adoptingRewrites(configuration.runs, listing: listing) {
                configuration.runs = runs
            }
            snapshotsGeneration[repositoryID] = generation
            snapshotListingOutcomes[repositoryID] = .loaded
            snapshotsLoadedAt[repositoryID] = .now
            // Read, so its server answers: upkeep waiting for it may run.
            maintenanceAwaitingServer.remove(repositoryID)
            repositoriesMissingPassword.remove(repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing, generation: generation)
            if repository.resticID == nil {
                await recordResticID(of: repositoryID, service: service, context: context)
            }
            // The size is decoration, so it is read last: the rows above are
            // the news, and the slower stats walk must not hold them — or the
            // upkeep they unblock — back. A stats failure must not fail the
            // listing, but it must not be invisible either — the banner says
            // what is missing while the rows stay.
            let stats: RepositoryStats?
            do {
                #if DEBUG
                // UI tests hold the size back (SWIFTRESTIC_DELAY_STATS, in
                // seconds) to watch the rows land first. The sleep's
                // cancellation is a stop, not a stats failure.
                if let seconds = Double(ProcessInfo.processInfo.environment["SWIFTRESTIC_DELAY_STATS"] ?? ""), seconds > 0 {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { throw ResticError.cancelled }
                }
                #endif
                stats = try await service.stats(context, timeout: Self.refreshTimeout)
                statsFailureNoted.remove(repositoryID)
            } catch ResticError.cancelled {
                // Stopped mid-read: not a stats failure to announce, and not
                // a reason to blank a size an earlier read established.
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
            // A cancelled refresh is the user (or shutdown) stopping the app's
            // own work, not a repository that could not be read: no banner,
            // no failed outcome — the next refresh reports the truth.
            return
        } catch ResticError.passwordMissing {
            // Expected before the user has entered a password; not worth a
            // banner. The outcome keeps the surfaces honest: "waiting for a
            // password" is a state a user can fix, "no snapshots" is not.
            guard configuration.repository(id: repositoryID) != nil else { return }
            repositoriesMissingPassword.insert(repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(
                "No password is saved for “\(label(of: repository))”. Add it to read its backups.",
                fix: .enterPassword(repositoryID)
            )
        } catch let ResticError.commandFailed(code, _) where code == ResticError.repositoryMissingCode {
            // restic's "does not exist": the repository is not where it was
            // saved — an unplugged volume, a moved folder. Never "empty": the
            // app creates a new repository before keeping it, so it holds no
            // uninitialised one, and at launch nothing has been listed yet to
            // tell the two apart — "0 backups" would read as the history
            // being gone. Earlier rows stay, as for any failed read. Two
            // sentences, because the sidebar shows only the first on one line.
            guard configuration.repository(id: repositoryID) != nil else { return }
            // No banner: the sidebar's row and every page of the repository
            // say it, for as long as it lasts.
            snapshotListingOutcomes[repositoryID] = .failed(
                Self.missingRepositoryReason(kind: repository.kind),
                fix: repository.kind == .local ? .locate(repositoryID) : .addRepository
            )
        } catch let ResticError.commandFailed(code, message) where code == ResticError.wrongPasswordCode {
            // Trying again can't help: the password has to change.
            guard configuration.repository(id: repositoryID) != nil else { return }
            noteAuthFailure(ResticError.commandFailed(exitCode: code, message: message), repositoryID: repositoryID)
            snapshotListingOutcomes[repositoryID] = .passwordRefused(repositoryName: label(of: repository))
        } catch {
            // Keep whatever an earlier successful listing produced — stale
            // rows beside an error beat a blank page that reads as "nothing
            // backed up". No banner: the sidebar's row and every page of the
            // repository say it, for as long as it lasts — a banner over
            // every page said it again.
            guard configuration.repository(id: repositoryID) != nil else { return }
            noteAuthFailure(error, repositoryID: repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(error.localizedDescription)
        }
    }

    func snapshotListingOutcome(for repositoryID: UUID?) -> SnapshotListingOutcome {
        guard let repositoryID else { return .idle }
        return snapshotListingOutcomes[repositoryID] ?? .idle
    }

    /// The listing's words for restic's exit 10 — no repository where this
    /// one is saved: two sentences, the sidebar showing the first alone.
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

    /// The first of `snapshots(for:planID:)`, found without filtering the
    /// rest.
    func latestSnapshot(in repositoryID: UUID?, planID: UUID) -> Snapshot? {
        guard let repositoryID else { return nil }
        let tag = ResticService.planTag(planID)
        return snapshots[repositoryID]?.first { $0.tags.contains(tag) }
    }

    /// The listing's first of the chain — the listing is newest first.
    func newestSnapshot(inChain chainKey: String, repositoryID: UUID) -> Snapshot? {
        snapshots(for: repositoryID).first { SnapshotIndex.chainKey(for: $0) == chainKey }
    }

    /// Name, path and kind only: a restore routes by nothing else.
    func indexedNode(repositoryID: UUID, snapshotID: String, path: String) async throws -> SnapshotNode? {
        let kinds = try await kinds(of: [path], inSnapshot: snapshotID, repositoryID: repositoryID)
        guard let isDirectory = kinds[PathKey(path)] else { return nil }
        return SnapshotNode(name: ResticPath.basename(of: path), type: isDirectory ? .dir : .file, path: path)
    }

    /// Matched by bytes: a sibling whose name only canonically equals this
    /// one is another file. A path the backup no longer lists fails loudly.
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
        // The browse cache first. A snapshot is content-addressed and
        // immutable, so its directory listings are facts that never go stale:
        // a hit answers without a restic process on every chevron click. The
        // coordinator hands the hit back already in browser order, so the
        // main actor does no sorting.
        if let cached = await indexCoordinator.cachedBrowserListing(
            snapshotID: snapshotID,
            directory: path,
            repositoryID: repositoryID
        ) {
            return cached
        }
        let (service, context) = try await resticContext(for: repository)
        let nodes = try await service.listDirectory(context, snapshotID: snapshotID, path: path)
        // Write-through, so the next visit to this directory is instant.
        // Best-effort by the coordinator's contract: the write runs in a task
        // of its own and the folder never waits on the index's writer; the
        // coordinator's shutdown drains it.
        indexCoordinator.cacheListing(
            snapshotID: snapshotID,
            directory: path,
            nodes: nodes,
            repositoryID: repositoryID
        )
        return nodes
    }

    /// One file's node in `snapshotIDs` — its size and modification time
    /// there — by snapshot ID, from one `restic find` of its exact path: the
    /// Backups tab's version rows, which ask for each version's newest
    /// backup. Case-exact, as a path is, and matched by bytes, as the index
    /// keys paths.
    ///
    /// Naming the backups is what keeps it quick — an unnamed find makes
    /// restic walk every backup of the repository. Past
    /// `fileHistoryNamedLimit` the find names none instead, so the command
    /// line stays inside the system's argument limit.
    ///
    /// Each answer is kept — in `fileHistoryAnswers` for the session and in
    /// the index, across launches — and only backups without one are asked:
    /// every find costs a restic process, so going back to a file asks
    /// nothing, and a version list a new backup grew asks only for that one.
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
            // Removed meanwhile: its answers went with it, and nothing would
            // clear these.
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

    /// Reads ahead what a click on each of `files` — one open folder's, all
    /// in one chain — will ask `fileHistory` for: each version's newest
    /// backup, from the index, then whatever neither the session nor the
    /// index has kept, from one `restic find` for all of them. A click never
    /// waits for it — one find matching every path gets slower per backup —
    /// so a click meanwhile runs its own. A folder whose files need more
    /// than `fileHistoryNamedLimit` backups is not read ahead: restic would
    /// walk every backup of the repository. Returned for tests to await.
    ///
    /// A failure — the index's or restic's — keeps what the index had kept
    /// and reads nothing more: each click then asks for its file, and
    /// reports what it is told.
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
            // Removed meanwhile: its answers went with it.
            guard self.repository(id: repositoryID) != nil else { return }
            var found: [PathKey: [String: SnapshotNode]] = [:]
            for result in results {
                for match in result.matches {
                    // What a click asks, no more: every backup named holds
                    // the folder's other files too.
                    guard let file = wanted[PathKey(match.path)], file.ids.contains(result.snapshot) else { continue }
                    found[PathKey(file.path), default: [:]][result.snapshot] = match.node
                    fileHistoryAnswers[key(result.snapshot, file.path)] = match.node
                }
            }
            indexCoordinator.cacheFileNodes(found, repositoryID: repositoryID)
        }
        let readers = wanted.keys.map { FileHistoryFile(repositoryID: repositoryID, path: $0) }
        for reader in readers { fileHistoryReadAheads[reader] = find }
        // Its failure leaves the files unanswered: each click asks again.
        _ = await find.result
        for reader in readers where fileHistoryReadAheads[reader] == find { fileHistoryReadAheads[reader] = nil }
    }

}

/// The path is matched by bytes, as the index keys paths.
struct FileHistoryKey: Hashable {
    let repositoryID: UUID
    let snapshotID: String
    let path: PathKey
}

struct FileHistoryFile: Hashable {
    let repositoryID: UUID
    let path: PathKey
}
