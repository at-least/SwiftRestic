import Foundation

/// Owns one snapshot index per repository and keeps it current: reconcile on
/// every snapshot refresh, a backfill that reads what the index has not read
/// yet, and (once a repository is removed) the file's disposal.
///
/// The index is a cache with a rebuild path — the repository is the truth —
/// so nothing here may turn a good refresh or backup into an app-level
/// failure. A write that fails is dropped, and the app degrades to what it
/// did before the index existed: restic `ls` per browse.
///
/// Three kinds of work, three homes:
/// - Reads are `nonisolated`. They take the store from `StoreRegistry` and
///   run on the pool's readers, so a search never queues behind a backfill
///   or another repository's reconcile.
/// - Writes are synchronous store calls made through `offActor`. GRDB's one
///   writer connection serialises them; a multi-second full compare holds
///   that writer, never this actor.
/// - The actor keeps the bookkeeping: listing generations, the backfill
///   tasks, the per-pass skip sets and failure counts, and the order of the
///   steps that close a file.
actor IndexCoordinator {
    /// The configuration's folder, which the index lives inside (see
    /// `indexDirectory`).
    let directory: URL
    /// Where the `<repository>.sqlite` files live: a folder of their own
    /// inside the configuration's, so the orphan sweep can own everything in
    /// it. The configuration folder's own `<uuid>.sqlite` files are the
    /// index's earlier home; nothing here opens, sweeps or deletes them.
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
    /// succeeded, so the repository was reachable, and no rule can tell a
    /// bad snapshot from a bad connection in a pass with nothing else to
    /// read — a repository's only chain, blocked by its own forward
    /// candidate, is exactly that pass, every time. Counting only failures
    /// in passes where other work landed left such a snapshot blocking
    /// every later backup for good. The cost of a wrong guess is one
    /// snapshot left out until the next launch releases it. The number
    /// itself is a guess: nobody has measured how real repositories fail.
    static let unreadableAfter = 2

    /// The open stores, with the tombstones and in-flight counts that let
    /// the reads skip this actor.
    private let registry = StoreRegistry()
    private var backfillTasks: [UUID: Task<Void, Never>] = [:]
    /// The generation of the newest listing applied per repository. The
    /// model numbers a listing before it asks restic for it, so the numbers
    /// follow the order the repository was read in — which the reconciles
    /// themselves need not: each reaches this actor through its own
    /// unstructured hop, and two hops promise no order.
    private var appliedGenerations: [UUID: UInt64] = [:]
    /// The latest reconcile per repository; the next one waits for it. The
    /// store write runs off the actor, so without this queue two reconciles
    /// could pass the generation check in order and reach the writer in the
    /// other — an older listing applied last.
    private var reconcileTails: [UUID: Task<Void, Never>] = [:]
    /// Repositories whose unreadable snapshots this process has already
    /// released — once per launch, before the first reconcile.
    private var released: Set<UUID> = []
    /// Per repository and snapshot: the passes in which its full read
    /// failed. In memory only, like the release: a fresh launch starts every
    /// snapshot's count over.
    private var readFailures: [UUID: [String: Int]] = [:]
    private var reports: [UUID: BackfillReport] = [:]
    /// The latest reset or drop per repository; the next one waits for it,
    /// so two never delete files under each other's pool.
    private var closings: [UUID: Task<Void, Never>] = [:]
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
    /// A listing whose `generation` is not newer than the last one applied
    /// is dropped unread: it was fetched before a listing that already
    /// landed, and applying it would record as dead every snapshot that
    /// newer listing brought in — a backup's own snapshot, taken between the
    /// two reads, among them. The number is taken even when the store then
    /// fails: an older listing is no better a retry than the next refresh.
    func reconcile(repositoryID: UUID, snapshots: [Snapshot], generation: UInt64) async {
        let previous = reconcileTails[repositoryID]
        let turn = Task {
            await previous?.value
            await self.apply(snapshots, generation: generation, repositoryID: repositoryID)
        }
        reconcileTails[repositoryID] = turn
        await turn.value
        if reconcileTails[repositoryID] == turn { reconcileTails[repositoryID] = nil }
    }

    private func apply(_ listing: [Snapshot], generation: UInt64, repositoryID: UUID) async {
        // The store first: a reset in progress holds the gate, and the
        // number below must be checked against what the fresh file applied,
        // not against what the reset is about to forget.
        guard let store = try? await lease(repositoryID) else { return }
        defer { registry.release(repositoryID) }
        if let applied = appliedGenerations[repositoryID], generation <= applied { return }
        appliedGenerations[repositoryID] = generation
        do {
            if !released.contains(repositoryID) {
                let retried = try await Self.offActor { try store.releaseUnreadable() }
                released.insert(repositoryID)
                // Each of these failed `unreadableAfter` passes in an earlier
                // launch, and the release puts it above its chain's window —
                // the forward candidate, ahead of every new backup. Still
                // unreadable, it must not block them for another count from
                // zero: one more failure sets it aside again.
                for snapshotID in retried {
                    readFailures[repositoryID, default: [:]][snapshotID] = Self.unreadableAfter - 1
                }
            }
            try await Self.offActor {
                try store.reconcile(listing: listing)
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

    /// One backfill pass: the index plans each step (`nextStep`), and this
    /// loop runs it — a delta through `restic diff` when the window-end
    /// snapshot is alive, else a full `restic ls` streamed in chunks — until
    /// nothing is left or the pass is cancelled. Tests await this directly;
    /// production goes through `startBackfill`.
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
            guard let step = try? store.nextStep(skipping: pass.skip) else { break }
            let end: StepEnd
            switch step {
            case .done:
                break steps
            case let .delta(target, base):
                let delta = await readDelta(target, from: base, into: store, service: service, context: context)
                guard case let .fallBack(reason) = delta else {
                    if case .landed = delta { pass.report.deltas += 1 }
                    end = delta
                    break
                }
                pass.report.count(reason)
                end = await readFull(target, into: store, service: service, context: context)
                if case .landed = end { pass.report.fulls += 1 }
            case let .full(target):
                if (try? store.chainHasWindow(of: target)) == true { pass.report.deadWindowEnd += 1 }
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
            case .stopped, .fallBack:
                break steps
            }
        }
        readFailures[repositoryID] = pass.failures
        reports[repositoryID] = pass.report
    }

    /// What the last finished backfill pass of the repository did, route by
    /// route. The app has no log to write it to; it waits here for a future
    /// surface, and the tests read it to see which route a step took.
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
        /// Delta route only: the diff cannot build the target, the full
        /// route must.
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
    ) async -> StepEnd {
        let collector = DeltaCollector()
        do {
            let malformed = try await service.walkDiff(context, olderID: base, newerID: target) { change in
                collector.consume(change)
            }
            let delta = try collector.delta(malformedLines: malformed)
            try await Self.offActor {
                try store.ingestDelta(snapshotID: target, from: base, added: delta.added, removed: delta.removed)
            }
            return .landed
        } catch {
            if Self.isCancellation(error) { return .stopped }
            switch error {
            case IncompleteStream.typeChange: return .fallBack(.typeChange)
            case IndexError.kindChanged: return .fallBack(.kindChanged)
            default: return Self.isRefusal(error) ? .refused : .fallBack(.diffFailed)
            }
        }
    }

    /// The full route: `beginFull`, the `restic ls` stream flushed in chunks
    /// as it arrives (on the runner's reader thread, never this actor), then
    /// the final chunk and the compare. A stream with lines that did not
    /// decode, or with no node at all, never reaches the final: applied, it
    /// would close the runs of every path it failed to mention.
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
            let malformed = try await service.walkSnapshot(context, snapshotID: target) { node in
                buffer.append(IndexedEntry(path: node.path, isDirectory: node.isDirectory))
            }
            guard malformed == 0 else { throw IncompleteStream.malformedLines(malformed) }
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
    /// route nor count against the snapshot.
    private static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        if case ResticError.cancelled = error { return true }
        return false
    }

    /// The index's refusals of a stale plan: the snapshot died or returned,
    /// was set aside, or the window moved between planning and writing. The
    /// next plan knows better, so the step is planned again.
    private static func isRefusal(_ error: Error) -> Bool {
        switch error as? IndexError {
        case .unknownSnapshot, .notAdjacent, .wrongBase, .unreadable,
             .streamIdentityChanged, .poisonedStream, .noSession:
            true
        default:
            false
        }
    }

    /// Runs a synchronous store write on the global executor, so the actor
    /// stays free for the steps of other repositories and for reset, drop
    /// and shutdown while GRDB's writer works.
    private static func offActor<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }

    // MARK: - Reads

    /// The indexed snapshots holding one path, newest first. The folder
    /// browser's core question.
    nonisolated func versions(ofPath path: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await read(repositoryID) { try await $0.versions(ofPath: path) }
    }

    /// `versions(ofPath:)` within one chain — a plan's tag — in SQL.
    nonisolated func versions(ofPath path: String, inChain chainKey: String, repositoryID: UUID) async throws -> [IndexVersion] {
        try await read(repositoryID) { try await $0.versions(ofPath: path, inChain: chainKey) }
    }

    /// Per path: how many indexed snapshots hold it, and the newest.
    nonisolated func versionSummaries(ofPaths paths: [String], repositoryID: UUID) async throws -> [PathKey: VersionSummary] {
        try await read(repositoryID) { try await $0.versionSummaries(ofPaths: paths) }
    }

    /// Which of `paths` one snapshot holds, each with its kind there.
    nonisolated func contains(paths: [String], inSnapshot snapshotID: String, repositoryID: UUID) async throws -> [PathKey: Bool] {
        try await read(repositoryID) { try await $0.contains(paths: paths, inSnapshot: snapshotID) }
    }

    /// Basename search across every indexed path — instant, no restic walk.
    nonisolated func searchPaths(matching query: String, repositoryID: UUID, limit: Int) async throws -> [SearchHit] {
        try await read(repositoryID) { try await $0.searchPaths(matching: query, limit: limit) }
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
    /// Internal, not private: the tests hold a read open across a reset.
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

    /// Captures one directory's listing for next time. Best-effort: a failed
    /// write costs only the next visit's restic round trip.
    nonisolated func cacheListing(snapshotID: String, directory: String, nodes: [SnapshotNode], repositoryID: UUID) async {
        let captured = nodes.map(CachedListingNode.init)
        _ = await cacheAccess(repositoryID) {
            try $0.recordListing(snapshotID: snapshotID, directory: directory, nodes: captured)
        }
    }

    /// The cached diff between two snapshots, nil on miss or cache failure.
    nonisolated func cachedDiff(olderID: String, newerID: String, repositoryID: UUID) async -> [CachedDiffChange]? {
        await cacheAccess(repositoryID) { try await $0.diff(olderID: olderID, newerID: newerID) } ?? nil
    }

    /// Captures one diff for next time. Callers pass only complete walks —
    /// a partial stream must never present itself as the whole answer.
    nonisolated func cacheDiff(olderID: String, newerID: String, changes: [ResticDiffChange], repositoryID: UUID) async {
        let captured = changes.map(CachedDiffChange.init)
        _ = await cacheAccess(repositoryID) {
            try $0.recordDiff(olderID: olderID, newerID: newerID, changes: captured)
        }
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
        // The rebuild re-sends the listing the model holds, under the
        // generation it was read with — the one already applied here. The
        // fresh file has applied nothing, so it must take that listing.
        appliedGenerations[repositoryID] = nil
        released.remove(repositoryID)
        readFailures[repositoryID] = nil
        reports[repositoryID] = nil
        registry.endClosing(repositoryID)
    }

    /// Cancels every backfill and waits for each to unwind — its restic
    /// child is terminated through the task's cancellation, and a write in
    /// progress commits or rolls back before the wait ends. Later backfills
    /// are refused. Quit calls this before it terminates the remaining
    /// restic processes, so a backfill sees its walk cancelled rather than
    /// failed and does not go on to spawn the next.
    func shutdown() async {
        isShutDown = true
        let running = Array(backfillTasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
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
    /// configuration folder's own `<uuid>.sqlite` files, the index's earlier
    /// home, are never touched: removing them is the user's call.
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
        for suffix in [".sqlite", ".sqlite-wal", ".sqlite-shm"] where name.hasSuffix(suffix) {
            return UUID(uuidString: String(name.dropLast(suffix.count)))
        }
        return nil
    }

    // MARK: - Store access

    /// The repository's store, counted in flight until the caller hands it
    /// back with `registry.release`. A reset in progress is waited out, a
    /// short poll at a time; a cancelled caller stops waiting.
    private nonisolated func lease(_ repositoryID: UUID) async throws -> SnapshotIndex {
        while true {
            if let store = try leaseUnlessClosing(repositoryID) { return store }
            try await Task.sleep(for: .milliseconds(10))
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

    private static func removeIndexFiles(at path: URL) {
        for suffix in ["", "-wal", "-shm"] {
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
/// how many callers are using each repository's store right now.
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

    func endClosing(_ repositoryID: UUID) {
        lock.lock()
        closing.remove(repositoryID)
        lock.unlock()
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

/// Why a restic stream was not taken as the whole answer, although restic
/// exited cleanly.
enum IncompleteStream: Error, Equatable {
    /// A `T` line: restic reports a change between file and directory as
    /// that one line and omits both subtrees, so the diff cannot say what
    /// the target holds below the path.
    case typeChange(path: String)
    /// Lines restic wrote that did not decode: the listing or diff received
    /// is not the one restic meant.
    case malformedLines(Int)
    /// A listing with no node at all. No real snapshot is empty — restic
    /// lists at least the folders it backed up — and applied, an empty
    /// listing would close every run of the chain.
    case emptyListing
}

/// Lock-guarded accumulation of one `restic diff`'s existence changes for
/// the delta route — the stream's callbacks run on the runner's reader
/// thread, not on the actor.
///
/// `+` is added and `-` removed, both in restic's spelling (a trailing `/`
/// marks a directory). `M` and `U` change content or metadata, not
/// existence, and are ignored. A `T` line ends the delta (`IncompleteStream
/// .typeChange`): the snapshot must take the full route, and the index's own
/// `kindChanged` refusal backs that up for a kind change that slips through
/// spelled as an add. Nothing more is kept after a `T`; the rest of the
/// stream is read to its end and dropped.
final class DeltaCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var added: [String] = []
    private var removed: [String] = []
    private var typeChange: String?

    func consume(_ change: ResticDiffChange) {
        lock.lock()
        defer { lock.unlock() }
        guard typeChange == nil else { return }
        if change.modifier.contains("T") {
            typeChange = change.path
            added = []
            removed = []
        } else if change.modifier.contains("+") {
            added.append(change.path)
        } else if change.modifier.contains("-") {
            removed.append(change.path)
        }
    }

    /// The delta to apply, or why there is none: a `T` line, or
    /// `malformedLines` restic wrote that did not decode — a change the
    /// decoder dropped is one the delta would silently miss.
    func delta(malformedLines: Int) throws -> (added: [String], removed: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if let typeChange { throw IncompleteStream.typeChange(path: typeChange) }
        guard malformedLines == 0 else { throw IncompleteStream.malformedLines(malformedLines) }
        return (added, removed)
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
    private var received = 0
    private var captured: Error?
    private var isCancelled = false

    /// - Parameter flush: records one chunk; `final: true` applies the whole
    ///   stream and must only ever run after every chunk landed.
    init(flush: @escaping @Sendable ([IndexedEntry], Bool) throws -> Void) {
        self.flush = flush
    }

    func append(_ entry: IndexedEntry) {
        var chunk: [IndexedEntry]?
        lock.lock()
        received += 1
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
        if let chunk { flushChunk(chunk, false) }
    }

    /// Flushes the remainder with the final marker — what applies the
    /// stream and marks the snapshot read; without it the snapshot stays
    /// pending. Any error captured mid-stream — and any error from the final
    /// itself — throws, leaving the snapshot pending for the next pass, and
    /// after a captured error nothing more reaches the store. A stream that
    /// delivered no entry at all throws `IncompleteStream.emptyListing`
    /// without sending the final: applied, an empty listing would read as a
    /// snapshot that holds nothing.
    func finish() throws {
        lock.lock()
        let remainder = pending
        pending = []
        lock.unlock()
        flushChunk(remainder, false)
        lock.lock()
        let failed = captured
        let cancelled = isCancelled
        let empty = received == 0
        lock.unlock()
        if let failed { throw failed }
        // A buffer told to stop never declares coverage — the snapshot stays
        // pending and the unwinding walk above handles its own error.
        guard !cancelled else { return }
        guard !empty else { throw IncompleteStream.emptyListing }
        // The decisive call propagates directly rather than being captured:
        // a failure here is exactly what must surface.
        try flush([], true)
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

    private func flushChunk(_ chunk: [IndexedEntry], _ final: Bool) {
        lock.lock()
        let stopped = isCancelled || captured != nil
        lock.unlock()
        guard !stopped, final || !chunk.isEmpty else { return }
        do {
            try flush(chunk, final)
        } catch {
            lock.lock()
            if captured == nil { captured = error }
            lock.unlock()
        }
    }
}
