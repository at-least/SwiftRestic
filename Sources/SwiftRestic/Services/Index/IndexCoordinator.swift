import Foundation

/// Owns one SQLite index per repository and keeps it current: reconcile on
/// every snapshot refresh, backfill of snapshots whose content has never been
/// read, and (once a repository is removed) the file's disposal.
///
/// The index is a cache with a rebuild path — the repository is the truth —
/// so nothing here may turn a good refresh or backup into an app-level
/// failure. Failures land in `outcomes[repositoryID]` for a future surface
/// and the app degrades to what it did before the index existed: restic `ls`
/// per browse.
actor IndexCoordinator {
    private let directory: URL
    private var stores: [UUID: SQLiteIndexStore] = [:]
    private var backfillTasks: [UUID: Task<Void, Never>] = [:]
    /// The last index error per repository, if any. Text, not an Error: the
    /// value exists to be shown, not matched.
    private(set) var outcomes: [UUID: String] = [:]

    /// - Parameter directory: injectable so tests never touch the real
    ///   Application Support tree.
    init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.directory = base
    }

    // MARK: - Reconcile

    /// Feeds a fresh `restic snapshots` listing into the repository's index.
    /// Failure is recorded, never thrown: the caller's refresh already
    /// succeeded and does not care.
    func reconcile(repositoryID: UUID, snapshots: [Snapshot]) {
        do {
            let store = try self.store(for: repositoryID)
            _ = try store.reconcile(aliveSnapshots: snapshots)
            outcomes[repositoryID] = nil
        } catch {
            outcomes[repositoryID] = error.localizedDescription
        }
    }

    // MARK: - Backfill

    /// Starts filling in snapshots the index has never read, newest first,
    /// unless one is already running. Each snapshot's paths stream from
    /// `restic ls` in chunks; a cancelled backfill leaves finished chunks
    /// behind, and the snapshot simply stays pending for the next pass.
    func startBackfill(repositoryID: UUID, service: any ResticClient, context: RepositoryContext) {
        guard backfillTasks[repositoryID] == nil else { return }
        backfillTasks[repositoryID] = Task {
            await self.runBackfill(repositoryID: repositoryID, service: service, context: context)
            backfillTasks[repositoryID] = nil
        }
    }

    func cancelBackfill(repositoryID: UUID) {
        backfillTasks[repositoryID]?.cancel()
    }

    /// The awaitable backfill loop — newest first, in batches, until the
    /// queue is empty or cancelled. Each snapshot is built from a diff
    /// against its indexed predecessor when one exists (change-sized, whatever
    /// the snapshot weighs) and from a full `ls` otherwise. A snapshot that
    /// cannot be read — network gone, repository vanished — stays pending and
    /// the batch moves on: stranding the whole queue behind one failure is
    /// what made gaps possible in the first place. Tests await this directly;
    /// production goes through `startBackfill`.
    func runBackfill(repositoryID: UUID, service: any ResticClient, context: RepositoryContext) async {
        var recordedFailure = false
        do {
            let store = try self.store(for: repositoryID)
            while !Task.isCancelled {
                let batch = try await store.pendingBackfill(limit: 16)
                guard !batch.isEmpty else { break }
                var progressed = false
                for next in batch {
                    if Task.isCancelled { break }
                    do {
                        try await backfillOne(
                            next,
                            repositoryID: repositoryID,
                            into: store,
                            service: service,
                            context: context
                        )
                        progressed = true
                    } catch {
                        recordedFailure = true
                        outcomes[repositoryID] = error.localizedDescription
                    }
                }
                // Every snapshot in the batch failed: refetching would serve
                // the same batch again. Leave them pending for a later pass.
                if !progressed { break }
            }
            // A clean sweep clears the last error; a bumpy one keeps it —
            // the next reconcile decides what the current truth is.
            if !recordedFailure {
                outcomes[repositoryID] = nil
            }
        } catch {
            outcomes[repositoryID] = error.localizedDescription
        }
    }

    private func backfillOne(
        _ snapshot: IndexedSnapshot,
        repositoryID: UUID,
        into store: SQLiteIndexStore,
        service: any ResticClient,
        context: RepositoryContext
    ) async throws {
        // The cheap route first: a diff against an already-indexed
        // predecessor. Everything that can go wrong there — no indexed
        // neighbor, a failed or cancelled walk — falls back to the full read,
        // which is always correct and idempotent after whatever landed.
        if let predecessor = try store.predecessorForDelta(of: snapshot.id) {
            do {
                let changes = ChangeCollector()
                try await service.walkDiff(
                    context,
                    olderID: predecessor.id,
                    newerID: snapshot.id
                ) { change in
                    changes.consume(change)
                }
                try store.applyDelta(
                    snapshotID: snapshot.id,
                    previousSeq: predecessor.seq,
                    added: changes.addedPaths,
                    removed: changes.removedPaths
                )
                return
            } catch {
                // The delta attempt is transactional: a failure leaves the
                // snapshot pending and untouched, so the full read below
                // starts clean. Recorded, not fatal — the full read is the
                // safety net this whole design leans on, and if it lands, the
                // loop's end-of-run sweep clears this stale error.
                outcomes[repositoryID] = error.localizedDescription
            }
        }

        // The restic stream arrives on a background queue; the buffer flushes
        // chunks into the store synchronously on that same thread, capturing
        // anything thrown so the non-throwing callback can surface it here.
        let buffer = BackfillBuffer { entries, final in
            try store.recordContent(snapshotID: snapshot.id, entries: entries, final: final)
        }
        do {
            try await service.walkSnapshot(context, snapshotID: snapshot.id) { node in
                buffer.append(IndexedEntry(path: node.path, isDirectory: node.isDirectory))
            }
            try buffer.finish()
        } catch {
            buffer.cancel()
            throw error
        }
    }

    // MARK: - Queries

    /// The versions the index holds for one path, newest first. The folder
    /// browser's core question.
    func versions(ofPath path: String, repositoryID: UUID) throws -> [IndexedSnapshot] {
        try store(for: repositoryID).versions(ofPath: path)
    }

    /// Basename search across every indexed path — instant, no restic walk.
    func searchPaths(matching query: String, repositoryID: UUID, limit: Int) throws -> [SearchHit] {
        try store(for: repositoryID).searchPaths(matching: query, limit: limit)
    }

    /// Whether every alive snapshot's content has been read — the folder
    /// browser's "this version list is complete" signal.
    func isFullyIndexed(repositoryID: UUID) throws -> Bool {
        try store(for: repositoryID).pendingBackfill(limit: 1).isEmpty
    }

    // MARK: - Lifecycle

    /// Closes and deletes a repository's index — the index exists only to
    /// serve its repository, so removal takes it along. Any running backfill
    /// is cancelled first. The WAL and shm sidecars go too: recreating a
    /// database at a path whose stale `-wal` survives is one of SQLite's
    /// documented corruption routes.
    func dropRepository(repositoryID: UUID) {
        cancelBackfill(repositoryID: repositoryID)
        stores[repositoryID] = nil
        outcomes[repositoryID] = nil
        removeIndexFiles(at: directory.appendingPathComponent(repositoryID.uuidString + ".sqlite"))
    }

    // MARK: - Store access

    /// The repository's store, opened on first use. A store that cannot even
    /// be opened twice — a corrupt file, most plausibly — is deleted and
    /// rebuilt from scratch: the index has a full rebuild path, so this is
    /// the fast recovery, not data loss.
    private func store(for repositoryID: UUID) throws -> SQLiteIndexStore {
        if let cached = stores[repositoryID] { return cached }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(repositoryID.uuidString + ".sqlite")
        do {
            let store = try SQLiteIndexStore(path: path.path)
            stores[repositoryID] = store
            return store
        } catch {
            removeIndexFiles(at: path)
            let store = try SQLiteIndexStore(path: path.path)
            stores[repositoryID] = store
            return store
        }
    }

    private func removeIndexFiles(at path: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path.path + suffix)
        }
    }
}

/// Lock-guarded accumulation of one diff's existence changes — the stream's
/// callbacks run off the main actor, and actor-local variables cannot be
/// mutated from a `@Sendable` closure.
private final class ChangeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [String] = []
    private var removed: [String] = []

    func consume(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        // The category split the index cares about is existence: content,
        // type and metadata changes all leave the path in place, so they
        // ride the "extend" default in the store.
        switch change.category {
        case .added: added.append(change.path)
        case .removed: removed.append(change.path)
        case .modified, .metadataOnly: break
        }
    }

    var addedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return added
    }

    var removedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return removed
    }
}

/// Accumulates streamed `ls` paths and hands them to the store in chunks.
///
/// Thread confinement by lock: the restic stream's callbacks arrive on one
/// background queue, while `finish` runs after the await on the actor. The
/// flush call is synchronous and transaction-per-chunk, so chunks recorded
/// before a failure or cancellation stay — the snapshot remains pending and
/// the next pass resumes from the top, idempotently. Internal, not private:
/// the tests drive the failure paths through an injected flush.
final class BackfillBuffer: @unchecked Sendable {
    private let flush: @Sendable ([IndexedEntry], Bool) throws -> Void
    private let chunkSize = 4_000
    private let lock = NSLock()
    private var pending: [IndexedEntry] = []
    private var captured: Error?
    private var isCancelled = false

    /// - Parameter flush: records one chunk; `final: true` flips the
    ///   snapshot's coverage and must only ever run after every chunk landed.
    init(flush: @escaping @Sendable ([IndexedEntry], Bool) throws -> Void) {
        self.flush = flush
    }

    func append(_ entry: IndexedEntry) {
        guard !Task.isCancelled else { return }
        var chunk: [IndexedEntry]?
        lock.lock()
        if !isCancelled {
            pending.append(entry)
            if pending.count >= chunkSize {
                chunk = pending
                pending = []
            }
        }
        lock.unlock()
        if let chunk { flushChunk(chunk, false) }
    }

    /// Marks the snapshot fully read — `final: true` is what flips coverage,
    /// and without it the snapshot would sit pending forever. Any error
    /// captured mid-stream — and any error from the final marker itself —
    /// throws, leaving the snapshot pending for the next pass.
    func finish() throws {
        lock.lock()
        let remainder = pending
        pending = []
        lock.unlock()
        flushChunk(remainder, false)
        lock.lock()
        let failed = captured
        lock.unlock()
        if let failed { throw failed }
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        // A buffer told to stop never declares coverage — the snapshot stays
        // pending and the unwinding walk above handles its own error.
        guard !cancelled else { return }
        // The decisive call propagates directly rather than being captured:
        // a failure here is exactly what must surface.
        try flush([], true)
    }

    /// Stops accepting paths — the walk above us is unwinding with an error
    /// or cancellation, and half-flushed state is exactly as far as the
    /// resumable design wants to go. The coverage marker is not exempt: a
    /// cancelled buffer never declares a snapshot fully read.
    func cancel() {
        lock.lock()
        isCancelled = true
        pending = []
        lock.unlock()
    }

    private func flushChunk(_ chunk: [IndexedEntry], _ final: Bool) {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        guard !cancelled, final || !chunk.isEmpty else { return }
        do {
            try flush(chunk, final)
        } catch {
            lock.lock()
            if captured == nil { captured = error }
            lock.unlock()
        }
    }
}
