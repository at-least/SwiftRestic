import Foundation
import GRDB
import SQLite3
import Testing

// Shared scaffolding for the SnapshotIndex suites. Every index here is
// file-backed in its own temporary directory, so the tests run the
// production configuration — DatabasePool, WAL, the pragmas and the writer's
// TEMP tables — and never touch the user's Application Support folder.

/// One file-backed index in a fresh temporary directory, deleted with the
/// fixture. `reopen()` closes and opens the file again: the TEMP tables and
/// the stream session go, exactly as after a relaunch.
final class IndexFixture {
    let directory: URL
    let path: String
    private(set) var index: SnapshotIndex

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticSnapshotIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("index.sqlite").path
        index = try SnapshotIndex(path: path)
    }

    func reopen() throws {
        try index.close()
        index = try SnapshotIndex(path: path)
    }

    deinit {
        try? index.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Scaffolding for the coordinator tests that run without restic: a
/// temporary configuration folder (created here, deleted by `remove()`), a
/// coordinator on it, snapshots of two plans, and the scripted
/// `MockResticClient` standing in for `ls` and `diff`. Shared across the
/// test files — the coordinator suites, the browse-cache suite, and the
/// restic suite's drop and reset tests — several of which used to rebuild
/// the folder-and-coordinator part by hand. The folder exists from `init`
/// on, where a bare coordinator creates it only when its first store opens
/// (`openStore`); nothing reads the difference.
struct CoordinatorScene {
    let root: URL
    let coordinator: IndexCoordinator
    let repositoryID = UUID()
    let context = RepositoryContext(repository: Repository(), password: "x")

    init(_ label: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        coordinator = IndexCoordinator(directory: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A snapshot of plan A (or B) at `seconds` past the epoch.
    static func snapshot(_ id: String, _ seconds: Int64, plan: String = IndexTestData.planA) throws -> Snapshot {
        try IndexTestData.snapshot(id, micros: seconds * 1_000_000, tags: [plan])
    }

    /// `/data`, one file named after the snapshot, and one file every
    /// snapshot holds.
    static func content(_ id: String) -> [String: Bool] {
        ["/data": true, "/data/\(id).txt": false, "/data/common.txt": false]
    }

    func reconcile(_ listing: [Snapshot], _ generation: UInt64) async {
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: generation)
    }

    func backfill(_ client: MockResticClient) async {
        await coordinator.runBackfill(repositoryID: repositoryID, service: client, context: context)
    }

    func versions(_ path: String) async throws -> [String] {
        try await coordinator.versions(ofPath: path, repositoryID: repositoryID).map(\.id)
    }

    var report: BackfillReport? {
        get async { await coordinator.lastBackfillReport(repositoryID: repositoryID) }
    }

    var violations: [String] {
        get async throws { try await coordinator.read(repositoryID) { try $0.invariantViolations() } }
    }
}

/// A path's content in one snapshot: path -> isDirectory.
typealias IndexContent = [String: Bool]

extension Dictionary where Key == String {
    /// The same entries keyed by `PathKey`, the keyed reads' key — what a
    /// String-keyed truth is compared with. A String dictionary never holds
    /// two canonically equal keys, so the byte keys are unique too.
    var byPathKey: [PathKey: Value] {
        var keyed: [PathKey: Value] = [:]
        for (path, value) in self { keyed[PathKey(path)] = value }
        return keyed
    }
}

extension Sequence where Element == String {
    /// The paths as `PathKey`s, to compare with a keyed read's keys.
    var pathKeys: Set<PathKey> { Set(map { PathKey($0) }) }
}

/// Every node a `walkSnapshot` delivered: as path → isDirectory, the content
/// restic listed, and as `paths`, the order it streamed them. Collected
/// under a lock because the callback runs on the runner's reader thread.
/// The real-restic suite reads snapshots through it, the stub suite checks
/// what a short stream still delivered, and the scripted client's order is
/// pinned through it.
final class NodeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Bool] = [:]
    private var order: [String] = []

    func append(_ node: SnapshotNode) {
        lock.lock()
        storage[node.path] = node.isDirectory
        order.append(node.path)
        lock.unlock()
    }

    var content: [String: Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// The paths in the order the walk delivered them.
    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }
}

/// Holds every reader connection of an index's pool from outside, each on a
/// background thread, until `release()`: a read begun meanwhile waits for a
/// reader, which parks the caller inside that read for as long as the test
/// needs. `isHeld` turns true once every reader is taken.
final class ReaderHold: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = 0
    private var released = false
    private let count: Int

    init(_ index: SnapshotIndex) {
        count = index.pool.configuration.maximumReaderCount
        for _ in 0 ..< count {
            DispatchQueue.global().async {
                try? index.pool.read { _ in
                    self.take()
                    while !self.isReleased { usleep(2_000) }
                }
            }
        }
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return taken == count
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    private func take() {
        lock.lock()
        taken += 1
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
}

/// Holds an index's one writer connection from outside, on a background
/// thread, as a backfill's chunk or full compare holds it — for seconds at
/// scale — until `release()`. For the tests that show a caller does not
/// queue behind it.
final class WriterHold: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var released = false
    private var freed = false

    init(_ index: SnapshotIndex) {
        DispatchQueue.global().async {
            index.pool.writeWithoutTransaction { _ in
                self.mark(held: true)
                while !self.isReleased { usleep(2_000) }
            }
            self.markFreed()
        }
    }

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    /// True once the writer was handed back after `release`.
    var isFreed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return freed
    }

    private func markFreed() {
        lock.lock()
        freed = true
        lock.unlock()
    }

    private var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }

    private func mark(held value: Bool) {
        lock.lock()
        held = value
        lock.unlock()
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
}

enum IndexTestData {
    static let planA = "swiftrestic-plan-aaaa1111aaaa1111aaaa1111aaaa1111"
    static let planB = "swiftrestic-plan-bbbb2222bbbb2222bbbb2222bbbb2222"

    /// A restic snapshot as the model decodes it, through a JSON document so
    /// the model's own defaults apply.
    static func snapshot(
        _ id: String,
        micros: Int64,
        tags: [String] = [],
        hostname: String? = "mac",
        paths: [String] = ["/data"]
    ) throws -> Snapshot {
        var document: [String: Any] = [
            "id": id,
            "short_id": String(id.prefix(8)),
            "time": Double(micros) / 1_000_000,
            "paths": paths,
            "tags": tags,
        ]
        if let hostname { document["hostname"] = hostname }
        let data = try JSONSerialization.data(withJSONObject: document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(Snapshot.self, from: data)
    }

    /// A 64-hex snapshot ID that sorts by `n` (bytewise and numerically).
    static func hexID(_ n: Int) -> String {
        let digits = String(n, radix: 16)
        return String(repeating: "0", count: 64 - digits.count) + digits
    }

    /// A path as `restic diff` spells it: a directory ends in `/`. The one
    /// writer of that spelling in the test scaffolding — `diff(from:to:)`,
    /// the scripted client's `walkDiff` and the scale model's deltas go
    /// through it; a test that pins a particular spelling writes it
    /// inline. The
    /// app only ever reads it (`ResticDiffChange.isDirectory` and
    /// `IndexedEntry(diffSpelling:)`, both through `ResticPath`), so the
    /// writing side lives with the tests;
    /// `DeltaCollectorTests.diffSpellingRoundTrips` pins the two together.
    static func diffSpelling(_ path: String, isDirectory: Bool) -> String {
        isDirectory ? path + "/" : path
    }

    /// A browse-cache row as `restic ls` reported the node. The cache keeps
    /// no name — `CachedListingNode.snapshotNode` re-derives it from the
    /// path — so the name here is only what the node carried on the wire.
    static func cachedNode(
        _ path: String, kind: SnapshotNode.Kind = .file, size: Int64? = 1, mtime: Date? = nil
    ) -> CachedListingNode {
        CachedListingNode(SnapshotNode(name: ResticPath.basename(of: path), type: kind, path: path, size: size, mtime: mtime))
    }

    /// The listing `restic ls` would stream: depth-first, siblings in byte
    /// order, with every ancestor directory present. Each path is split into
    /// its components once, not on every comparison: the scripted client
    /// streams its listings through here too, some of them 30 000 paths
    /// long, and a debug build pays for every split.
    static func ls(_ content: IndexContent) -> [IndexedEntry] {
        content.keys
            .map { (path: $0, components: SnapshotIndex.components($0)) }
            .sorted { a, b in
                a.components.lexicographicallyPrecedes(b.components) { SnapshotIndex.bytesLess($0, $1) }
            }
            .map { IndexedEntry(path: $0.path, isDirectory: content[$0.path] ?? false) }
    }

    /// A complete set-difference diff in restic's spelling (directories end
    /// in `/`): a kind change appears in both lists.
    static func diff(from base: IndexContent, to target: IndexContent) -> (added: [String], removed: [String]) {
        var added: [String] = []
        var removed: [String] = []
        for (path, isDirectory) in target {
            if let was = base[path] {
                if was != isDirectory {
                    added.append(diffSpelling(path, isDirectory: isDirectory))
                    removed.append(diffSpelling(path, isDirectory: was))
                }
            } else {
                added.append(diffSpelling(path, isDirectory: isDirectory))
            }
        }
        for (path, was) in base where target[path] == nil { removed.append(diffSpelling(path, isDirectory: was)) }
        return (added.sorted(by: SnapshotIndex.bytesLess), removed.sorted(by: SnapshotIndex.bytesLess))
    }

    /// The planner loop both `runToDone`s drive: to `.done` or `maxSteps`,
    /// each full step as one chunk through `full`, each delta as a complete
    /// diff through `delta`, falling back to `full` when that throws.
    /// Returns the trace.
    static func runPlanner(
        _ contents: [String: IndexContent], maxSteps: Int,
        next: () throws -> IndexStep,
        full: (_ id: String, _ entries: [IndexedEntry]) throws -> Void,
        delta: (_ id: String, _ base: String, _ added: [String], _ removed: [String]) throws -> Void
    ) throws -> [String] {
        var trace: [String] = []
        for _ in 0 ..< maxSteps {
            switch try next() {
            case .done:
                return trace
            case .full(let id):
                trace.append("full(\(id))")
                try full(id, ls(contents[id] ?? [:]))
            case .delta(let id, let base):
                trace.append("delta(\(id)<-\(base))")
                let (added, removed) = diff(from: contents[base] ?? [:], to: contents[id] ?? [:])
                do {
                    try delta(id, base, added, removed)
                } catch {
                    trace.append("deltaThrew")
                    try full(id, ls(contents[id] ?? [:]))
                }
            }
        }
        trace.append("STEP-CAP")
        return trace
    }
}

extension SnapshotIndex {
    /// One whole full read: `beginFull`, then the listing in one final chunk.
    func ingestWhole(_ snapshotID: String, _ entries: [IndexedEntry]) throws {
        try beginFull(snapshotID: snapshotID)
        try ingestFull(snapshotID: snapshotID, entries: entries, final: true)
    }

    /// `ingestDelta` fed paths as `restic diff` spells them — a directory
    /// with its trailing `/` — each converted as `DeltaCollector` converts
    /// it (`IndexedEntry(diffSpelling:)`), so a test writes what restic
    /// writes.
    func ingestDiff(snapshotID: String, from base: String, added: [String], removed: [String]) throws {
        try ingestDelta(
            snapshotID: snapshotID, from: base,
            added: added.map(IndexedEntry.init(diffSpelling:)),
            removed: removed.map(IndexedEntry.init(diffSpelling:))
        )
    }

    /// Runs the planner to `.done`, feeding each step from `contents`: a
    /// delta as a complete diff (falling back to the full route if it is
    /// refused), a full step as one chunk. Returns the trace.
    @discardableResult
    func runToDone(_ contents: [String: IndexContent], maxSteps: Int = 100) throws -> [String] {
        try IndexTestData.runPlanner(
            contents, maxSteps: maxSteps,
            next: { try nextStep() },
            full: { try ingestWhole($0, $1) },
            delta: { try ingestDiff(snapshotID: $0, from: $1, added: $2, removed: $3) }
        )
    }

    /// The stored-state violations that must be absent at this point.
    /// (a)–(c) are established by housekeeping, so they are checked only
    /// right after it; `excusing` names letters the caller knows to be
    /// legitimately broken (risk 8's crash leftovers are (i)).
    func violations(afterHousekeeping: Bool, excusing: Set<Character> = []) throws -> [String] {
        try invariantViolations().filter { line in
            guard line.count > 1 else { return true }
            let letter = line[line.index(after: line.startIndex)]
            if !afterHousekeeping, "abc".contains(letter) { return false }
            return !excusing.contains(letter)
        }
    }

    /// The IDs holding `path`, newest first — what most assertions compare.
    func versionIDs(_ path: String) async throws -> [String] {
        try await versions(ofPath: path).map(\.id)
    }

    /// Every listed snapshot's state by ID (`State.pending`, `.indexed`,
    /// `.unreadable`); a snapshot the listing dropped has no row, so no
    /// entry — what reconcile wrote, for the tests that check it.
    func snapStates() throws -> [String: Int64] {
        try pool.read { db in
            var states: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT hash, state FROM snap") {
                states[row["hash"]] = row["state"]
            }
            return states
        }
    }

    /// Whether the open stream holds a cached walk. Read on the writer,
    /// where `session` lives (a closure that cannot throw, so neither does
    /// this).
    func streamHoldsWalk() -> Bool {
        pool.writeWithoutTransaction { _ in session?.walk != nil }
    }

    /// The paths of the nodes check (i) counts — no run, no child, no stage
    /// row — for a caller that must excuse some of them by name rather than
    /// the whole check. On the writer, where the stage lives.
    func strandedPaths() throws -> Set<String> {
        try pool.write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT n.id " + SnapshotIndex.strandedNodes)
            var paths: [Int64: String] = [:]
            return Set(try ids.map { try SnapshotIndex.path(db, of: $0, memo: &paths) })
        }
    }

    /// The virtual-machine work the writer connection does inside `body`,
    /// counted by SQLite's progress handler at one-instruction granularity:
    /// a statement that visits n rows counts at least n. A measure of cost
    /// that does not depend on the machine, for asserting that a write's
    /// work does not grow with rows it has no business reading. Only
    /// statements `body` runs on the writer count; reads on pool readers do
    /// not.
    func writerWork(_ body: () throws -> Void) throws -> Int {
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.initialize(to: 0)
        defer { counter.deallocate() }
        try pool.writeWithoutTransaction { db in
            sqlite3_progress_handler(db.sqliteConnection, 1, { context in
                context?.assumingMemoryBound(to: Int.self).pointee += 1
                return 0
            }, UnsafeMutableRawPointer(counter))
        }
        defer { try? pool.writeWithoutTransaction { db in sqlite3_progress_handler(db.sqliteConnection, 0, nil, nil) } }
        try body()
        return counter.pointee
    }
}

/// What the writer connection has written so far, in two units that do not
/// depend on the machine: rows changed by completed statements
/// (`sqlite3_total_changes64` through GRDB, which counts TEMP tables and the
/// rows FTS5 writes into its own shadow tables too), and bytes appended to
/// the `-wal` — pages the pager wrote out (`SQLITE_DBSTATUS_CACHE_WRITE`),
/// each one frame of a page plus its 24-byte header. Both are cumulative per
/// connection, so a reopen starts them over: the difference of two reads on
/// one connection is what the writes between them cost.
struct WriteCounters: Equatable {
    var rows: Int
    var walBytes: Int

    static func - (a: WriteCounters, b: WriteCounters) -> WriteCounters {
        WriteCounters(rows: a.rows - b.rows, walBytes: a.walBytes - b.walBytes)
    }
}

extension SnapshotIndex {
    /// The writer's counters now (see `WriteCounters`). Every write of the
    /// index runs on the writer, so these see all of them; reads never
    /// write.
    func writeCounters() throws -> WriteCounters {
        try pool.writeWithoutTransaction { db in
            var pages: Int32 = 0
            var highwater: Int32 = 0
            let status = sqlite3_db_status(db.sqliteConnection, SQLITE_DBSTATUS_CACHE_WRITE, &pages, &highwater, 0)
            guard status == SQLITE_OK else {
                throw DatabaseError(message: "sqlite3_db_status(CACHE_WRITE) returned \(status)")
            }
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096
            return WriteCounters(rows: db.totalChangesCount, walBytes: Int(pages) * (pageSize + 24))
        }
    }

    /// What `body`'s writes cost, by `writeCounters()` before and after.
    func cost(of body: () throws -> Void) throws -> WriteCounters {
        let before = try writeCounters()
        try body()
        return try writeCounters() - before
    }
}

/// A fixture's index whose every write is followed by
/// `invariantViolations()`: (d)–(k) after each write, whether it succeeded
/// or threw, and (a)–(c) too right after housekeeping. A violation becomes a
/// test issue at the caller's line. The scripted suites write through this,
/// except where a test's point is a write it cannot make: a numbered
/// reconcile, a file prepared for the schema check, a stage planted to fail
/// check (j).
final class CheckedIndex {
    let fixture: IndexFixture
    /// Letters known to be legitimately broken from here on (risk 8: a
    /// reopen during a stream leaves (i) behind for good).
    var excusing: Set<Character> = []

    init() throws {
        fixture = try IndexFixture()
    }

    var index: SnapshotIndex { fixture.index }
    var path: String { fixture.path }

    private func checked<T>(
        _ operation: String,
        afterHousekeeping: Bool = false,
        _ sourceLocation: SourceLocation,
        _ body: () throws -> T
    ) throws -> T {
        defer {
            do {
                let found = try index.violations(afterHousekeeping: afterHousekeeping, excusing: excusing)
                if !found.isEmpty { Issue.record("after \(operation): \(found)", sourceLocation: sourceLocation) }
            } catch {
                Issue.record("the invariant check threw after \(operation): \(error)", sourceLocation: sourceLocation)
            }
        }
        return try body()
    }

    /// What the reconcile wrote, measured around the store's call alone.
    @discardableResult
    func reconcile(_ listing: [Snapshot], sourceLocation: SourceLocation = #_sourceLocation) throws -> WriteCounters {
        try checked("reconcile", sourceLocation) { try index.cost { try index.reconcile(listing: listing) } }
    }

    func housekeeping(sourceLocation: SourceLocation = #_sourceLocation) throws {
        try checked("housekeeping", afterHousekeeping: true, sourceLocation) { try index.housekeeping() }
    }

    func releaseUnreadable(sourceLocation: SourceLocation = #_sourceLocation) throws {
        try checked("releaseUnreadable", sourceLocation) { _ = try index.releaseUnreadable() }
    }

    func markUnreadable(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try checked("markUnreadable(\(id))", sourceLocation) { try index.markUnreadable(snapshotID: id) }
    }

    func beginFull(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try checked("beginFull(\(id))", sourceLocation) { try index.beginFull(snapshotID: id) }
    }

    func chunk(_ id: String, _ entries: [IndexedEntry], final: Bool, sourceLocation: SourceLocation = #_sourceLocation) throws {
        try checked("ingestFull(\(id), final: \(final))", sourceLocation) {
            try index.ingestFull(snapshotID: id, entries: entries, final: final)
        }
    }

    func full(_ id: String, _ entries: [IndexedEntry], sourceLocation: SourceLocation = #_sourceLocation) throws {
        try beginFull(id, sourceLocation: sourceLocation)
        try chunk(id, entries, final: true, sourceLocation: sourceLocation)
    }

    func delta(
        _ id: String, from base: String, added: [String], removed: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try checked("ingestDelta(\(id) <- \(base))", sourceLocation) {
            try index.ingestDiff(snapshotID: id, from: base, added: added, removed: removed)
        }
    }

    func reopen() throws {
        try fixture.reopen()
    }

    /// `SnapshotIndex.runToDone`, every write checked.
    @discardableResult
    func runToDone(
        _ contents: [String: IndexContent], maxSteps: Int = 100,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> [String] {
        try IndexTestData.runPlanner(
            contents, maxSteps: maxSteps,
            next: { try index.nextStep() },
            full: { try full($0, $1, sourceLocation: sourceLocation) },
            delta: { try delta($0, from: $1, added: $2, removed: $3, sourceLocation: sourceLocation) }
        )
    }
}

/// An `ls` entry, for scripts that spell their streams by hand.
func entry(_ path: String, _ isDirectory: Bool = false) -> IndexedEntry {
    IndexedEntry(path: path, isDirectory: isDirectory)
}
