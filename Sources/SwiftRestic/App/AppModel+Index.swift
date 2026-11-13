import Foundation

extension AppModel {
    /// Best-effort: the index is a cache, and its failure never fails the
    /// refresh that fed it. A fresh backup reaches the index through the
    /// backup's closing refresh, after retention released the exclusive
    /// lock. On the background lane, so a quit waits for the reconcile.
    func indexReconcile(repositoryID: UUID, listing: [Snapshot], generation: UInt64) {
        tasks.addBackground(Task {
            let taken = await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generation)
            // A removal clears the entry while a reconcile is in flight; a
            // write after it would stay for the session.
            if taken, repository(id: repositoryID) != nil {
                indexTakenGeneration[repositoryID] = max(indexTakenGeneration[repositoryID] ?? 0, generation)
            }
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            // The coordinator's `shutdown()` is what stops backfills at quit.
            // This covers the stretch before it, while the quit waits for
            // the console: a backfill started there would spawn restic only
            // to be cancelled.
            guard !isShuttingDown else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        })
    }

    /// Take it before restic is asked: a repository's refreshes run one at a
    /// time, so the numbers order listings by when they were read, the order
    /// the index must apply them in; their reconcile hops do not keep it.
    func nextListingGeneration() -> UInt64 {
        listingGeneration += 1
        return listingGeneration
    }

    func indexedContentVersions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [ContentVersion] {
        try await indexCoordinator.contentVersions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    func kinds(of paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await indexCoordinator.kinds(of: paths, inSnapshot: snapshotID, repositoryID: repositoryID)
    }

    /// False until the index took the listing on screen: its answers still
    /// describe the listing before. Throws when the index cannot answer:
    /// read as "still reading", a broken index would stay partial for good.
    func indexIsComplete(repositoryID: UUID) async throws -> Bool {
        guard indexTakenGeneration[repositoryID] == snapshotsGeneration[repositoryID] else { return false }
        return try await indexCoordinator.isComplete(repositoryID: repositoryID)
    }

    /// Rebuilds from the listing the model already holds, under the
    /// generation it was read with. Listing and generation are read after
    /// the reset, not before: a refresh reaching the old store meanwhile has
    /// moved them on, and the older listing would leave the fresh store
    /// behind what `indexIsComplete` reads as taken.
    func rebuildIndex(repositoryID: UUID) {
        tasks.addBackground(Task {
            await indexCoordinator.resetRepository(repositoryID: repositoryID)
            indexReconcile(
                repositoryID: repositoryID,
                listing: snapshots[repositoryID] ?? [],
                generation: snapshotsGeneration[repositoryID] ?? 0
            )
        })
    }

    /// Shared with the views that report truncation.
    static let indexSearchLimit = 200

    /// The searches ask for one hit past the limit, so a full page is not
    /// called cut short.
    private static func capped<Hit>(_ hits: [Hit]) -> (hits: [Hit], isTruncated: Bool) {
        (Array(hits.prefix(indexSearchLimit)), hits.count > indexSearchLimit)
    }

    /// Summaries, not full version lists, which can run to thousands per
    /// path. Throws when the index fails: "the index is broken" must never
    /// read as "nothing matches".
    func searchIndexWithSummaries(
        pattern: String,
        repositoryID: UUID
    ) async throws -> (hits: [SearchHit], summaries: [PathKey: VersionSummary], isTruncated: Bool) {
        let found = try await indexCoordinator.searchWithSummaries(
            matching: pattern,
            repositoryID: repositoryID,
            limit: AppModel.indexSearchLimit + 1
        )
        let page = Self.capped(found.hits)
        return (page.hits, found.summaries, page.isTruncated)
    }

    /// One broken index leaves the others' rows. Completeness is asked
    /// before the search: a backup once read stays read, so an index
    /// complete beforehand has read every backup its hits come from.
    func searchAllBackups(pattern: String) async -> AllBackupsSearch {
        var answers: [AllBackupsSearch.Answer] = []
        for repository in configuration.repositories {
            do {
                let isComplete = try await indexIsComplete(repositoryID: repository.id)
                let found = try await searchIndexWithSummaries(pattern: pattern, repositoryID: repository.id)
                let built = FindResultGrouping.indexRows(hits: found.hits, summaries: found.summaries)
                answers.append(AllBackupsSearch.Answer(
                    repositoryID: repository.id,
                    outcome: .rows(built.rows, isTruncated: found.isTruncated || built.dropped > 0, isComplete: isComplete)
                ))
            } catch {
                answers.append(AllBackupsSearch.Answer(repositoryID: repository.id, outcome: .failed(error.localizedDescription)))
            }
        }
        return AllBackupsSearch(answers)
    }

    /// A diff between two content-addressed snapshots never changes, so a
    /// completed walk is cached. A partial one is not: it would pose as the
    /// whole answer on the next switch.
    func snapshotChanges(
        repositoryID: UUID,
        olderID: String,
        newerID: String
    ) async -> ChangeMarks {
        if let cached = await indexCoordinator.cachedDiff(
            olderID: olderID,
            newerID: newerID,
            repositoryID: repositoryID
        ) {
            var map: [PathKey: ResticDiffChange] = [:]
            for change in cached.map(\.resticDiffChange) {
                map[ChangeMap.key(change)] = change
            }
            return ChangeMarks(changes: map)
        }
        guard let repository = repository(id: repositoryID) else {
            return ChangeMarks(changes: [:], failure: ResticError.repositoryRemoved.localizedDescription)
        }
        let collector = ChangeMap()
        do {
            let (service, context) = try await resticContext(for: repository)
            // A line that did not decode throws: a change the map never saw,
            // whose row would read as unchanged, makes the walk as incomplete
            // as one that died, though restic exited cleanly.
            try await service.walkDiff(context, olderID: olderID, newerID: newerID) { change in
                collector.insert(change)
            }
            // Not awaited: the marks are in hand, and the write may queue
            // behind a backfill.
            indexCoordinator.cacheDiff(
                olderID: olderID,
                newerID: newerID,
                changes: collector.changes,
                repositoryID: repositoryID
            )
        } catch {
            return ChangeMarks(changes: collector.map, failure: error.localizedDescription)
        }
        return ChangeMarks(changes: collector.map)
    }
}

struct ChangeMarks: Equatable, Sendable {
    /// By bytes (`PathKey`): NFC and NFD spellings of one name are two paths
    /// to restic, and a String key would keep one mark for both rows.
    var changes: [PathKey: ResticDiffChange]
    /// Nil when `restic diff` finished. Otherwise the marks that streamed
    /// are still true, but a blank row does not mean unchanged.
    var failure: String? = nil
}

/// The stream's callbacks run off the main actor.
private final class ChangeMap: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PathKey: ResticDiffChange] = [:]
    private var raw: [ResticDiffChange] = []

    func insert(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        raw.append(change)
        // Directories arrive with a trailing slash; the tree keys paths
        // without one. Bytewise (`ResticPath`): a Character test misses the
        // slash after a Prepend character.
        storage[Self.key(change)] = change
    }

    static func key(_ change: ResticDiffChange) -> PathKey { PathKey(ResticPath.normalized(change.path)) }

    var map: [PathKey: ResticDiffChange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Undeduplicated: the cache's record of the walk.
    var changes: [ResticDiffChange] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}
