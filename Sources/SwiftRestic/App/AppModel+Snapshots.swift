import Foundation

extension AppModel {
    // MARK: - Snapshots

    /// Generous ceiling on one repository's `snapshots`/`stats` refresh. A
    /// black-holed SFTP host or S3 endpoint would otherwise hang the refresh —
    /// and, at launch, the scheduler that is armed once it finishes — forever.
    static let refreshTimeout: TimeInterval = 300

    /// The most backups `fileHistory` names to restic, 92 bytes each on the
    /// command line (`--snapshot` and a 64-character ID, with their argv
    /// pointers): 2,000 is ~184 KB of the 1 MiB `ARG_MAX` macOS allows for
    /// arguments and environment together.
    static let fileHistoryNamedLimit = 2_000

    func refreshAllSnapshots() async {
        // Concurrent, not serial: the scheduler is armed only after this
        // returns, so one slow or unreachable remote repository must not delay
        // another's backups. (No lock asks for that order any more: the
        // listing and its stats run lock-free — see `bootstrap`.)
        await withTaskGroup(of: Void.self) { group in
            for repository in configuration.repositories {
                group.addTask { await self.refreshSnapshots(repositoryID: repository.id) }
            }
        }
    }

    func refreshSnapshots(repositoryID: UUID) async {
        guard let repository = repository(id: repositoryID) else { return }
        guard !loadingSnapshots.contains(repositoryID) else {
            // A second refresh while one runs (a backup's closing refresh
            // racing the launch refresh, say) must not be dropped: the first
            // one's listing predates whatever the second one needs to see.
            // Remember it; the in-flight refresh re-runs it when it lands.
            pendingSnapshotRefreshes.insert(repositoryID)
            return
        }
        loadingSnapshots.insert(repositoryID)
        defer {
            loadingSnapshots.remove(repositoryID)
            if pendingSnapshotRefreshes.remove(repositoryID) != nil, !isShuttingDown {
                // Registered on the background lane like the maintenance
                // engine's closing refresh: that lane is what a quit drains,
                // and the guard keeps a shutdown-time unwind from spawning
                // restic work past `terminateAll`.
                tasks.addBackground(Task { [weak self] in
                    await self?.refreshSnapshots(repositoryID: repositoryID)
                })
            }
        }

        do {
            let service = try service()
            let context = try await context(for: repository)
            // Numbered before restic is asked, so the number says when the
            // listing was read, not when its reconcile reaches the index.
            let generation = nextListingGeneration()
            let listing = try await service.snapshots(context, planID: nil, timeout: Self.refreshTimeout)
            // A stats failure must not fail the listing (the rows are the
            // news; the size is decoration), but it must not be invisible
            // either — the banner says what is missing while the rows stay.
            // Announced once per failing stretch, not once per refresh.
            let stats: RepositoryStats?
            do {
                stats = try await service.stats(context, timeout: Self.refreshTimeout)
                statsFailureNoted.remove(repositoryID)
            } catch ResticError.cancelled {
                // The refresh was stopped mid-read: not a stats failure to
                // announce, and not a reason to blank a size an earlier read
                // already established.
                stats = repositoryStats[repositoryID]
            } catch {
                stats = nil
                if !statsFailureNoted.contains(repositoryID) {
                    statsFailureNoted.insert(repositoryID)
                    post(Banner(
                        title: "Could not read “\(repository.name)”'s size",
                        message: error.localizedDescription,
                        isError: false
                    ))
                }
            }
            // The repository can be deleted while its refresh is in flight; a
            // removed entry gets no state, no rows and no banner.
            guard configuration.repository(id: repositoryID) != nil else { return }
            snapshots[repositoryID] = listing
            snapshotsGeneration[repositoryID] = generation
            repositoryStats[repositoryID] = stats
            snapshotListingOutcomes[repositoryID] = .loaded
            snapshotsLoadedAt[repositoryID] = .now
            repositoriesMissingPassword.remove(repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing, generation: generation)
        } catch ResticError.cancelled {
            // A cancelled refresh is the user (or shutdown) stopping the app's
            // own work, not a repository that could not be read: no banner,
            // no failed outcome. Both a cancelled maintenance run's closing
            // refresh and a window close during launch's refresh land here;
            // the next refresh reports the truth.
            return
        } catch ResticError.passwordMissing {
            // Expected before the user has entered a password; not worth a banner.
            // The listing surfaces stay honest through the outcome: "waiting for
            // a password" is a state a user can fix, "no snapshots" is not.
            guard configuration.repository(id: repositoryID) != nil else { return }
            repositoriesMissingPassword.insert(repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(
                "Waiting for a repository password — add it in the repository settings to read this repository."
            )
        } catch let ResticError.commandFailed(code, _) where code == 10 {
            // restic's "does not exist": the repository is not where it was
            // saved — an unplugged volume, a moved folder. Never "empty": the
            // app creates a new repository before keeping it (the editor's
            // save), so it holds no uninitialised one, and at launch nothing
            // has been listed yet to tell the two apart — "0 backups" there
            // read as the history being gone. Earlier rows stay, as for any
            // failed read. Two sentences, because the sidebar shows only the
            // first on one line.
            guard configuration.repository(id: repositoryID) != nil else { return }
            let advice = repository.kind == .local
                ? "Is its disk connected? If it moved, update its path in the repository settings."
                : "Check its location in the repository settings."
            snapshotListingOutcomes[repositoryID] = .failed("Repository missing. \(advice)")
            post(Banner(
                title: "Could not read “\(repository.name)”",
                message: "The repository is missing at \(repository.resticRepositoryString).",
                isError: true
            ))
        } catch {
            // Keep whatever an earlier successful listing produced — stale rows
            // beside an error are worth more to a backup user than a blank card
            // that reads as "nothing backed up".
            guard configuration.repository(id: repositoryID) != nil else { return }
            noteAuthFailure(error, repositoryID: repositoryID)
            snapshotListingOutcomes[repositoryID] = .failed(error.localizedDescription)
            post(Banner(
                title: "Could not read “\(repository.name)”",
                message: error.localizedDescription,
                isError: true
            ))
        }
    }

    /// The listing outcome a surface should render for a repository, `.idle`
    /// when there is none (including the "no repository" case).
    func snapshotListingOutcome(for repositoryID: UUID?) -> SnapshotListingOutcome {
        guard let repositoryID else { return .idle }
        return snapshotListingOutcomes[repositoryID] ?? .idle
    }

    /// When the repository's listing last succeeded, for freshness stamps.
    func snapshotsLoadedAt(for repositoryID: UUID?) -> Date? {
        guard let repositoryID else { return nil }
        return snapshotsLoadedAt[repositoryID]
    }

    /// The repository's backups sorted to where the sidebar shows them:
    /// under its plans, the rest under Other backups.
    func shelves(for repositoryID: UUID) -> BackupShelves {
        backupShelves[repositoryID]
            ?? BackupShelves(listing: [], plans: plans(in: repositoryID), allPlans: configuration.plans)
    }

    /// A plan's backups that would stay behind if it left `repositoryID`,
    /// and the shelf's title as it will read once it has — the sidebar's
    /// own derivation, so a dialog never names a section by a title it
    /// will not have. Nil when the plan holds no backups there.
    func backupsLeftBehind(planID: UUID, in repositoryID: UUID) -> (count: Int, shelfTitle: String)? {
        guard let count = shelves(for: repositoryID).byPlan[planID]?.count, count > 0
        else { return nil }
        return (
            count,
            SidebarTree.otherBackupsTitle(repositoryHasPlans: plans(in: repositoryID).count > 1)
        )
    }

    /// How the sidebar names the place `record` sits — its plan, or its
    /// group under Other backups — for surfaces that name one backup (with
    /// `SnapshotLineage.displayName(of:label:)`) instead of a second rule of
    /// their own.
    func recordLabel(of record: Snapshot, repositoryID: UUID) -> SnapshotLineage.Label? {
        shelves(for: repositoryID).label(
            of: record, repositories: configuration.repositories, localHost: localHostname
        )
    }

    func snapshots(for repositoryID: UUID?, planID: UUID? = nil) -> [Snapshot] {
        guard let repositoryID, let all = snapshots[repositoryID] else { return [] }
        guard let planID else { return all }
        let tag = ResticService.planTag(planID)
        return all.filter { $0.tags.contains(tag) }
    }

    func children(
        repositoryID: UUID,
        snapshotID: String,
        path: String
    ) async throws -> [SnapshotNode] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        // The browse cache first. A snapshot is content-addressed and
        // immutable, so its directory listings are facts that never go stale:
        // a hit answers without the restic round trip — the difference
        // between an instant expand and a fresh process reopening the whole
        // repository on every chevron click. The coordinator hands the hit
        // back already in browser order, so the main actor does no sorting.
        if let cached = await indexCoordinator.cachedBrowserListing(
            snapshotID: snapshotID,
            directory: path,
            repositoryID: repositoryID
        ) {
            return cached
        }
        let (service, context) = try await resticContext(for: repository)
        let nodes = try await service.listDirectory(context, snapshotID: snapshotID, path: path)
        // Write-through, so the next visit to this directory — the record
        // switch that re-walks this spine, the collapse and re-expand — is
        // instant. Best-effort by the coordinator's contract, which also
        // hands the write to a task of its own and returns: the folder never
        // waits on the index's writer, and a quit drains the write in the
        // coordinator's shutdown rather than exiting under it.
        indexCoordinator.cacheListing(
            snapshotID: snapshotID,
            directory: path,
            nodes: nodes,
            repositoryID: repositoryID
        )
        return nodes
    }

    /// Searches a repository's snapshots for a path pattern. A pattern with
    /// no glob character is looked for inside names (`*word*`): restic
    /// matches a pattern against whole names, so a bare word found only an
    /// item named exactly that — "notes" nothing on the demo repository,
    /// "*notes*" six files (probed, restic 0.19.1) — and a bare word is
    /// what a Files tab's "Search All Backups…" hands over, the index's own
    /// search taking words.
    func findFiles(
        repositoryID: UUID,
        pattern: String,
        latestOnly: Bool
    ) async throws -> [FindResult] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let (service, context) = try await resticContext(for: repository)
        let isGlob = pattern.unicodeScalars.contains { "*?[\\".unicodeScalars.contains($0) }
        return try await service.find(
            context,
            patterns: [isGlob ? pattern : "*\(pattern)*"],
            ignoreCase: true,
            snapshotIDs: latestOnly ? ["latest"] : []
        )
    }

    /// One file's node in `backupIDs` — its size and modification time
    /// there — by backup ID, from one `restic find` of its exact path: the
    /// Files view's version rows, which ask for each version's newest
    /// backup. Case-exact, as a path is, and matched by bytes, as the index
    /// keys paths.
    ///
    /// Naming the backups is what keeps it quick: at 1,000 backups of a
    /// 2,060-file tree, every backup took restic 6.9–8.5 s, the 100 its
    /// versions needed 1.9–2.2 s. Past `fileHistoryNamedLimit` the find
    /// searches every backup instead, so the command line stays far inside
    /// the system's argument limit.
    ///
    /// Each answer is kept — for the session (`fileHistoryAnswers`) and in
    /// the index, across launches — and only backups without one are asked:
    /// the pane is made anew for every click, and every find costs a restic
    /// process — 0.5–2 s even on a five-backup local repository, most of it
    /// restic deriving the key — so going back to a file asks nothing, even
    /// after a relaunch, and a version list a new backup grew asks only for
    /// that one.
    func fileHistory(repositoryID: UUID, path: String, backupIDs: [String]) async throws -> [String: SnapshotNode] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let pathKey = PathKey(path)
        func key(_ backupID: String) -> FileHistoryKey {
            FileHistoryKey(repositoryID: repositoryID, backupID: backupID, path: pathKey)
        }
        var unanswered = backupIDs.filter { fileHistoryAnswers[key($0)] == nil }
        unanswered = await answersFromIndexCache(path: path, backupIDs: unanswered, repositoryID: repositoryID)
        if !unanswered.isEmpty {
            let (service, context) = try await resticContext(for: repository)
            let results = try await service.find(
                context,
                patterns: [ResticService.globEscaped(path)],
                ignoreCase: false,
                snapshotIDs: unanswered.count <= Self.fileHistoryNamedLimit ? unanswered : []
            )
            var found: [String: SnapshotNode] = [:]
            for result in results {
                if let match = result.matches.first(where: { PathKey($0.path) == pathKey }) {
                    found[result.snapshot] = match.node
                }
            }
            for (backupID, node) in found { fileHistoryAnswers[key(backupID)] = node }
            indexCoordinator.cacheFileNodes([path: found], repositoryID: repositoryID)
        }
        var history: [String: SnapshotNode] = [:]
        for backupID in backupIDs {
            history[backupID] = fileHistoryAnswers[key(backupID)]
        }
        return history
    }

    /// Fills `fileHistoryAnswers` for one path from the index's cached
    /// nodes; returns the backups it could not answer.
    private func answersFromIndexCache(path: String, backupIDs: [String], repositoryID: UUID) async -> [String] {
        guard !backupIDs.isEmpty else { return [] }
        let pathKey = PathKey(path)
        let kept = await indexCoordinator.cachedFileNodes(path: path, snapshotIDs: backupIDs, repositoryID: repositoryID)
        for (backupID, node) in kept {
            fileHistoryAnswers[FileHistoryKey(repositoryID: repositoryID, backupID: backupID, path: pathKey)] = node
        }
        return backupIDs.filter { kept[$0] == nil }
    }

    /// Reads ahead what a click on each of `files` — one open folder's, all
    /// in one chain — will ask `fileHistory` for: each version's newest
    /// backup, from the index, then whatever neither the session nor the
    /// index has kept, from one `restic find` for all of them. One walk per
    /// backup named serves every file — at five backups, 200 files took
    /// restic 0.61 s against 0.53 s for one — but each backup costs more
    /// with 200 paths to match (at 60 backups, 2.1 s against 1.0 s), so a
    /// click never waits for it: one meanwhile runs its own find, as
    /// before. A folder whose files need more than
    /// `fileHistoryNamedLimit` backups is not read ahead: restic would walk
    /// every backup of the repository. Returned for tests to await.
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
        func key(_ backupID: String, _ path: String) -> FileHistoryKey {
            FileHistoryKey(repositoryID: repositoryID, backupID: backupID, path: PathKey(path))
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
            let rest = await answersFromIndexCache(path: file.path, backupIDs: unanswered, repositoryID: repositoryID)
            if !rest.isEmpty { missing[file.path] = rest }
        }
        // A click answered some meanwhile, or another read-ahead took them.
        for (path, ids) in missing {
            let unanswered = ids.filter { fileHistoryAnswers[key($0, path)] == nil }
            missing[path] = reading(path) || unanswered.isEmpty ? nil : unanswered
        }
        let backupIDs = Set(missing.values.joined())
        guard !missing.isEmpty, backupIDs.count <= Self.fileHistoryNamedLimit, !isShuttingDown else { return }
        let wanted = Dictionary(uniqueKeysWithValues: missing.map { (PathKey($0.key), (path: $0.key, ids: Set($0.value))) })
        let find = Task<Void, any Error> { [self] in
            guard !isShuttingDown else { return }
            let (service, context) = try await resticContext(for: repository)
            let results = try await service.find(
                context,
                patterns: wanted.values.map { ResticService.globEscaped($0.path) },
                ignoreCase: false,
                snapshotIDs: Array(backupIDs)
            )
            // Removed meanwhile: its answers went with it.
            guard self.repository(id: repositoryID) != nil else { return }
            var found: [String: [String: SnapshotNode]] = [:]
            for result in results {
                for match in result.matches {
                    // What a click asks, no more: every backup named holds
                    // the folder's other files too.
                    guard let file = wanted[PathKey(match.path)], file.ids.contains(result.snapshot) else { continue }
                    found[file.path, default: [:]][result.snapshot] = match.node
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

    /// Compares two snapshots; `+` in the result means present only in `newer`.
    func diffSnapshots(
        repositoryID: UUID,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let (service, context) = try await resticContext(for: repository)
        return try await service.diff(
            context,
            olderID: olderID,
            newerID: newerID,
            includeMetadata: includeMetadata
        )
    }
}

/// One file in one backup of one repository: what `fileHistory` keeps an
/// answer under. The path is matched by bytes, as the index keys paths.
struct FileHistoryKey: Hashable {
    let repositoryID: UUID
    let backupID: String
    let path: PathKey
}

/// One file of one repository: what a read-ahead in flight is kept under.
struct FileHistoryFile: Hashable {
    let repositoryID: UUID
    let path: PathKey
}
