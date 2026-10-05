import Foundation

extension AppModel {
    /// Hands a freshly loaded listing to the index and keeps its backfill
    /// moving. Everything here is best-effort: the index is a cache whose
    /// failure never fails the refresh that fed it — the coordinator records
    /// the error and the app reads snapshots through restic as before.
    ///
    /// This is also how a fresh backup reaches the index: the backup flow's
    /// closing refresh lands here, after retention has released the
    /// repository's exclusive lock, and the backfill loop picks the cheap
    /// diff route or the full read per snapshot.
    ///
    /// `generation` is the listing's number from `nextListingGeneration`;
    /// the repository's index drops a listing older than one it already
    /// took — numbers are compared within one repository only.
    /// On the background lane, so a quit waits for the reconcile instead of
    /// exiting under it.
    func indexReconcile(repositoryID: UUID, listing: [Snapshot], generation: UInt64) {
        tasks.addBackground(Task {
            await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generation)
            indexTakenGeneration[repositoryID] = max(indexTakenGeneration[repositoryID] ?? 0, generation)
            // Backfill needs the repository and its credentials; if either is
            // gone mid-refresh, the next refresh retries the whole pass.
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            // Not what keeps a backfill from outliving the quit: the
            // coordinator refuses one once its `shutdown()` has run, and
            // cancels and awaits any started before, all ahead of
            // `terminateAll`. This check covers the stretch before that call,
            // while the quit waits for the console, which the coordinator
            // cannot see: a backfill started there would spawn restic only to
            // be cancelled moments later. It runs on the main actor, where
            // `isShuttingDown` is set, so every reconcile that finishes after
            // the quit began stops here; one whose `startBackfill` hop was
            // already under way is the coordinator's to cancel. The next
            // launch resumes the backfill.
            guard !isShuttingDown else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        })
    }

    /// Numbers the listing a refresh is about to read. Taken before restic
    /// is asked: refreshes of one repository run one at a time, so these
    /// numbers order the listings by when they were read — the order the
    /// index must apply them in, which their reconcile hops do not promise.
    /// One counter serves every repository: the index compares a listing's
    /// number only with its own repository's, and each number is newer than
    /// every one handed out before it, whichever repository took them.
    func nextListingGeneration() -> UInt64 {
        listingGeneration += 1
        return listingGeneration
    }

    /// The backups of one chain — a plan's tag, or a lineage's key — that
    /// hold one path, newest first, from the index. Throws when the index
    /// fails: the Files view says so, rather than reading a broken index as
    /// "no backup holds it".
    func indexedHolders(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await indexCoordinator.versions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    /// What one chain ever held directly under `path`, from the index. Throws
    /// when the index fails: the Files view says so beside the fallback it
    /// lists instead, rather than reading a broken index as an empty folder.
    func indexedChildren(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexChild] {
        try await indexCoordinator.children(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    /// One path's content versions within one chain, from the index. Throws
    /// when the index fails, as `indexedChildren` does.
    func indexedContentVersions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [ContentVersion] {
        try await indexCoordinator.contentVersions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)
    }

    /// What changed directly under one folder from one backup of its chain
    /// to another, from the index — no restic. Nil when the index has not
    /// read both; throws when it fails, as `indexedChildren` does.
    func indexedChanges(
        underPath path: String,
        inChain chainKey: String,
        from olderID: String,
        to newerID: String,
        repositoryID: UUID
    ) async throws -> FolderChanges? {
        try await indexCoordinator.changes(
            underPath: path, inChain: chainKey, from: olderID, to: newerID, repositoryID: repositoryID
        )
    }

    /// Whether the index has read every listed snapshot of the repository —
    /// the Files view's completeness signal. An index that cannot answer
    /// reads as "not complete", never as a failure. So does one that has not
    /// taken the listing on screen yet: its reconcile runs after the listing
    /// lands, and until it returns the index answers for the listing before —
    /// complete for that one, perhaps, but blind to what this one added or
    /// forgot.
    func indexIsComplete(repositoryID: UUID) async -> Bool {
        guard indexTakenGeneration[repositoryID] == snapshotsGeneration[repositoryID] else { return false }
        return (try? await indexCoordinator.isComplete(repositoryID: repositoryID)) ?? false
    }

    /// Throws the index away and rebuilds it from the listing the model
    /// already holds. The recovery hatch for an index the user no longer
    /// trusts — same path a corrupt file takes, just user-invoked. A reset,
    /// not a drop: the repository still exists, so the reconcile below must
    /// land even though it runs through the same coordinator. The listing
    /// goes in under the generation it was read with: the fresh store the
    /// reset leaves has taken no number, and a refresh newer than it still
    /// wins.
    func rebuildIndex(repositoryID: UUID) {
        let listing = snapshots[repositoryID] ?? []
        let generation = snapshotsGeneration[repositoryID] ?? 0
        Task {
            await indexCoordinator.resetRepository(repositoryID: repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing, generation: generation)
        }
    }

    /// The search's hit ceiling, shared with the views that report
    /// truncation — a duplicated constant here and there would drift and
    /// quietly stop the "showing the first matches" footer from appearing.
    static let indexSearchLimit = 200

    /// The Restore pane's search: instant basename hits over the indexed
    /// paths, and which of them `snapshotID` holds — each with its kind in
    /// that snapshot, true for a directory — from one read of the index.
    /// Throws when the index itself fails: for a search tool, "the index is
    /// broken" must never read as "nothing matches". A snapshot the index
    /// has not read holds nothing here; the caller's completeness check
    /// owns that.
    func searchIndexWithMembership(
        pattern: String,
        inSnapshot snapshotID: String,
        repositoryID: UUID
    ) async throws -> SearchWithMembership {
        try await indexCoordinator.searchWithMembership(
            matching: pattern,
            inSnapshot: snapshotID,
            repositoryID: repositoryID,
            limit: AppModel.indexSearchLimit
        )
    }

    /// Find Files' search: instant basename hits over the indexed paths,
    /// each with its version count and newest version — what a row shows —
    /// without the full lists, which can run to thousands per path, from
    /// one read of the index. Throws when the index itself fails, as the
    /// Restore pane's search does; the summaries are keyed by the path's
    /// bytes (`PathKey`).
    func searchIndexWithSummaries(
        pattern: String,
        repositoryID: UUID
    ) async throws -> SearchWithSummaries {
        try await indexCoordinator.searchWithSummaries(
            matching: pattern,
            repositoryID: repositoryID,
            limit: AppModel.indexSearchLimit
        )
    }

    /// A Files tab's search: instant basename hits over what one chain ever
    /// held — items its newest backup no longer has included — each as the
    /// tree lists it, from one read of the index. Throws when the index
    /// itself fails, as the other searches do: "the index is broken" must
    /// never read as "nothing matches".
    func searchIndex(pattern: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexChild] {
        try await indexCoordinator.search(
            matching: pattern,
            inChain: chainKey,
            repositoryID: repositoryID,
            limit: AppModel.indexSearchLimit
        )
    }

    /// What changed between two snapshots, keyed by normalized path — the
    /// restore browser's Change column — and, when `restic diff` did not
    /// finish, why. A blank row reads as "unchanged" only when the
    /// comparison completed; the pane's header says so when it did not.
    ///
    /// A diff between two content-addressed snapshots is an immutable fact,
    /// so completed walks are cached and a repeat record switch skips the
    /// walk entirely. Only a completed walk is cached: a stream that died
    /// partway, or one with lines that did not decode, keeps its partial map
    /// on screen, flagged as a failure, and never presents itself as the
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
            var map: [String: ResticDiffChange] = [:]
            for change in cached {
                // Keyed as `ChangeMap.insert` keys a streamed change.
                map[ResticPath.normalized(change.path)] = change.resticDiffChange
            }
            return ChangeMarks(changes: map)
        }
        guard let repository = repository(id: repositoryID) else {
            return ChangeMarks(changes: [:], failure: ResticError.repositoryMissing.localizedDescription)
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

/// One comparison's marks for the restore browser's Change column.
struct ChangeMarks: Equatable, Sendable {
    var changes: [String: ResticDiffChange]
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
    private var storage: [String: ResticDiffChange] = [:]
    private var raw: [ResticDiffChange] = []

    func insert(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        raw.append(change)
        // Directories arrive with restic's trailing slash; the tree keys
        // paths without one. Bytewise (`ResticPath`): a Character test
        // misses the slash after a Prepend character, and that row's mark
        // would never be found.
        storage[ResticPath.normalized(change.path)] = change
    }

    var map: [String: ResticDiffChange] {
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
