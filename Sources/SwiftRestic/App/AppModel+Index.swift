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
    /// the coordinator drops a listing older than one it already applied.
    /// On the background lane, so a quit waits for the reconcile instead of
    /// exiting under it.
    func indexReconcile(repositoryID: UUID, listing: [Snapshot], generation: UInt64) {
        tasks.addBackground(Task {
            await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generation)
            // Backfill needs the repository and its credentials; if either is
            // gone mid-refresh, the next refresh retries the whole pass.
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            // The backfill is restic work, and a quit that is draining this
            // lane must not have it spawn any past `terminateAll` — the rule
            // the refresh follow-up keeps too. The next launch resumes it.
            guard !isShuttingDown else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        })
    }

    /// Numbers the listing a refresh is about to read. Taken before restic
    /// is asked: refreshes of one repository run one at a time, so these
    /// numbers order the listings by when they were read — the order the
    /// index must apply them in, which their reconcile hops do not promise.
    func nextListingGeneration(_ repositoryID: UUID) -> UInt64 {
        let next = (listingGeneration[repositoryID] ?? 0) + 1
        listingGeneration[repositoryID] = next
        return next
    }

    /// The versions the index knows for one path within one chain — a
    /// plan's tag — newest first. Empty — not an error — when the index has
    /// not read that path yet; the folder browser degrades to the newest
    /// snapshot and says so.
    func indexedVersions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async -> [IndexVersion] {
        (try? await indexCoordinator.versions(ofPath: path, inChain: chainKey, repositoryID: repositoryID)) ?? []
    }

    /// For a whole search result, each path's version count and newest
    /// version — what a Find Files row shows — without the full lists, which
    /// can run to thousands per path. Throws when the index itself fails: a
    /// search that cannot read its index must say so, not read as "nothing
    /// covered"; a path the index holds nothing on is simply absent from the
    /// dictionary, which is keyed by the path's bytes (`PathKey`).
    func indexedSummaries(ofPaths paths: [String], repositoryID: UUID) async throws -> [PathKey: VersionSummary] {
        try await indexCoordinator.versionSummaries(ofPaths: paths, repositoryID: repositoryID)
    }

    /// Which of `paths` one snapshot holds, each with its kind in that
    /// snapshot (true for a directory) — the Restore pane's split of a
    /// search by the open backup. Throws, like the summaries, when the index
    /// fails. A snapshot the index has not read answers `[:]`: nothing about
    /// it is known, which the caller's completeness check owns.
    func indexMembership(ofPaths paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await indexCoordinator.contains(paths: paths, inSnapshot: snapshotID, repositoryID: repositoryID)
    }

    /// Whether the index has read every listed snapshot of the repository —
    /// the folder browser's completeness signal. An index that cannot answer
    /// reads as "not complete", never as a failure.
    func indexIsComplete(repositoryID: UUID) async -> Bool {
        (try? await indexCoordinator.isComplete(repositoryID: repositoryID)) ?? false
    }

    /// Throws the index away and rebuilds it from the listing the model
    /// already holds. The recovery hatch for an index the user no longer
    /// trusts — same path a corrupt file takes, just user-invoked. A reset,
    /// not a drop: the repository still exists, so the reconcile below must
    /// land even though it runs through the same coordinator. The listing
    /// goes in under the generation it was read with; the reset forgot that
    /// it had been applied, and a refresh newer than it still wins.
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

    /// Instant basename search over the indexed paths. Throws when the index
    /// itself fails: for a search tool, "the index is broken" must never
    /// read as "nothing matches".
    func searchIndex(
        pattern: String,
        repositoryID: UUID,
        limit: Int = AppModel.indexSearchLimit
    ) async throws -> [SearchHit] {
        try await indexCoordinator.searchPaths(
            matching: pattern,
            repositoryID: repositoryID,
            limit: limit
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
                map[ChangeMap.key(change.path)] = change.resticDiffChange
            }
            return ChangeMarks(changes: map)
        }
        guard let repository = repository(id: repositoryID) else {
            return ChangeMarks(changes: [:], failure: ResticError.repositoryMissing.localizedDescription)
        }
        let collector = ChangeMap()
        do {
            let (service, context) = try await resticContext(for: repository)
            let malformed = try await service.walkDiff(context, olderID: olderID, newerID: newerID) { change in
                collector.insert(change)
            }
            // A line restic wrote that did not decode is a change the map
            // never saw, whose row would read as unchanged: as incomplete as
            // a walk that died, though restic exited cleanly.
            guard malformed == 0 else {
                throw ResticError.malformedOutput(
                    command: "diff",
                    detail: "\(malformed) change \(malformed == 1 ? "line" : "lines") did not decode"
                )
            }
            await indexCoordinator.cacheDiff(
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

    /// Directories arrive with a trailing slash; the tree keys paths
    /// without one.
    static func key(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    func insert(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        raw.append(change)
        storage[Self.key(change.path)] = change
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
