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

    /// The awaitable backfill loop — one `ls` per pending snapshot until the
    /// queue is empty or cancelled. Tests await this directly; production
    /// goes through `startBackfill`.
    func runBackfill(repositoryID: UUID, service: any ResticClient, context: RepositoryContext) async {
        do {
            let store = try self.store(for: repositoryID)
            while !Task.isCancelled {
                guard let next = try await store.pendingBackfill(limit: 1).first else { break }
                try await backfillOne(next, into: store, service: service, context: context)
            }
            outcomes[repositoryID] = nil
        } catch {
            outcomes[repositoryID] = error.localizedDescription
        }
    }

    private func backfillOne(
        _ snapshot: IndexedSnapshot,
        into store: SQLiteIndexStore,
        service: any ResticClient,
        context: RepositoryContext
    ) async throws {
        // The restic stream arrives on a background queue; the buffer flushes
        // chunks into the store synchronously on that same thread, capturing
        // anything thrown so the non-throwing callback can surface it here.
        let buffer = BackfillBuffer(snapshotID: snapshot.id, store: store)
        do {
            try await service.walkSnapshot(context, snapshotID: snapshot.id) { node in
                buffer.append(node.path)
            }
            try buffer.finish()
        } catch {
            buffer.cancel()
            throw error
        }
    }

    // MARK: - Lifecycle

    /// Closes and deletes a repository's index — the index exists only to
    /// serve its repository, so removal takes it along. Any running backfill
    /// is cancelled first.
    func dropRepository(repositoryID: UUID) {
        cancelBackfill(repositoryID: repositoryID)
        stores[repositoryID] = nil
        outcomes[repositoryID] = nil
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent(repositoryID.uuidString + ".sqlite")
        )
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
            try? FileManager.default.removeItem(at: path)
            let store = try SQLiteIndexStore(path: path.path)
            stores[repositoryID] = store
            return store
        }
    }
}

/// Accumulates streamed `ls` paths and hands them to the store in chunks.
///
/// Thread confinement by lock: the restic stream's callbacks arrive on one
/// background queue, while `finish` runs after the await on the actor. The
/// store call is synchronous and transaction-per-chunk, so chunks recorded
/// before a failure or cancellation stay — the snapshot remains pending and
/// the next pass resumes from the top, idempotently.
private final class BackfillBuffer: @unchecked Sendable {
    private let snapshotID: String
    private let store: SQLiteIndexStore
    private let chunkSize = 4_000
    private let lock = NSLock()
    private var pending: [String] = []
    private var captured: Error?
    private var isCancelled = false

    init(snapshotID: String, store: SQLiteIndexStore) {
        self.snapshotID = snapshotID
        self.store = store
    }

    func append(_ path: String) {
        guard !Task.isCancelled else { return }
        var chunk: [String]?
        lock.lock()
        if !isCancelled {
            pending.append(path)
            if pending.count >= chunkSize {
                chunk = pending
                pending = []
            }
        }
        lock.unlock()
        if let chunk { flush(chunk) }
    }

    /// Marks the snapshot fully read — `final: true` is what flips coverage,
    /// and without it the snapshot would sit pending forever. An error
    /// captured mid-stream throws instead, leaving the snapshot pending so
    /// the next pass resumes it.
    func finish() throws {
        lock.lock()
        let remainder = pending
        pending = []
        let failed = captured
        lock.unlock()
        guard failed == nil else { throw failed! }
        flush(remainder)
        try store.recordContent(snapshotID: snapshotID, paths: [], final: true)
    }

    /// Stops accepting paths — the walk above us is unwinding with an error
    /// or cancellation, and half-flushed state is exactly as far as the
    /// resumable design wants to go.
    func cancel() {
        lock.lock()
        isCancelled = true
        pending = []
        lock.unlock()
    }

    private func flush(_ chunk: [String]) {
        guard !chunk.isEmpty else { return }
        do {
            try store.recordContent(snapshotID: snapshotID, paths: chunk, final: false)
        } catch {
            lock.lock()
            if captured == nil { captured = error }
            lock.unlock()
        }
    }
}
