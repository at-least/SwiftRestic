import Foundation

extension AppModel {
    /// Everything here is best-effort: the index is a cache, and its
    /// failure never fails the refresh that fed it — the coordinator
    /// records the error and the app keeps reading snapshots through restic.
    ///
    /// This is also how a fresh backup reaches the index: the backup flow's
    /// closing refresh lands here, after retention has released the
    /// repository's exclusive lock, and the backfill loop picks the cheap
    /// diff route or the full read per snapshot.
    ///
    /// `generation` is the listing's number from `nextListingGeneration`;
    /// the repository's index drops a listing older than one it already
    /// took — numbers are compared within one repository only. On the
    /// background lane, so a quit waits for the reconcile instead of
    /// exiting under it.
    func indexReconcile(repositoryID: UUID, listing: [Snapshot], generation: UInt64) {
        tasks.addBackground(Task {
            let taken = await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generation)
            // Only a listing the store took, of a repository still here: a
            // removal clears the entry while a reconcile is in flight, and
            // UUIDs are never reused, so a write after it would stay for the
            // session.
            if taken, repository(id: repositoryID) != nil {
                indexTakenGeneration[repositoryID] = max(indexTakenGeneration[repositoryID] ?? 0, generation)
            }
            // Backfill needs the repository and its credentials; if either is
            // gone mid-refresh, the next refresh retries the whole pass.
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            // Not what keeps a backfill from outliving the quit: the
            // coordinator refuses one once its `shutdown()` has run and
            // cancels and awaits any started before, ahead of
            // `terminateAll`. This check covers the stretch before that
            // call, while the quit waits for the console, which the
            // coordinator cannot see — a backfill started there would spawn
            // restic only to be cancelled moments later. Runs on the main
            // actor, where `isShuttingDown` is set; a hop already under way
            // is the coordinator's to cancel. The next launch resumes the
            // backfill.
            guard !isShuttingDown else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        })
    }

    /// Numbers the listing a refresh is about to read. Taken before restic
    /// is asked: a repository's refreshes run one at a time, so these
    /// numbers order the listings by when they were read — the order the
    /// index must apply them in, which their reconcile hops do not promise.
    /// One counter serves every repository: the index compares a listing's
    /// number only with its own repository's, and each number is newer than
    /// every one handed out before it.
    func nextListingGeneration() -> UInt64 {
        listingGeneration += 1
        return listingGeneration
    }

    /// Throws when the index fails: the Backups tab says so, rather than
    /// reading a broken index as "no backup holds it".
    func indexedHolders(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await indexCoordinator.versions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    func indexedContentVersions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [ContentVersion] {
        try await indexCoordinator.contentVersions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    func kinds(of paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await indexCoordinator.kinds(of: paths, inSnapshot: snapshotID, repositoryID: repositoryID)
    }

    /// Whether the index has read every listed snapshot of the repository —
    /// the Backups tab's and the searches' completeness signal. Not complete
    /// when it has not taken the listing on screen yet, whose answers still
    /// describe the listing before — blind to what this one added or forgot.
    /// Throws when the index cannot answer: read as "still reading", a broken
    /// index would stay a partial answer for good.
    func indexIsComplete(repositoryID: UUID) async throws -> Bool {
        guard indexTakenGeneration[repositoryID] == snapshotsGeneration[repositoryID] else { return false }
        return try await indexCoordinator.isComplete(repositoryID: repositoryID)
    }

    /// Throws the index away and rebuilds it from the listing the model
    /// already holds — the recovery hatch for an index the user no longer
    /// trusts. A reset, not a drop: the repository still exists, so the
    /// reconcile must land even though it runs through the same
    /// coordinator. The listing goes in under the generation it was read
    /// with: the fresh store has taken no number, and a refresh newer than
    /// it still wins. Both are read after the reset, not before: a refresh
    /// whose reconcile reached the old store meanwhile has moved them on,
    /// and the older listing would leave the fresh store behind the
    /// generation `indexIsComplete` reads as taken.
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

    /// The search's hit ceiling, shared with the views that report
    /// truncation — a duplicated constant here and there would drift and
    /// quietly stop the "showing the first matches" footer from appearing.
    static let indexSearchLimit = 200

    /// At most `indexSearchLimit` hits plus whether the index holds more.
    /// The searches ask for one hit past the limit, so a full page is not
    /// called cut short.
    private static func capped<Hit>(_ hits: [Hit]) -> (hits: [Hit], isTruncated: Bool) {
        (Array(hits.prefix(indexSearchLimit)), hits.count > indexSearchLimit)
    }

    /// One repository's search for Search All Backups: instant basename hits
    /// over the indexed paths, each with its version count and newest version
    /// — what a row shows — without the full lists, which can run to
    /// thousands per path, from one read of the index. Throws when the index
    /// itself fails: for a search tool, "the index is broken" must never read
    /// as "nothing matches". The summaries are keyed by the path's bytes
    /// (`PathKey`). Capped by `capped`.
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

    /// Search All Backups: every repository's index, one at a time, each
    /// answering for itself — one broken index leaves the others' rows. Asked
    /// before the search, as every search asks: a backup once read stays read,
    /// so an index complete beforehand has read every backup its hits come
    /// from.
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

    /// The Backups tab's search: instant basename hits over what one chain ever
    /// held — items its newest backup no longer has included — each as the
    /// tree lists it, capped by `capped`. Throws when the index itself
    /// fails, as the other searches do.
    func searchIndex(pattern: String, inChain chainKey: String, repositoryID: UUID) async throws -> (hits: [IndexChild], isTruncated: Bool) {
        let found = try await indexCoordinator.search(
            matching: pattern,
            inChain: chainKey,
            repositoryID: repositoryID,
            limit: AppModel.indexSearchLimit + 1
        )
        return Self.capped(found)
    }

    /// What changed between two snapshots, keyed by normalized path — the
    /// restore browser's Change column — and, when `restic diff` did not
    /// finish, why. A blank row reads as "unchanged" only when the
    /// comparison completed; the pane's header says so when it did not.
    ///
    /// A diff between two content-addressed snapshots is an immutable fact,
    /// so completed walks are cached and a repeat record switch skips the
    /// walk. Only a completed walk is cached: a partial one keeps its map
    /// on screen, flagged as a failure, and never poses as the whole answer
    /// on the next switch.
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
            // Handed over, not awaited, as `children` hands over its
            // listing: the marks are in hand, and the write may queue behind
            // a backfill.
            indexCoordinator.cacheDiff(
                olderID: olderID,
                newerID: newerID,
                changes: collector.changes,
                repositoryID: repositoryID
            )
        } catch {
            // The map keeps whatever streamed before the failure; nothing
            // lands in the cache.
            return ChangeMarks(changes: collector.map, failure: error.localizedDescription)
        }
        return ChangeMarks(changes: collector.map)
    }
}

struct ChangeMarks: Equatable, Sendable {
    /// By bytes (`PathKey`), as every path map is: the NFC and NFD
    /// spellings of one name are two paths to restic, and a String key
    /// would keep one mark for both rows.
    var changes: [PathKey: ResticDiffChange]
    /// Why `restic diff` stopped short; nil when it finished. What streamed
    /// before a failure stays — each mark is still true — but a blank row
    /// no longer means unchanged.
    var failure: String? = nil
}

/// Lock-guarded accumulation of one diff's changes — the stream's callbacks
/// run off the main actor, and a main-actor dictionary cannot be mutated
/// from a `@Sendable` closure.
private final class ChangeMap: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PathKey: ResticDiffChange] = [:]
    private var raw: [ResticDiffChange] = []

    func insert(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        raw.append(change)
        // Directories arrive with restic's trailing slash; the tree keys
        // paths without one. Bytewise (`ResticPath`): a Character test
        // misses the slash after a Prepend character, and that row's mark
        // would never be found.
        storage[Self.key(change)] = change
    }

    static func key(_ change: ResticDiffChange) -> PathKey { PathKey(ResticPath.normalized(change.path)) }

    var map: [PathKey: ResticDiffChange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// The change rows as they streamed, undeduplicated — the cache's
    /// record of the walk.
    var changes: [ResticDiffChange] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }
}
