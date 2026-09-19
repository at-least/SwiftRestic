import Foundation

extension AppModel {
    // MARK: - Snapshots

    /// Generous ceiling on one repository's `snapshots`/`stats` refresh. A
    /// black-holed SFTP host or S3 endpoint would otherwise hang the refresh —
    /// and, at launch, the scheduler that is armed once it finishes — forever.
    static let refreshTimeout: TimeInterval = 300

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
            if pendingSnapshotRefreshes.remove(repositoryID) != nil {
                // In a fresh task: this one's cancellation must not bleed
                // into the rerun (a cancelled in-flight refresh unwinds
                // through here too), and `refreshSnapshots` re-enters the
                // guard cleanly.
                Task { await self.refreshSnapshots(repositoryID: repositoryID) }
            }
        }

        do {
            let service = try service()
            let context = try await context(for: repository)
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
            repositoryStats[repositoryID] = stats
            snapshotListingOutcomes[repositoryID] = .loaded
            snapshotsLoadedAt[repositoryID] = .now
            repositoriesMissingPassword.remove(repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing)
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
            // restic's "nothing here yet" — the expected state between adding a
            // repository and its first init, so it reads as loaded-and-empty.
            // But when an earlier listing had rows, "does not exist" means the
            // repository vanished (an unmounted volume, a moved folder), and
            // emptying the list would trade the user's history for a lie.
            guard configuration.repository(id: repositoryID) != nil else { return }
            if (snapshots[repositoryID] ?? []).isEmpty {
                snapshots[repositoryID] = []
                snapshotListingOutcomes[repositoryID] = .loaded
                snapshotsLoadedAt[repositoryID] = .now
            } else {
                snapshotListingOutcomes[repositoryID] = .failed(
                    "The repository is missing at its saved location — reconnect the volume or update its path in the repository settings."
                )
                post(Banner(
                    title: "Could not read “\(repository.name)”",
                    message: "The repository is missing at \(repository.resticRepositoryString).",
                    isError: true
                ))
            }
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
        // repository on every chevron click.
        if let cached = await indexCoordinator.cachedListing(
            snapshotID: snapshotID,
            directory: path,
            repositoryID: repositoryID
        ) {
            return ResticService.sortedForBrowser(cached.map(\.snapshotNode))
        }
        let service = try service()
        let context = try await context(for: repository)
        let nodes = try await service.listDirectory(context, snapshotID: snapshotID, path: path)
        // Write-through, so the next visit to this directory — the record
        // switch that re-walks this spine, the collapse and re-expand — is
        // instant. Best-effort by the coordinator's contract.
        await indexCoordinator.cacheListing(
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
        let service = try service()
        let context = try await context(for: repository)
        return try await service.find(
            context,
            pattern: pattern,
            ignoreCase: true,
            snapshotID: latestOnly ? "latest" : nil
        )
    }

    /// Compares two snapshots; `+` in the result means present only in `newer`.
    func diffSnapshots(
        repositoryID: UUID,
        olderID: String,
        newerID: String,
        includeMetadata: Bool
    ) async throws -> SnapshotDiff {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryMissing }
        let service = try service()
        let context = try await context(for: repository)
        return try await service.diff(
            context,
            olderID: olderID,
            newerID: newerID,
            includeMetadata: includeMetadata
        )
    }
}
