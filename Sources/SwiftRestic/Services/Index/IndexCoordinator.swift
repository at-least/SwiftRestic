import Foundation

/// Owns one snapshot index per repository and keeps it current: reconcile on
/// every snapshot refresh, a backfill that reads what the index has not read
/// yet, and (once a repository is removed) the file's disposal.
///
/// The index is a cache with a rebuild path — the repository is the truth —
/// so nothing here may turn a good refresh or backup into an app-level
/// failure. A write that fails is dropped, and the app degrades to restic
/// `ls` per browse.
///
/// Three kinds of work, three homes:
/// - Reads are `nonisolated`. They take the store from `StoreRegistry` and
///   run on the pool's readers, so a search never queues behind a backfill
///   or another repository's reconcile.
/// - Writes, and the backfill's planner read, are synchronous store calls
///   made through `offActor`. GRDB's one writer connection serialises the
///   writes; a multi-second full compare holds that writer, never this
///   actor. The browse-cache captures run in tasks of their own
///   (`CacheWrites`), so the folder or record that produced one never waits
///   on that writer.
/// - The actor keeps the bookkeeping: the backfill tasks, the per-pass skip
///   sets and failure counts, the launch's release of unreadable snapshots,
///   and the order of the steps that close a file. The listing generations
///   live in the store, under its writer (`reconcile(listing:generation:)`).
actor IndexCoordinator {
    /// The configuration's folder, which the index lives inside (see
    /// `indexDirectory`).
    let directory: URL
    /// Where the `<repository>.sqlite` files live: a folder of their own
    /// inside the configuration's, so the orphan sweep can own everything in
    /// it. The configuration folder's own files are never touched (see
    /// `sweepOrphanFiles`).
    nonisolated var indexDirectory: URL {
        directory.appendingPathComponent("index", isDirectory: true)
    }

    /// The one place a repository's index file is named. Tests read it too,
    /// instead of spelling the path a second time.
    nonisolated func fileURL(for repositoryID: UUID) -> URL {
        indexDirectory.appendingPathComponent(repositoryID.uuidString + ".sqlite")
    }

    /// Passes whose full read of one snapshot must fail before the snapshot
    /// is set aside as unreadable. Every failure counts, whatever else the
    /// pass did: each pass follows a refresh whose `restic snapshots` just
    /// succeeded, so the repository was reachable, yet in a pass with
    /// nothing else to read — a repository's only chain, blocked by its own
    /// forward candidate — a bad snapshot is indistinguishable from a bad
    /// connection. A rule counting only failures in passes where other work
    /// landed would never set such a snapshot aside, leaving it to block
    /// every later backup. The cost of a wrong guess is one snapshot left
    /// out until the next launch releases it. The number itself is a guess:
    /// nobody has measured how real repositories fail.
    static let unreadableAfter = 2

    /// The open stores, with the tombstones and in-flight counts that let
    /// the reads skip this actor.
    private let registry = StoreRegistry()
    /// The browse-cache captures handed over and not yet written.
    private let cacheWrites = CacheWrites()
    private var backfillTasks: [UUID: Task<Void, Never>] = [:]
    /// The latest reset or drop per repository; the next one waits for it,
    /// so two never delete files under each other's pool.
    private var closings: [UUID: Task<Void, Never>] = [:]
    /// Repositories whose unreadable snapshots this process has released, or
    /// is releasing — once per launch, by the first reconcile.
    private var released: Set<UUID> = []
    /// Per repository and snapshot: the passes in which its full read
    /// failed. In memory only, like the release: a fresh launch starts every
    /// snapshot's count over.
    private var readFailures: [UUID: [String: Int]] = [:]
    private var reports: [UUID: BackfillReport] = [:]
    private var isShutDown = false

    /// - Parameter directory: injectable so tests never touch the real
    ///   Application Support tree.
    init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.directory = base
    }

    // MARK: - Reconcile

    /// Feeds a fresh `restic snapshots` listing into the repository's index,
    /// then lets housekeeping reclaim what the listing's deaths stranded.
    /// Failure is dropped, never thrown: the caller's refresh already
    /// succeeded and does not care, and the next refresh brings a newer
    /// listing. The first reconcile of a repository in this process first
    /// releases the snapshots an earlier launch set aside as unreadable.
    ///
    /// A listing whose `generation` is not newer than the last one the store
    /// took is dropped unread, and housekeeping with it: it was fetched
    /// before a listing that already landed, and applying it would record as
    /// dead every snapshot that newer listing brought in — a backup's own
    /// snapshot, taken between the two reads, among them. The store compares
    /// under its writer (`reconcile(listing:generation:)`), where the writes
    /// are ordered, so concurrent reconciles need no queue here: whichever
    /// reaches the writer second is compared with the first.
    func reconcile(repositoryID: UUID, snapshots listing: [Snapshot], generation: UInt64) async {
        guard let store = try? await lease(repositoryID) else { return }
        defer { registry.release(repositoryID) }
        do {
            // Marked before the release is awaited, so a reconcile arriving
            // meanwhile does not release again — a second release would hand
            // back anything a backfill set aside in between. Either order of
            // release and the next listing leaves a whole index: the release
            // puts each snapshot above whatever its chain has used so far. A
            // backfill started here may read the failure counts before the
            // presets below land, which costs a still-unreadable released
            // snapshot one extra failed pass. A failed release unmarks for
            // the next reconcile to retry; its own listing is dropped with
            // it, so an older listing arriving later still lands — harmless,
            // nothing newer has.
            if released.insert(repositoryID).inserted {
                do {
                    let retried = try await Self.offActor { try store.releaseUnreadable() }
                    // Each of these failed `unreadableAfter` passes in an
                    // earlier launch, and now sits above its chain's window —
                    // the forward candidate, ahead of every new backup. Still
                    // unreadable, it must not block them for another count
                    // from zero: one more failure sets it aside again.
                    for snapshotID in retried {
                        readFailures[repositoryID, default: [:]][snapshotID] = Self.unreadableAfter - 1
                    }
                } catch {
                    released.remove(repositoryID)
                    throw error
                }
            }
            try await Self.offActor {
                guard try store.reconcile(listing: listing, generation: generation) else { return }
                try store.housekeeping()
            }
        } catch {
            // Dropped: the index answers with what it has until the next
            // refresh, and housekeeping is space, never answers.
        }
    }

    // MARK: - Backfill

    /// Starts reading what the index has not read, unless a backfill of the
    /// repository is already running or the coordinator is shutting down.
    func startBackfill(repositoryID: UUID, service: any ResticClient, context: RepositoryContext) {
        guard !isShutDown, !registry.isRemoved(repositoryID), backfillTasks[repositoryID] == nil else { return }
        backfillTasks[repositoryID] = Task {
            await self.runBackfill(repositoryID: repositoryID, service: service, context: context)
            backfillTasks[repositoryID] = nil
        }
    }

    /// One backfill pass: the index plans each step (`plannedStep`, a pool
    /// read made through `offActor`, so the actor stays free meanwhile for
    /// reconciles, resets and shutdown), and this loop runs it — a delta
    /// through `restic diff` when the window-end snapshot is alive, else a
    /// full `restic ls` streamed in chunks — until nothing is left or the
    /// pass is cancelled. Tests await this directly; production goes
    /// through `startBackfill`.
    ///
    /// A delta that cannot build its target — restic failed, a `T` line, a
    /// line that did not decode, a kind change the index refused — falls
    /// through to the full route for that same target. A step the index
    /// refuses as stale (a reconcile landed between planning and writing) is
    /// planned again once; refused twice, or failed by restic on the full
    /// route, its target sits out the rest of the pass (the skip set), so no
    /// pass reads one snapshot twice and the loop always ends. A snapshot
    /// whose full read fails in `unreadableAfter` passes is set aside as
    /// unreadable at once, which lets its chain's window move past it in the
    /// same pass.
    func runBackfill(repositoryID: UUID, service: any ResticClient, context: RepositoryContext) async {
        guard !isShutDown, let store = try? leaseUnlessClosing(repositoryID) else { return }
        defer { registry.release(repositoryID) }
        var pass = BackfillPass(failures: readFailures[repositoryID] ?? [:])
        steps: while !Task.isCancelled {
            let skip = pass.skip
            guard let planned = try? await Self.offActor({ try store.plannedStep(skipping: skip) }) else { break }
            // Cancelled during the read: nothing was learned, and a step
            // begun now would only start restic for it to be killed.
            guard !Task.isCancelled else { break }
            let step = planned.step
            let end: StepEnd
            switch step {
            case .done:
                break steps
            case let .delta(target, base):
                switch await readDelta(target, from: base, into: store, service: service, context: context) {
                case let .ended(delta):
                    if case .landed = delta { pass.report.deltas += 1 }
                    end = delta
                case let .fallBack(reason):
                    pass.report.count(reason)
                    end = await readFull(target, into: store, service: service, context: context)
                    if case .landed = end { pass.report.fulls += 1 }
                }
            case let .full(target):
                if planned.deadWindowEnd { pass.report.deadWindowEnd += 1 }
                end = await readFull(target, into: store, service: service, context: context)
                if case .landed = end { pass.report.fulls += 1 }
            }
            guard let target = step.target else { break }
            switch end {
            case .landed:
                pass.landed(target)
            case .refused:
                pass.refused(step, target)
            case .failed:
                guard pass.failed(target) else { break }
                try? await Self.offActor { try store.markUnreadable(snapshotID: target) }
                pass.report.markedUnreadable += 1
            case .stopped:
                break steps
            }
        }
        readFailures[repositoryID] = pass.failures
        reports[repositoryID] = pass.report
    }

    /// What the last finished backfill pass of the repository did, route by
    /// route: the tests' view of which route each step took; the app never
    /// reads it.
    func lastBackfillReport(repositoryID: UUID) -> BackfillReport? {
        reports[repositoryID]
    }

    /// How one step ended.
    private enum StepEnd {
        case landed
        /// The index turned the write down because the plan went stale.
        case refused
        /// restic or the index failed the read.
        case failed
        /// The pass was cancelled mid-step; nothing was learned.
        case stopped
    }

    /// How the delta route ended: the step's end, or why the diff cannot
    /// build the target and the full route must.
    private enum DeltaEnd {
        case ended(StepEnd)
        case fallBack(DeltaFallback)
    }

    enum DeltaFallback {
        case typeChange, diffFailed, kindChanged
    }

    /// The delta route. `restic diff <base> <target>` in that order whatever
    /// their ages, so `+` always means "only in the target": a reverse step
    /// (an older target below the window) reads the same way as a forward one.
    private nonisolated func readDelta(
        _ target: String,
        from base: String,
        into store: SnapshotIndex,
        service: any ResticClient,
        context: RepositoryContext
    ) async -> DeltaEnd {
        let collector = DeltaCollector()
        do {
            try await service.walkDiff(context, olderID: base, newerID: target) { change in
                collector.consume(change)
            }
            let delta = try collector.delta()
            try await Self.offActor {
                try store.ingestDelta(
                    snapshotID: target, from: base, added: delta.added, removed: delta.removed, modified: delta.modified
                )
            }
            return .ended(.landed)
        } catch {
            if Self.isCancellation(error) { return .ended(.stopped) }
            switch error {
            case IncompleteStream.typeChange: return .fallBack(.typeChange)
            case IndexError.kindChanged: return .fallBack(.kindChanged)
            default: return Self.isRefusal(error) ? .ended(.refused) : .fallBack(.diffFailed)
            }
        }
    }

    /// The full route: `beginFull`, the `restic ls` stream flushed in chunks
    /// as it arrives (on the runner's reader thread, never this actor), then
    /// the final chunk and the compare. A stream with lines that did not
    /// decode (the walk throws) or with no node at all never reaches the
    /// final: applied, it would close the runs of every path it failed to
    /// mention.
    private nonisolated func readFull(
        _ target: String,
        into store: SnapshotIndex,
        service: any ResticClient,
        context: RepositoryContext
    ) async -> StepEnd {
        let buffer = BackfillBuffer { entries, final in
            try store.ingestFull(snapshotID: target, entries: entries, final: final)
        }
        do {
            try await Self.offActor { try store.beginFull(snapshotID: target) }
            try await service.walkSnapshot(context, snapshotID: target) { node in
                buffer.append(IndexedEntry(path: node.path, isDirectory: node.isDirectory))
            }
            try await Self.offActor { try buffer.finish() }
            return .landed
        } catch {
            buffer.cancel()
            if Self.isCancellation(error) { return .stopped }
            return Self.isRefusal(error) ? .refused : .failed
        }
    }

    /// A cancelled pass stops where it is: a walk killed by cancellation
    /// fails like a broken one, and must neither fall through to the full
    /// route nor count against the snapshot. A stop is what the run records
    /// call one (`ResticError.isCancellation`), or this task's own
    /// cancellation, whatever error the walk unwound with.
    private static func isCancellation(_ error: Error) -> Bool {
        Task.isCancelled || ResticError.isCancellation(error)
    }

    /// The index's refusals of a stale plan: the snapshot died or returned,
    /// was set aside, or the window moved between planning and writing. The
    /// next plan knows better, so the step is planned again.
    private static func isRefusal(_ error: Error) -> Bool {
        guard let error = error as? IndexError else { return false }
        switch error {
        case .unknownSnapshot, .notAdjacent, .wrongBase, .unreadable,
             .streamIdentityChanged, .poisonedStream, .noSession:
            return true
        case .kindChanged, .schemaMismatch, .repositoryRemoved:
            return false
        }
    }

    /// Runs a synchronous store call — a write, or the planner's read — on
    /// the global executor, so the actor stays free for the steps of other
    /// repositories and for reset, drop and shutdown while GRDB works.
    private static func offActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }

    // MARK: - Reads

    /// The indexed snapshots holding one path within one chain — a plan's
    /// tag — newest first, in SQL. The Files view's core question.
    nonisolated func versions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await read(repositoryID) { try await $0.versions(ofPath: path, inChain: chainKey) }
    }

    /// Everything one chain ever held directly under a folder, items its
    /// newest backup no longer has included — the Files view's tree level.
    nonisolated func children(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexChild] {
        try await read(repositoryID) { try await $0.children(ofPath: path, inChain: chainKey) }
    }

    /// One path's content versions within one chain — the Files view's
    /// version list.
    nonisolated func contentVersions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [ContentVersion] {
        try await read(repositoryID) { try await $0.contentVersions(ofPath: path, inChain: chainKey) }
    }

    /// What changed directly under one folder between two backups of a
    /// chain — a Files tab's folder against the backup before.
    nonisolated func changes(
        underPath path: String,
        inChain chainKey: String,
        from olderID: String,
        to newerID: String,
        repositoryID: UUID
    ) async throws -> FolderChanges? {
        try await read(repositoryID) {
            try await $0.changes(underPath: path, inChain: chainKey, from: olderID, to: newerID)
        }
    }

    /// The Restore pane's search: basename hits across every indexed path —
    /// instant, no restic walk — and which of them the open backup holds,
    /// with their kind there, from one read of the index.
    nonisolated func searchWithMembership(
        matching query: String,
        inSnapshot snapshotID: String,
        repositoryID: UUID,
        limit: Int
    ) async throws -> SearchWithMembership {
        try await read(repositoryID) {
            try await $0.searchWithMembership(matching: query, limit: limit, inSnapshot: snapshotID)
        }
    }

    /// Find Files' search: the hits and each one's version summary, from
    /// one read of the index.
    nonisolated func searchWithSummaries(matching query: String, repositoryID: UUID, limit: Int) async throws -> SearchWithSummaries {
        try await read(repositoryID) { try await $0.searchWithSummaries(matching: query, limit: limit) }
    }

    /// A Files tab's search: basename hits within one chain, each as the
    /// tree lists it, from one read of the index.
    nonisolated func search(
        matching query: String,
        inChain chainKey: String,
        repositoryID: UUID,
        limit: Int
    ) async throws -> [IndexChild] {
        try await read(repositoryID) { try await $0.search(matching: query, inChain: chainKey, limit: limit) }
    }

    /// Which of `paths` a snapshot holds, each with its kind there — the
    /// Restore pane's incomplete strip asks it of the backup before.
    nonisolated func kinds(of paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await read(repositoryID) { try await $0.contains(paths: paths, inSnapshot: snapshotID) }
    }

    /// Whether every listed snapshot has been read — the consumers' "the
    /// index answers exactly" signal.
    nonisolated func isComplete(repositoryID: UUID) async throws -> Bool {
        try await read(repositoryID) { try await $0.isComplete() }
    }

    /// Runs `body` on the repository's store, opened on first use and
    /// counted in flight until `body` returns, so a reset or drop waits for
    /// it before closing the pool. A reset in progress is sat out; a dropped
    /// repository throws `repositoryRemoved`, however late the caller came.
    /// Internal, not private: the tests hold a read open across a reset, and
    /// read through it what the app never asks — a path's versions across
    /// every chain, and the path-keyed reads they hold the searches to.
    nonisolated func read<T: Sendable>(
        _ repositoryID: UUID,
        _ body: @Sendable (SnapshotIndex) async throws -> T
    ) async throws -> T {
        let store = try await lease(repositoryID)
        defer { registry.release(repositoryID) }
        return try await body(store)
    }

    // MARK: - Browse caches

    /// The cached `restic ls` answer for one directory, or nil when nothing
    /// was captured — or when the cache itself failed. A miss is an
    /// invitation to restic, never an error.
    nonisolated func cachedListing(snapshotID: String, directory: String, repositoryID: UUID) async -> [CachedListingNode]? {
        await cacheAccess(repositoryID) { try await $0.listing(snapshotID: snapshotID, directory: directory) } ?? nil
    }

    /// The cached listing mapped and sorted into the browser's row order,
    /// nil on miss. `nonisolated async`, so the sort runs on the global
    /// executor and the caller — the main actor — never pays the
    /// directory-sized `localizedStandardCompare` pass that the live
    /// `listDirectory` path already does off-main inside the service: the
    /// hit is the path that exists to be instant.
    nonisolated func cachedBrowserListing(snapshotID: String, directory: String, repositoryID: UUID) async -> [SnapshotNode]? {
        guard let cached = await cachedListing(
            snapshotID: snapshotID, directory: directory, repositoryID: repositoryID
        ) else { return nil }
        return ResticService.sortedForBrowser(cached.map(\.snapshotNode))
    }

    /// Captures one directory's listing for next time, and returns at once:
    /// the write runs in a task of its own (`CacheWrites`). The caller has
    /// the listing in hand, and the write queues on the index's one writer,
    /// which a backfill's chunk or full compare holds for seconds at scale —
    /// a folder must not wait on a cache. Best-effort: a failed write costs
    /// only the next visit's restic round trip. `shutdown` waits for the
    /// captures handed over before it and drops any after.
    nonisolated func cacheListing(snapshotID: String, directory: String, nodes: [SnapshotNode], repositoryID: UUID) {
        cacheWrites.start { [self] in
            let captured = nodes.map(CachedListingNode.init)
            _ = await cacheAccess(repositoryID) {
                try await $0.recordListing(snapshotID: snapshotID, directory: directory, nodes: captured)
            }
        }
    }

    /// The cached diff between two snapshots, nil on miss or cache failure.
    nonisolated func cachedDiff(olderID: String, newerID: String, repositoryID: UUID) async -> [CachedDiffChange]? {
        await cacheAccess(repositoryID) { try await $0.diff(olderID: olderID, newerID: newerID) } ?? nil
    }

    /// Captures one diff for next time, and returns at once, as
    /// `cacheListing` does: the Change column's marks are in hand. Callers
    /// pass only complete walks — a partial stream must never present itself
    /// as the whole answer.
    nonisolated func cacheDiff(olderID: String, newerID: String, changes: [ResticDiffChange], repositoryID: UUID) {
        cacheWrites.start { [self] in
            let captured = changes.map(CachedDiffChange.init)
            _ = await cacheAccess(repositoryID) {
                try await $0.recordDiff(olderID: olderID, newerID: newerID, changes: captured)
            }
        }
    }

    /// One file's cached node in each of `snapshotIDs` that has one, by
    /// snapshot ID — empty on a miss, or when the cache itself failed.
    nonisolated func cachedFileNodes(path: String, snapshotIDs: [String], repositoryID: UUID) async -> [String: SnapshotNode] {
        let cached = await cacheAccess(repositoryID) { try await $0.fileNodes(path: path, snapshotIDs: snapshotIDs) }
        return (cached ?? [:]).mapValues(\.snapshotNode)
    }

    /// Captures files' nodes — by path, then by snapshot ID — for next time,
    /// and returns at once, as `cacheListing` does: the version rows have
    /// their sizes and dates in hand.
    nonisolated func cacheFileNodes(_ nodes: [String: [String: SnapshotNode]], repositoryID: UUID) {
        cacheWrites.start { [self] in
            let captured = nodes.mapValues { $0.mapValues(CachedListingNode.init) }
            _ = await cacheAccess(repositoryID) {
                try await $0.recordFileNodes(captured)
            }
        }
    }

    /// Returns once every capture handed over so far has been written or
    /// has failed — including any handed over while it waits. `shutdown`
    /// waits here; so do tests that read back what they just captured.
    nonisolated func cacheWritesSettled() async {
        await cacheWrites.settled()
    }

    /// `read` for the caches: best-effort, so a failure is nil, and a reset
    /// in progress is a miss rather than a wait.
    private nonisolated func cacheAccess<T: Sendable>(
        _ repositoryID: UUID,
        _ body: @Sendable (SnapshotIndex) async throws -> T
    ) async -> T? {
        guard let store = try? leaseUnlessClosing(repositoryID) else { return nil }
        defer { registry.release(repositoryID) }
        return try? await body(store)
    }

    // MARK: - Lifecycle

    /// Closes and deletes a repository's index — the index exists only to
    /// serve its repository, so removal takes it along. The repository joins
    /// the tombstone set first, so a refresh or a read that was in flight
    /// when the removal happened cannot recreate the file behind its back.
    /// UUIDs are never reused, so a tombstone never needs lifting.
    func dropRepository(repositoryID: UUID) async {
        await close(repositoryID, removing: true)
    }

    /// `dropRepository` without the tombstone: the recovery hatch a
    /// user-invoked rebuild drives. The repository still exists — only its
    /// index is being thrown away — so future reconciles must land.
    func resetRepository(repositoryID: UUID) async {
        await close(repositoryID, removing: false)
    }

    private func close(_ repositoryID: UUID, removing: Bool) async {
        let previous = closings[repositoryID]
        let turn = Task {
            await previous?.value
            await self.closeFile(repositoryID, removing: removing)
        }
        closings[repositoryID] = turn
        await turn.value
        if closings[repositoryID] == turn { closings[repositoryID] = nil }
    }

    /// The order is the point. The store leaves the registry first, behind a
    /// gate no read or write can open the file through. The backfill is
    /// cancelled and awaited: its task holds the store. Reads and writes
    /// still running on it finish. Only then does the pool close and the
    /// files — the `-wal` and `-shm` sidecars too — go: deleting a database
    /// under an open connection, or opening a fresh one where a stale `-wal`
    /// survives, are SQLite's documented corruption routes.
    private func closeFile(_ repositoryID: UUID, removing: Bool) async {
        let store = registry.beginClosing(repositoryID, removing: removing)
        backfillTasks[repositoryID]?.cancel()
        await backfillTasks[repositoryID]?.value
        await registry.drained(repositoryID)
        try? store?.close()
        Self.removeIndexFiles(at: fileURL(for: repositoryID))
        // No listing generation to forget: it lived on the store just
        // closed, and the fresh one takes the rebuild's re-sent listing
        // under the number it was read with.
        released.remove(repositoryID)
        readFailures[repositoryID] = nil
        reports[repositoryID] = nil
        registry.endClosing(repositoryID)
    }

    /// Cancels every backfill and waits for each to unwind — its restic
    /// child is terminated through the task's cancellation, and a write in
    /// progress commits or rolls back before the wait ends — then waits for
    /// the browse-cache captures already handed over. Later backfills are
    /// refused and later captures dropped: one offered while the app quits
    /// costs the next launch a restic round trip, never a write the exit
    /// cuts off. Quit calls this before it terminates the remaining restic
    /// processes, so a backfill sees its walk cancelled rather than failed
    /// and does not go on to spawn the next.
    func shutdown() async {
        isShutDown = true
        cacheWrites.close()
        let running = Array(backfillTasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
        await cacheWritesSettled()
    }

    // MARK: - Orphan files

    /// Deletes the index files of repositories the configuration does not
    /// name: a removal whose drop never ran (a crash, or a quit before the
    /// background lane drained), or a repository deleted from config.json by
    /// hand. Nothing else ever reclaims them — the tombstone lives in memory
    /// and dies with the process.
    ///
    /// Only `indexDirectory` is swept, and in it only `<UUID>.sqlite` and its
    /// `-wal` and `-shm` sidecars; any other name is left alone. The
    /// configuration folder's own `<uuid>.sqlite` files are never touched:
    /// removing them is the user's call.
    ///
    /// `configured` must come from a configuration that read whole: an empty
    /// or substituted list would make every live repository's index read as
    /// an orphan. A store open in this process is spared whatever the list
    /// says — it belongs to a repository something just used, and deleting
    /// an open database's files is one of SQLite's documented corruption
    /// routes. The check and the deletion run under the registry's lock,
    /// where every store is opened, so none can open in between.
    func sweepOrphanFiles(configured: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: indexDirectory.path) else { return }
        registry.whileHeld { isHeld in
            for name in names {
                guard let owner = Self.repositoryID(ofIndexFile: name),
                      !configured.contains(owner),
                      !isHeld(owner)
                else { continue }
                try? FileManager.default.removeItem(at: indexDirectory.appendingPathComponent(name))
            }
        }
    }

    /// The repository an index file belongs to, read from its name alone:
    /// `<UUID>.sqlite`, `<UUID>.sqlite-wal` or `<UUID>.sqlite-shm`. Anything
    /// else is not a file this coordinator wrote, so it has no owner here.
    private static func repositoryID(ofIndexFile name: String) -> UUID? {
        for suffix in fileSuffixes where name.hasSuffix(".sqlite" + suffix) {
            return UUID(uuidString: String(name.dropLast(".sqlite".count + suffix.count)))
        }
        return nil
    }

    // MARK: - Store access

    /// The repository's store, counted in flight until the caller hands it
    /// back with `registry.release`. A reset in progress is waited out: the
    /// caller parks until the gate reopens (`StoreRegistry.gateOpened`), then
    /// tries again — another reset may have closed the gate meanwhile, or a
    /// drop tombstoned the repository, which throws `repositoryRemoved`. A
    /// cancelled caller stops waiting at once and throws `CancellationError`.
    private nonisolated func lease(_ repositoryID: UUID) async throws -> SnapshotIndex {
        while true {
            if let store = try leaseUnlessClosing(repositoryID) { return store }
            try await registry.gateOpened(repositoryID)
        }
    }

    /// `lease` that answers nil instead of waiting out a reset: for the
    /// caches, and for a backfill, which a reset is itself waiting for.
    private nonisolated func leaseUnlessClosing(_ repositoryID: UUID) throws -> SnapshotIndex? {
        try registry.lease(repositoryID) { try self.openStore(repositoryID) }
    }

    /// Opens the repository's file, creating the folder and the schema on
    /// first use. A file that will not open — another schema, a corrupt
    /// file — is deleted with its sidecars and opened afresh: the index has a
    /// full rebuild path, so this is the fast recovery, not data loss. Runs
    /// only under the registry's lock, and only when no store of the
    /// repository is open or closing, so no other pool has the file open.
    private nonisolated func openStore(_ repositoryID: UUID) throws -> SnapshotIndex {
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let path = fileURL(for: repositoryID)
        do {
            return try SnapshotIndex(path: path.path)
        } catch {
            Self.removeIndexFiles(at: path)
            return try SnapshotIndex(path: path.path)
        }
    }

    /// What SQLite appends to a database's path for each of its files:
    /// nothing for the database itself, then its WAL and shared-memory
    /// sidecars.
    private static let fileSuffixes = ["", "-wal", "-shm"]

    /// Deletes a database's file with its `-wal` and `-shm` sidecars: the
    /// recovery `openStore` runs on a file that will not open, and what a
    /// reset or drop does once the pool is closed. Only ever on a path no
    /// pool has open — deleting under an open connection is one of SQLite's
    /// documented corruption routes. The store tests call it too — for the
    /// same recovery, and to clear a closed fixture's file — so the three
    /// names are spelled once.
    static func removeIndexFiles(at path: URL) {
        for suffix in fileSuffixes {
            try? FileManager.default.removeItem(atPath: path.path + suffix)
        }
    }
}

/// What one backfill pass did, route by route: how often a snapshot took the
/// population-sized full read where a delta would have cost only the change,
/// and why.
struct BackfillReport: Sendable, Equatable {
    /// Snapshots a full `restic ls` indexed, fallbacks included.
    var fulls = 0
    /// Snapshots a `restic diff` indexed.
    var deltas = 0
    /// Diffs abandoned on a `T` line.
    var typeChange = 0
    /// Diffs restic failed, or wrote lines of that did not decode.
    var diffFailed = 0
    /// Diffs the index refused for a kind change they did not spell out.
    var kindChanged = 0
    /// Full steps planned for a chain that already has a window: the
    /// window-end snapshot died, so a delta has no base.
    var deadWindowEnd = 0
    /// Full reads that failed; each target sits out the rest of its pass.
    var fullFailed = 0
    /// Steps the index turned down because the plan went stale mid-step.
    var refused = 0
    /// Snapshots set aside as unreadable.
    var markedUnreadable = 0

    mutating func count(_ reason: IndexCoordinator.DeltaFallback) {
        switch reason {
        case .typeChange: typeChange += 1
        case .diffFailed: diffFailed += 1
        case .kindChanged: kindChanged += 1
        }
    }
}

/// One pass's memory: what to skip, what was refused, and how many passes
/// each snapshot's full read has failed in.
private struct BackfillPass {
    var skip: Set<String> = []
    var refusedSteps: Set<IndexStep> = []
    var failures: [String: Int]
    var report = BackfillReport()

    init(failures: [String: Int]) {
        self.failures = failures
    }

    mutating func landed(_ target: String) {
        failures[target] = nil
    }

    /// The target sits out the rest of the pass, and the failure counts
    /// against it — once per pass, since a skipped snapshot is not planned
    /// again. True when this failure is the one that sets it aside.
    mutating func failed(_ target: String) -> Bool {
        skip.insert(target)
        report.fullFailed += 1
        let count = failures[target, default: 0] + 1
        guard count >= IndexCoordinator.unreadableAfter else {
            failures[target] = count
            return false
        }
        failures[target] = nil
        return true
    }

    /// Planned again once, then skipped: a step the index keeps refusing is
    /// not going to land this pass.
    mutating func refused(_ step: IndexStep, _ target: String) {
        report.refused += 1
        if !refusedSteps.insert(step).inserted { skip.insert(target) }
    }
}

extension IndexStep {
    /// The snapshot a step reads; nil for `.done`.
    fileprivate var target: String? {
        switch self {
        case let .full(snapshotID), let .delta(snapshotID, _): snapshotID
        case .done: nil
        }
    }
}

/// The coordinator's open stores, readable without the actor: the map, the
/// tombstones of removed repositories, the gate a reset or drop closes, and
/// how many callers are using each repository's store right now. Both waits
/// it serves park a continuation, never poll: a reset waiting for the
/// callers to drain, and a lease waiting for the gate to reopen.
///
/// Every store is opened here, under the lock, and only when none of the
/// repository is open or closing — so one file never has two pools, and a
/// reset can close the one it has once its count reaches zero. The count
/// is taken in the same critical section as the lookup; a lookup followed
/// by a separate increment would let a reset close the pool in between.
private final class StoreRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [UUID: SnapshotIndex] = [:]
    private var removed: Set<UUID> = []
    private var closing: Set<UUID> = []
    private var inFlight: [UUID: Int] = [:]
    private var drainWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Leases parked at a closed gate, by ticket, so a cancelled one can be
    /// found and resumed alone.
    private var gateWaiters: [UUID: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// The store, opened with `open` if need be, counted in flight; nil
    /// while a reset or drop holds the gate. Throws `repositoryRemoved` for
    /// a dropped repository, and whatever `open` throws.
    func lease(_ repositoryID: UUID, open: () throws -> SnapshotIndex) throws -> SnapshotIndex? {
        lock.lock()
        defer { lock.unlock() }
        guard !removed.contains(repositoryID) else { throw IndexError.repositoryRemoved }
        guard !closing.contains(repositoryID) else { return nil }
        let store = try stores[repositoryID] ?? open()
        stores[repositoryID] = store
        inFlight[repositoryID, default: 0] += 1
        return store
    }

    func release(_ repositoryID: UUID) {
        lock.lock()
        let remaining = (inFlight[repositoryID] ?? 1) - 1
        var waiters: [CheckedContinuation<Void, Never>] = []
        if remaining > 0 {
            inFlight[repositoryID] = remaining
        } else {
            inFlight[repositoryID] = nil
            waiters = drainWaiters.removeValue(forKey: repositoryID) ?? []
        }
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Takes the store out of the map and closes the gate; a drop also
    /// tombstones the repository, which the gate's lifting leaves in place.
    func beginClosing(_ repositoryID: UUID, removing: Bool) -> SnapshotIndex? {
        lock.lock()
        defer { lock.unlock() }
        if removing { removed.insert(repositoryID) }
        closing.insert(repositoryID)
        return stores.removeValue(forKey: repositoryID)
    }

    /// Reopens the gate and wakes the leases parked at it — outside the
    /// lock, as `release` wakes its waiters. Each tries its lease again.
    func endClosing(_ repositoryID: UUID) {
        lock.lock()
        closing.remove(repositoryID)
        let waiters = gateWaiters.removeValue(forKey: repositoryID)?.values.map { $0 } ?? []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once no caller is using the repository's store.
    func drained(_ repositoryID: UUID) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if !enqueueDrainWaiter(waiter, for: repositoryID) { waiter.resume() }
        }
    }

    private func enqueueDrainWaiter(_ waiter: CheckedContinuation<Void, Never>, for repositoryID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight[repositoryID] != nil else { return false }
        drainWaiters[repositoryID, default: []].append(waiter)
        return true
    }

    /// Returns once the repository's gate is open — at once if it already
    /// is — for the caller to try its lease again; `endClosing` wakes it. A
    /// cancelled caller is woken at once and throws `CancellationError`,
    /// however long the reset still runs.
    func gateOpened(_ repositoryID: UUID) async throws {
        let ticket = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if !enqueueGateWaiter(waiter, ticket, for: repositoryID) { waiter.resume() }
            }
        } onCancel: {
            cancelGateWaiter(ticket, for: repositoryID)
        }
        try Task.checkCancellation()
    }

    /// Parks `waiter` while the gate is closed and its task not cancelled;
    /// false when it must not wait. Cancellation is read under the lock,
    /// which closes the race with `cancelGateWaiter`: a cancellation that
    /// lands before this runs is seen here, and one after finds the waiter
    /// parked.
    private func enqueueGateWaiter(
        _ waiter: CheckedContinuation<Void, Never>,
        _ ticket: UUID,
        for repositoryID: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard closing.contains(repositoryID), !Task.isCancelled else { return false }
        gateWaiters[repositoryID, default: [:]][ticket] = waiter
        return true
    }

    /// Wakes one cancelled lease, if it is still parked; `endClosing` may
    /// have woken it already.
    private func cancelGateWaiter(_ ticket: UUID, for repositoryID: UUID) {
        lock.lock()
        let waiter = gateWaiters[repositoryID]?.removeValue(forKey: ticket)
        lock.unlock()
        waiter?.resume()
    }

    func isRemoved(_ repositoryID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return removed.contains(repositoryID)
    }

    /// Runs `body` under the lock with a test for "this repository's store
    /// is open, closing or in use", so a file-level decision cannot race a
    /// store opening.
    func whileHeld(_ body: ((UUID) -> Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body { self.stores[$0] != nil || self.closing.contains($0) || self.inFlight[$0] != nil }
    }
}

/// The browse-cache captures in flight: `cacheListing` and `cacheDiff` hand
/// a write over and return, and a quit still waits for it. Off the actor,
/// like `StoreRegistry`, so handing one over never waits on the actor
/// either. Each task removes its own entry when it ends; after `close`,
/// nothing new starts.
private final class CacheWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    /// Runs `body` in a task of its own, unless `close` came first.
    func start(_ body: @escaping @Sendable () async -> Void) {
        let ticket = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        // Created under the lock, so the task's own removal, which takes the
        // lock, cannot run before its entry exists.
        running[ticket] = Task {
            await body()
            self.finished(ticket)
        }
    }

    func close() {
        lock.lock()
        isClosed = true
        lock.unlock()
    }

    /// Returns once nothing is running — a loop, so a capture started while
    /// it waits is waited for too.
    func settled() async {
        while let task = anyRunning() { await task.value }
    }

    private func anyRunning() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return running.values.first
    }

    private func finished(_ ticket: UUID) {
        lock.lock()
        running[ticket] = nil
        lock.unlock()
    }
}

/// Why a restic stream was not taken as the whole answer, although restic
/// exited cleanly.
enum IncompleteStream: Error, Equatable {
    /// A `T` line: restic reports a change between file and directory as
    /// that one line and omits both subtrees, so the diff cannot say what
    /// the target holds below the path.
    case typeChange(path: String)
    /// A listing with no node at all. No real snapshot is empty — restic
    /// lists at least the folders it backed up — and applied, an empty
    /// listing would close every run of the chain.
    case emptyListing
}

/// Lock-guarded accumulation of one `restic diff`'s existence changes for
/// the delta route — the stream's callbacks run on the runner's reader
/// thread, not on the actor.
///
/// `+` is added and `-` removed, each kept as the entry the store takes
/// (`IndexedEntry(diffSpelling:)`: the path without restic's trailing `/`,
/// the kind that `/` marks). `M` — content changed, the only change restic
/// reports for a path in both snapshots without `--metadata`, which the
/// walk does not pass — is kept as modified, for the store's content
/// versions; so is `?`, which `ResticDiffChange` counts as modified too. `U`
/// changes only metadata and is ignored. A `T` line ends the delta
/// (`IncompleteStream.typeChange`): the snapshot must take the full route,
/// and the index's own `kindChanged` refusal backs that up for a kind change
/// that slips through spelled as an add. Nothing more is kept after a `T`;
/// the rest of the stream is read to its end and dropped.
final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [IndexedEntry] = []
    private var removed: [IndexedEntry] = []
    private var modified: [IndexedEntry] = []
    private var typeChange: String?

    func consume(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        guard typeChange == nil else { return }
        if change.modifier.contains("T") {
            typeChange = change.path
            return
        }
        switch change.category {
        case .added: added.append(IndexedEntry(diffSpelling: change.path))
        case .removed: removed.append(IndexedEntry(diffSpelling: change.path))
        case .modified: modified.append(IndexedEntry(diffSpelling: change.path))
        case .metadataOnly: break
        }
    }

    /// The delta to apply, or `IncompleteStream.typeChange` when a `T` line
    /// means there is none.
    func delta() throws -> (added: [IndexedEntry], removed: [IndexedEntry], modified: [IndexedEntry]) {
        lock.lock()
        defer { lock.unlock() }
        if let typeChange { throw IncompleteStream.typeChange(path: typeChange) }
        return (added, removed, modified)
    }
}

/// Accumulates streamed `ls` paths and hands them to the store in chunks.
///
/// Thread confinement by lock: the restic stream's callbacks arrive on one
/// background queue, while `finish` runs after the walk returns. The flush
/// call is synchronous and transaction-per-chunk, so chunks recorded before
/// a failure or cancellation stay staged — the snapshot remains pending and
/// the next pass streams it again from the top. Internal, not private: the
/// tests drive the failure paths through an injected flush.
///
/// The first chunk that fails to record stops the buffer for good: no later
/// chunk is flushed and the final marker is never sent. The snapshot cannot
/// be declared read after a lost chunk anyway, so every later chunk would be
/// a write spent on a stream already known incomplete — and a chunk may have
/// failed because the store's picture of this stream is wrong, which later
/// chunks would only build on. The next pass reads the snapshot again from
/// the top.
final class BackfillBuffer: @unchecked Sendable {
    private let flush: @Sendable ([IndexedEntry], Bool) throws -> Void
    private let chunkSize = SnapshotIndex.chunkSize
    private let lock = NSLock()
    private var pending: [IndexedEntry] = []
    private var receivedAny = false
    private var captured: Error?
    private var isCancelled = false

    /// - Parameter flush: records one chunk; with `final: true` the chunk is
    ///   the stream's last — possibly empty — and the call also applies the
    ///   whole stream, in that chunk's transaction, so it must only ever run
    ///   after every earlier chunk landed.
    init(flush: @escaping @Sendable ([IndexedEntry], Bool) throws -> Void) {
        self.flush = flush
    }

    func append(_ entry: IndexedEntry) {
        var chunk: [IndexedEntry]?
        lock.lock()
        receivedAny = true
        // After a failed chunk nothing more will be flushed, so nothing more
        // is kept: the rest of a million-path stream must not pile up here.
        if !isCancelled, captured == nil {
            pending.append(entry)
            if pending.count >= chunkSize {
                chunk = pending
                pending = []
            }
        }
        lock.unlock()
        if let chunk { flushChunk(chunk) }
    }

    /// Sends the remainder as the final chunk — what applies the stream and
    /// marks the snapshot read, in the remainder's own transaction (the
    /// store stages it and compares in one); without it the snapshot stays
    /// pending. A stream that ended on a chunk boundary sends an empty
    /// final. Any error captured mid-stream throws instead, and then
    /// nothing more reaches the store, the remainder included; an error
    /// from the final itself throws too — either way the snapshot stays
    /// pending for the next pass. A stream that delivered no entry at all
    /// throws `IncompleteStream.emptyListing` without sending the final:
    /// applied, an empty listing would read as a snapshot that holds
    /// nothing.
    func finish() throws {
        lock.lock()
        let remainder = pending
        pending = []
        let failed = captured
        let cancelled = isCancelled
        let empty = !receivedAny
        lock.unlock()
        if let failed { throw failed }
        // A buffer told to stop never declares coverage — the snapshot stays
        // pending and the unwinding walk above handles its own error.
        guard !cancelled else { return }
        guard !empty else { throw IncompleteStream.emptyListing }
        // The decisive call propagates directly rather than being captured:
        // a failure here is exactly what must surface.
        try flush(remainder, true)
    }

    /// Stops accepting paths — the walk above us is unwinding with an error
    /// or cancellation, and half-flushed state is exactly as far as the
    /// resumable design wants to go. The final marker is not exempt: a
    /// cancelled buffer never declares a snapshot fully read.
    func cancel() {
        lock.lock()
        isCancelled = true
        pending = []
        lock.unlock()
    }

    /// Records one non-final chunk; a failure is captured for `finish`.
    private func flushChunk(_ chunk: [IndexedEntry]) {
        lock.lock()
        let stopped = isCancelled || captured != nil
        lock.unlock()
        guard !stopped, !chunk.isEmpty else { return }
        do {
            try flush(chunk, false)
        } catch {
            lock.lock()
            if captured == nil { captured = error }
            lock.unlock()
        }
    }
}
