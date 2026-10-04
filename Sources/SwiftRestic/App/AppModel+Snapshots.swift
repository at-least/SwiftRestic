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
        // another's backups. The ordering itself is kept — refreshing before the
        // scheduler starts means a due plan's retention step cannot collide with
        // our own snapshot listing.
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
        } catch let ResticError.commandFailed(code, _, _) where code == 10 {
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

    /// Searches a repository's snapshots for a path pattern.
    func findFiles(
        repositoryID: UUID,
        pattern: String,
        latestOnly: Bool
    ) async throws -> [FindResult] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let (service, context) = try await resticContext(for: repository)
        return try await service.find(
            context,
            pattern: pattern,
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
    /// Each answer is kept (`fileHistoryAnswers`) and only backups without
    /// one are asked: the pane is made anew for every click, and every find
    /// costs a restic process — 0.5–2 s even on a five-backup local
    /// repository, most of it restic deriving the key — so going back to a
    /// file asks nothing, and a version list a new backup grew asks only
    /// for that one.
    func fileHistory(repositoryID: UUID, path: String, backupIDs: [String]) async throws -> [String: FindMatch] {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let pathKey = PathKey(path)
        let unanswered = backupIDs.filter {
            fileHistoryAnswers[FileHistoryKey(repositoryID: repositoryID, backupID: $0, path: pathKey)] == nil
        }
        if !unanswered.isEmpty {
            let (service, context) = try await resticContext(for: repository)
            let results = try await service.find(
                context,
                pattern: ResticService.globEscaped(path),
                ignoreCase: false,
                snapshotIDs: unanswered.count <= Self.fileHistoryNamedLimit ? unanswered : []
            )
            for result in results {
                if let match = result.matches.first(where: { PathKey($0.path) == pathKey }) {
                    fileHistoryAnswers[FileHistoryKey(repositoryID: repositoryID, backupID: result.snapshot, path: pathKey)] = match
                }
            }
        }
        var history: [String: FindMatch] = [:]
        for id in backupIDs {
            history[id] = fileHistoryAnswers[FileHistoryKey(repositoryID: repositoryID, backupID: id, path: pathKey)]
        }
        return history
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
