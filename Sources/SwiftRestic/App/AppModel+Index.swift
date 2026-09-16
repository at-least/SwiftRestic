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
    func indexReconcile(repositoryID: UUID, listing: [Snapshot]) {
        Task {
            await indexCoordinator.reconcile(repositoryID: repositoryID, snapshots: listing)
            // Backfill needs the repository and its credentials; if either is
            // gone mid-refresh, the next refresh retries the whole pass.
            guard let repository = repository(id: repositoryID),
                  let service = try? service(),
                  let context = try? await context(for: repository)
            else { return }
            await indexCoordinator.startBackfill(repositoryID: repositoryID, service: service, context: context)
        }
    }

    /// The versions the index knows for one path, newest first. Empty — not
    /// an error — when the index has not read that path yet; the folder
    /// browser degrades to the newest snapshot and says so.
    func indexedVersions(ofPath path: String, repositoryID: UUID) async -> [IndexedSnapshot] {
        (try? await indexCoordinator.versions(ofPath: path, repositoryID: repositoryID)) ?? []
    }

    /// Whether the index has read every alive snapshot of the repository —
    /// the folder browser's completeness signal. An index that cannot answer
    /// reads as "not complete", never as a failure.
    func indexIsComplete(repositoryID: UUID) async -> Bool {
        (try? await indexCoordinator.isFullyIndexed(repositoryID: repositoryID)) ?? false
    }

    /// Throws the index away and rebuilds it from the listing the model
    /// already holds. The recovery hatch for an index the user no longer
    /// trusts — same path a corrupt file takes, just user-invoked. A reset,
    /// not a drop: the repository still exists, so the reconcile below must
    /// land even though it runs through the same coordinator.
    func rebuildIndex(repositoryID: UUID) {
        let listing = snapshots[repositoryID] ?? []
        Task {
            await indexCoordinator.resetRepository(repositoryID: repositoryID)
            indexReconcile(repositoryID: repositoryID, listing: listing)
        }
    }

    /// Instant basename search over the indexed paths. Throws when the index
    /// itself fails: for a search tool, "the index is broken" must never
    /// read as "nothing matches".
    func searchIndex(
        pattern: String,
        repositoryID: UUID,
        limit: Int = 200
    ) async throws -> [SearchHit] {
        try await indexCoordinator.searchPaths(
            matching: pattern,
            repositoryID: repositoryID,
            limit: limit
        )
    }

    /// What changed between two snapshots, keyed by normalized path — the
    /// restore browser's Change column. Empty on failure; the column then
    /// reads as "no change information" rather than "unchanged".
    ///
    /// A diff between two content-addressed snapshots is an immutable fact,
    /// so completed walks are cached and a repeat record switch skips the
    /// walk entirely. Only a completed walk is cached: a stream that died
    /// partway keeps today's behavior — a partial map on screen — but never
    /// presents itself as the whole answer on the next switch.
    func snapshotChanges(
        repositoryID: UUID,
        olderID: String,
        newerID: String
    ) async -> [String: ResticDiffChange] {
        if let cached = await indexCoordinator.cachedDiff(
            olderID: olderID,
            newerID: newerID,
            repositoryID: repositoryID
        ) {
            var map: [String: ResticDiffChange] = [:]
            for change in cached {
                map[ChangeMap.key(change.path)] = change.resticDiffChange
            }
            return map
        }
        guard let repository = repository(id: repositoryID),
              let service = try? service(),
              let context = try? await context(for: repository)
        else { return [:] }
        let collector = ChangeMap()
        do {
            try await service.walkDiff(context, olderID: olderID, newerID: newerID) { change in
                collector.insert(change)
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
        }
        return collector.map
    }
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
