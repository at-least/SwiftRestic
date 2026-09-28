import Foundation
import GRDB
import Testing

/// The scale gates (FINAL.md 5.4): at a snapshot count well past what the
/// unit tests reach, every write the index makes must cost its own change,
/// never the population's. A regression there fails no answer — it only
/// makes each backup slower as the history grows — so these tests assert
/// cost directly, in units that do not depend on the machine: rows changed
/// and bytes appended to the `-wal`, read from the writer's own counters
/// (`WriteCounters`). Wall time is only printed, and only under the bench
/// flag below.
///
/// FINAL.md states its bounds per write; here each applies to the mean over
/// a phase's writes instead — a deviation, because FTS5 merges its segments
/// incrementally, so a write that happens to cross a merge threshold pays a
/// burst (measured while calibrating: 14 of 200 five-add, five-remove deltas
/// changed 63–73 rows instead of 31, and the largest wrote 37 pages where
/// its own bound allowed 36). A mean alone would hide one population-sized
/// write among many cheap ones, so every write's rows also stay under a
/// ceiling of a fifth of a chain's paths — far above any burst, far below a
/// rewrite of the chain. The WAL has no such ceiling yet: at the default
/// shape a merge burst writes about as much as the whole population does.
///
/// The default shape keeps `./build.sh test` quick: three plan chains over
/// disjoint folders of one home, about 20k paths, 600 hourly history ticks
/// with restic-style retention (keep the last 100 ticks and every second
/// older one, a different half per chain), so 1,800 snapshots are read and
/// about 1,050 stay, with an interior seq gap at every thinned tick. Pass
/// `SWIFTRESTIC_INDEX_BENCH=1` to the test process — through xcodebuild,
/// `TEST_RUNNER_SWIFTRESTIC_INDEX_BENCH=1`, which it forwards with the prefix
/// stripped — for the target shape nobody measured before: 2M paths in five
/// chains and about 10k retained snapshots (18,500 read). The bench asserts
/// the same bounds and prints the timings (means): per backup, housekeeping,
/// a one-letter search, the summaries against full version lists, the
/// planner and `isComplete` as the indexed count grows, and four rare
/// events — a head death, a failed diff, a mass omission and its recovery,
/// and a whole chain's death.
@Suite("snapshot index scale")
struct SnapshotIndexScaleTests {
    @Test("the write counters see what a write costs, and a population-sized write breaks the bounds")
    func countersMeasureWrites() throws {
        let fixture = try IndexFixture()
        let index = fixture.index
        var content: IndexContent = ["/p": true]
        for d in 0 ..< 20 {
            content["/p/d\(d)"] = true
            for f in 0 ..< 100 { content["/p/d\(d)/f\(f).txt"] = false }
        }
        let first = try IndexTestData.snapshot(IndexTestData.hexID(1), micros: 1_000_000, tags: [IndexTestData.planA])
        _ = try index.reconcile(listing: [first])
        try index.ingestWhole(first.id, IndexTestData.ls(content))

        // 500 new paths in one delta, measured against a WAL truncated just
        // before it: the counted bytes must be exactly the frames the file
        // grew by, after its 32-byte header.
        var grown = content
        for f in 0 ..< 500 { grown["/p/d\(f % 20)/new\(f).txt"] = false }
        let second = try IndexTestData.snapshot(IndexTestData.hexID(2), micros: 2_000_000, tags: [IndexTestData.planA])
        _ = try index.reconcile(listing: [first, second])
        let truncated = try index.pool.writeWithoutTransaction { db in
            try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        #expect(truncated?[0] as Int? == 0, "the checkpoint was blocked: \(String(describing: truncated))")
        let (added, removed) = IndexTestData.diff(from: content, to: grown)
        let big = try index.cost {
            try index.ingestDelta(snapshotID: second.id, from: first.id, added: added, removed: removed)
        }
        let walFile = try FileManager.default.attributesOfItem(atPath: fixture.path + "-wal")[.size] as? Int ?? -1
        print("SCALE counters: 500 new paths changed \(big.rows) rows and appended \(big.walBytes) WAL bytes; -wal is \(walFile) bytes")
        #expect(walFile == big.walBytes + 32)
        // Each new path is at least its node and its run.
        #expect(big.rows >= 2 * 500)
        // The negative control: the bounds the scale test applies, taken
        // for a one-and-one delta, must fail on this one. (Not ten and ten:
        // new nodes append densely, so 500 of them wrote only 38 pages,
        // under the 224 KiB a ten-and-ten delta may write.)
        #expect(Double(big.rows) > ScaleBounds.rows(added: 1, removed: 1))
        #expect(Double(big.walBytes) > ScaleBounds.wal(added: 1, removed: 1))

        // A delta that changes nothing still moves the window and the
        // snapshot's state: the counter must see those two rows.
        let third = try IndexTestData.snapshot(IndexTestData.hexID(3), micros: 3_000_000, tags: [IndexTestData.planA])
        _ = try index.reconcile(listing: [first, second, third])
        let nothing = try index.cost { try index.ingestDelta(snapshotID: third.id, from: second.id, added: [], removed: []) }
        #expect(nothing.rows > 0 && nothing.rows <= ScaleBounds.zeroChangeRows)
    }

    @Test("writes stay change-sized, and answers exact, at a high snapshot count")
    func changeSizedAtScale() async throws {
        let run = try ScaleRun(shape: .current)
        try await run.run()
    }
}

// MARK: - Bounds

/// The machine-independent bounds, per write; the tests compare means.
///
/// Rows: an added path costs at most four rows — its node, the two rows
/// FTS5 writes for the node's name (the virtual table's own and its
/// `docsize` shadow row), and its run — and a removed path one, the close of
/// its run. Calibrated on the production configuration: 500 new paths
/// changed 2,007 rows (the first test prints it), ten re-added known paths
/// plus ten removed 22, a zero-change delta 2. The constant is per write:
/// 16 for the window, the snapshot's state and the transaction's FTS segment
/// flush, and 16 for FTS5's incremental merges, which every write that adds
/// names pays for in bursts. That share grows with the number of names (more
/// merge levels): above the per-path accounting, deltas averaged 9 rows at
/// 30k names and 14 at 2.7M (the bench's 18,495 reverse deltas: 221.0 rows
/// for 41.5 added and 40.9 removed). FINAL.md 5.4 wrote `4·k + 16` for k
/// added and k removed, an estimate from a run whose diffs were mostly
/// content changes; existence changes of new paths cost `5·k` plus the
/// constant.
///
/// WAL: FINAL.md's `k × 16 KiB + 64 KiB`, with k the larger side: four
/// pages per added-and-removed pair — a removal dirties its run's leaf, an
/// addition its node's `(parent, name)` leaf, the rest land on pages the
/// transaction shares — plus sixteen for the pages every write touches.
///
/// Housekeeping after a death: every path only the dead snapshot held
/// appears twice in its two neighbours' churn (added into it, removed after
/// it) and costs its run, its node and the node's two FTS rows, plus a GC
/// scratch row: four rows per churn entry covers it, and eight the queue
/// row and the flush.
enum ScaleBounds {
    static func rows(added: Int, removed: Int) -> Double {
        Double(4 * added + removed + 32)
    }

    static func wal(added: Int, removed: Int) -> Double {
        Double(max(added, removed) * 16 * 1_024 + 64 * 1_024)
    }

    static func housekeepingRows(churn: Int) -> Double {
        Double(4 * churn + 8)
    }

    /// FINAL.md 5.4 S-2; a zero-change delta writes the window and the state.
    static let zeroChangeRows = 4

    /// A full read into a populated chain commits one transaction per
    /// chunk, and each chunk that creates nodes pays what a delta's constant
    /// pays for its names — the FTS segment flush and the merge share, 4 and
    /// 16 rows above — plus the node table's tail page: a delta's accounting
    /// plus, per such chunk, 20 rows and eight pages. Measured at 2M paths
    /// before these terms existed: the head deaths of the bench's first run
    /// wrote 1,487 KiB with 39 of 100 chunks carrying adds, where the delta
    /// bound alone allowed 1,056 KiB — about six pages per such chunk — and
    /// the second run's full reads changed 519.5 durable rows for 48.0
    /// added, 42.5 removed and 34.5 such chunks, about eight rows each.
    /// Still change-sized: every such chunk carries at least one added path.
    static func fullRows(added: Int, removed: Int, chunksWithAdds: Int) -> Double {
        rows(added: added, removed: removed) + Double(20 * chunksWithAdds)
    }

    static func fullWAL(added: Int, removed: Int, chunksWithAdds: Int) -> Double {
        wal(added: added, removed: removed) + Double(chunksWithAdds * 32 * 1_024)
    }
}

// MARK: - Shape

struct ScaleShape: Sendable {
    var chains: Int
    var pathsPerChain: Int
    var historyTicks: Int
    /// Retention keeps the newest `keepRecent` ticks and every second older
    /// one (a different half per chain).
    var keepRecent: Int
    var forwardTicks: Int
    /// Files added and files removed per chain and tick, each drawn from this.
    var churn: ClosedRange<Int>
    /// Rounds of S-6, each a head death and a failed diff in every chain:
    /// enough full reads that the mean absorbs an FTS merge burst.
    var fullRouteRounds: Int
    var bench: Bool

    static let standard = ScaleShape(
        chains: 3, pathsPerChain: 6_667, historyTicks: 600, keepRecent: 100, forwardTicks: 20, churn: 2 ... 8,
        fullRouteRounds: 4, bench: false)
    static let benchmark = ScaleShape(
        chains: 5, pathsPerChain: 400_000, historyTicks: 3_700, keepRecent: 300, forwardTicks: 200, churn: 20 ... 60,
        fullRouteRounds: 1, bench: true)

    static var current: ScaleShape {
        ProcessInfo.processInfo.environment["SWIFTRESTIC_INDEX_BENCH"] == "1" ? benchmark : standard
    }

    /// Ticks the model generates: the history, the forward backups, and the
    /// two backups of each full-route round.
    var totalTicks: Int { historyTicks + forwardTicks + 2 * fullRouteRounds }
    /// A forward tick with no change in any chain (S-2).
    var quietTick: Int { historyTicks + 3 }
}

// MARK: - The model

/// One chain's history as node lifetimes, so any tick's content, and the
/// difference between any two ticks, comes from the events in between —
/// never from a materialised listing per snapshot, which the bench shape
/// could not hold.
private final class ChainModel {
    static let never = Int32.max
    static let words = ["inv", "rep", "img", "doc", "memo", "scan", "plan", "note", "tax", "song", "clip", "deck"]
    static let extensions = ["pdf", "jpg", "txt", "png", "mp3", "csv", "key", "zip", "doc", "mov"]
    static let folders = ["Documents", "Pictures", "Projects", "Music", "Desktop"]

    let index: Int
    let tag: String
    let root: String
    /// Node 0 is the chain's root folder; the ancestors above it are listed
    /// but never change.
    var name: [String] = []
    var parent: [Int32] = []
    var isDir: [Bool] = []
    var born: [Int32] = []
    var died: [Int32] = []
    var children: [[Int32]] = []
    var addedAt: [[Int32]]
    var removedAt: [[Int32]]
    private var serial = 0

    init(index: Int, shape: ScaleShape, generator: inout SeededGenerator) {
        self.index = index
        tag = ResticService.planTagPrefix + String(format: "%08x-0000-4000-8000-%012x", index + 1, index + 1)
        root = "/Users/alice/" + Self.folders[index % Self.folders.count] + (index < Self.folders.count ? "" : "\(index)")
        addedAt = Array(repeating: [], count: shape.totalTicks)
        removedAt = Array(repeating: [], count: shape.totalTicks)
        build(shape, &generator)
    }

    var nodeCount: Int { name.count }

    func alive(_ node: Int32, at tick: Int) -> Bool {
        born[Int(node)] <= tick && tick < died[Int(node)]
    }

    private func nextName(_ generator: inout SeededGenerator, directory: Bool) -> String {
        serial += 1
        let word = Self.words[Int(generator.next() % UInt64(Self.words.count))]
        if directory { return word.capitalized + "-" + String(serial, radix: 36) }
        let ext = Self.extensions[Int(generator.next() % UInt64(Self.extensions.count))]
        return word + "-" + String(serial, radix: 36) + "." + ext
    }

    @discardableResult
    private func add(_ nodeName: String, under parentNode: Int32, directory: Bool, tick: Int) -> Int32 {
        let node = Int32(name.count)
        name.append(nodeName)
        parent.append(parentNode)
        isDir.append(directory)
        born.append(Int32(tick))
        died.append(Self.never)
        children.append([])
        if parentNode >= 0 { children[Int(parentNode)].append(node) }
        if tick > 0 { addedAt[tick].append(node) }
        return node
    }

    private func kill(_ node: Int32, tick: Int) {
        died[Int(node)] = Int32(tick)
        removedAt[tick].append(node)
    }

    /// The whole timeline, seeded: an initial tree of folders of 32 files,
    /// then per tick some removals and additions of files, now and then a
    /// new folder or a removed one, and three files every fifth tick that
    /// live for exactly one tick (what a middle snapshot's death leaves for
    /// housekeeping). The quiet tick changes nothing.
    private func build(_ shape: ScaleShape, _ generator: inout SeededGenerator) {
        add(root, under: -1, directory: true, tick: 0)
        let leafCount = max(1, shape.pathsPerChain / 33)
        let topCount = max(1, Int(Double(leafCount).squareRoot()))
        var aliveFiles: [Int32] = []
        var slot: [Int32: Int] = [:]
        var leaves: [Int32] = []
        var tops: [Int32] = []
        for _ in 0 ..< topCount { tops.append(add(nextName(&generator, directory: true), under: 0, directory: true, tick: 0)) }
        for l in 0 ..< leafCount {
            let leaf = add(nextName(&generator, directory: true), under: tops[l % topCount], directory: true, tick: 0)
            leaves.append(leaf)
            for _ in 0 ..< 32 {
                let file = add(nextName(&generator, directory: false), under: leaf, directory: false, tick: 0)
                slot[file] = aliveFiles.count
                aliveFiles.append(file)
            }
        }
        func dropFile(_ file: Int32) {
            guard let at = slot.removeValue(forKey: file) else { return }
            let last = aliveFiles.removeLast()
            if last != file {
                aliveFiles[at] = last
                slot[last] = at
            }
        }
        func pick(_ count: Int) -> Int { Int(generator.next() % UInt64(max(1, count))) }

        for tick in 1 ..< shape.totalTicks where tick != shape.quietTick {
            let span = UInt64(shape.churn.count)
            let removals = shape.churn.lowerBound + Int(generator.next() % span)
            for _ in 0 ..< removals where !aliveFiles.isEmpty {
                let file = aliveFiles[pick(aliveFiles.count)]
                dropFile(file)
                kill(file, tick: tick)
            }
            if tick % 40 == 0, leaves.count > 4 {
                let at = pick(leaves.count)
                let leaf = leaves.remove(at: at)
                for child in children[Int(leaf)] where died[Int(child)] == Self.never {
                    dropFile(child)
                    kill(child, tick: tick)
                }
                kill(leaf, tick: tick)
            }
            let additions = shape.churn.lowerBound + Int(generator.next() % span)
            for _ in 0 ..< additions {
                let file = add(nextName(&generator, directory: false), under: leaves[pick(leaves.count)], directory: false, tick: tick)
                slot[file] = aliveFiles.count
                aliveFiles.append(file)
            }
            if tick % 25 == 0 {
                let leaf = add(nextName(&generator, directory: true), under: tops[pick(tops.count)], directory: true, tick: tick)
                leaves.append(leaf)
                for _ in 0 ..< 8 {
                    let file = add(nextName(&generator, directory: false), under: leaf, directory: false, tick: tick)
                    slot[file] = aliveFiles.count
                    aliveFiles.append(file)
                }
            }
            if tick % 5 == 0, tick + 1 < shape.totalTicks, tick + 1 != shape.quietTick {
                for _ in 0 ..< 3 {
                    let file = add(nextName(&generator, directory: false), under: leaves[pick(leaves.count)], directory: false, tick: tick)
                    kill(file, tick: tick + 1)
                }
            }
        }
    }

    func path(of node: Int32) -> String {
        var names: [String] = []
        var current = node
        while current > 0 {
            names.append(name[Int(current)])
            current = parent[Int(current)]
        }
        return ([root] + names.reversed()).joined(separator: "/")
    }

    /// restic's spelling in a diff: a directory ends in `/`.
    func spelled(_ node: Int32) -> String {
        isDir[Int(node)] ? path(of: node) + "/" : path(of: node)
    }

    /// What `restic diff` from `base` to `target` would list, either
    /// direction.
    func delta(from base: Int, to target: Int) -> (added: [String], removed: [String]) {
        var added: [String] = []
        var removed: [String] = []
        guard base != target else { return ([], []) }
        var seen = Set<Int32>()
        for tick in (min(base, target) + 1) ... max(base, target) {
            for node in addedAt[tick] + removedAt[tick] where seen.insert(node).inserted {
                let inTarget = alive(node, at: target)
                let inBase = alive(node, at: base)
                if inTarget, !inBase { added.append(spelled(node)) }
                if inBase, !inTarget { removed.append(spelled(node)) }
            }
        }
        return (added, removed)
    }

    /// The listing `restic ls` streams for this chain at `tick`: the fixed
    /// ancestors, then the tree depth-first with siblings in byte order,
    /// handed over in chunks as `BackfillBuffer` flushes them.
    func streamListing(at tick: Int, chunk: Int, _ body: ([IndexedEntry], Bool) throws -> Void) throws {
        var pending: [IndexedEntry] = []
        func emit(_ entry: IndexedEntry) throws {
            pending.append(entry)
            if pending.count == chunk {
                try body(pending, false)
                pending.removeAll(keepingCapacity: true)
            }
        }
        var prefix = ""
        for component in SnapshotIndex.components(root).dropLast() {
            prefix += "/" + component
            try emit(IndexedEntry(path: prefix, isDirectory: true))
        }
        var stack: [(node: Int32, path: String)] = [(0, root)]
        while let (node, path) = stack.popLast() {
            try emit(IndexedEntry(path: path, isDirectory: isDir[Int(node)]))
            let kids = children[Int(node)]
                .filter { alive($0, at: tick) }
                .sorted { SnapshotIndex.bytesLess(name[Int($0)], name[Int($1)]) }
            for kid in kids.reversed() { stack.append((kid, path + "/" + name[Int(kid)])) }
        }
        try body(pending, true)
    }

    /// Nodes alive at every tick of the model: the steady part of the tree.
    func permanentFiles() -> [Int32] {
        (0 ..< Int32(nodeCount)).filter { !isDir[Int($0)] && born[Int($0)] == 0 && died[Int($0)] == Self.never }
    }
}

// MARK: - One run

private struct StepRecord {
    var chain: Int
    var added: Int
    var removed: Int
    var cost: WriteCounters
    /// Entries streamed (full route only): each is one TEMP stage row in and
    /// one out, which the row counter sees too.
    var streamed: Int
    /// Chunks of a full read that carried an added path: each creates nodes
    /// in its own transaction, so each flushes its own FTS segment.
    var chunksWithAdds = 0
    var seconds: Double
    /// The final chunk's transaction alone (full route only): where the
    /// staged listing is compared with the runs at the window end.
    var finalSeconds = 0.0

    /// Rows outside the TEMP stage: the part of a full read that must stay
    /// change-sized.
    var durableRows: Int { cost.rows - 2 * streamed }
}

private final class ScaleRun {
    let shape: ScaleShape
    let fixture: IndexFixture
    var chains: [ChainModel] = []
    /// Per chain, the ticks the latest listing holds.
    var listed: [Set<Int>]
    /// Per chain, the newest tick ever indexed forward: the window end whose
    /// content the TOP runs describe, even after it died.
    var hiTick: [Int]
    var snapshots: [String: (chain: Int, tick: Int)] = [:]
    var ingests = 0
    var readSamples: Set<Int> = [1_000, 3_000]

    var index: SnapshotIndex { fixture.index }

    init(shape: ScaleShape) throws {
        self.shape = shape
        fixture = try IndexFixture()
        listed = Array(repeating: [], count: shape.chains)
        hiTick = Array(repeating: -1, count: shape.chains)
    }

    // MARK: Helpers

    func id(chain: Int, tick: Int) -> String {
        IndexTestData.hexID(chain * 10_000_000 + tick + 1)
    }

    func micros(chain: Int, tick: Int) -> Int64 {
        1_700_000_000_000_000 + Int64(tick) * 3_600_000_000 + Int64(chain) * 60_000_000
    }

    var snapshotCache: [String: Snapshot] = [:]

    func listing() throws -> [Snapshot] {
        var out: [Snapshot] = []
        for chain in chains {
            for tick in listed[chain.index] {
                let hash = id(chain: chain.index, tick: tick)
                if let cached = snapshotCache[hash] {
                    out.append(cached)
                    continue
                }
                let snapshot = try IndexTestData.snapshot(
                    hash, micros: micros(chain: chain.index, tick: tick), tags: [chain.tag], paths: [chain.root])
                snapshotCache[hash] = snapshot
                snapshots[hash] = (chain.index, tick)
                out.append(snapshot)
            }
        }
        return out
    }

    func retain(now: Int) {
        for c in 0 ..< shape.chains {
            listed[c] = listed[c].filter { now - $0 < shape.keepRecent || ($0 + c) % 2 == 0 }
        }
    }

    @discardableResult
    func reconcile() throws -> ReconcileOutcome {
        try index.reconcile(listing: listing())
    }

    func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = Date()
        try body()
        return Date().timeIntervalSince(start)
    }

    func bench(_ line: String) {
        if shape.bench { print("BENCH " + line) }
    }

    func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    func ms(_ s: Double) -> String { String(format: "%.2f ms", s * 1_000) }
    func kib(_ bytes: Double) -> String { String(format: "%.1f KiB", bytes / 1_024) }

    func violations(afterHousekeeping: Bool, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var found: [String] = []
        let s = try seconds { found = try index.violations(afterHousekeeping: afterHousekeeping) }
        bench("invariant checks \(label): \(ms(s))")
        #expect(found.isEmpty, "\(label): \(found)", sourceLocation: sourceLocation)
    }

    // MARK: Steps

    /// Streams one full read the way the backfill does and measures it.
    func full(_ hash: String, chain: Int, tick: Int, churnFrom base: Int?) throws -> StepRecord {
        let churn: (added: [String], removed: [String]) = base.map { chains[chain].delta(from: $0, to: tick) } ?? ([], [])
        let addedPaths = Set(churn.added.map(SnapshotIndex.canonical))
        var streamed = 0
        var chunksWithAdds = 0
        var finalSeconds = 0.0
        var cost = WriteCounters(rows: 0, walBytes: 0)
        let s = try seconds {
            cost = try index.cost {
                try index.beginFull(snapshotID: hash)
                try chains[chain].streamListing(at: tick, chunk: SnapshotIndex.chunkSize) { entries, final in
                    streamed += entries.count
                    if !addedPaths.isEmpty, entries.contains(where: { addedPaths.contains($0.path) }) { chunksWithAdds += 1 }
                    let chunkSeconds = try seconds {
                        try index.ingestFull(snapshotID: hash, entries: entries, final: final)
                    }
                    if final { finalSeconds = chunkSeconds }
                }
            }
        }
        return StepRecord(
            chain: chain, added: churn.added.count, removed: churn.removed.count, cost: cost, streamed: streamed,
            chunksWithAdds: chunksWithAdds, seconds: s, finalSeconds: finalSeconds)
    }

    func delta(_ hash: String, from base: String, chain: Int, tick: Int, baseTick: Int) throws -> StepRecord {
        let (added, removed) = chains[chain].delta(from: baseTick, to: tick)
        var cost = WriteCounters(rows: 0, walBytes: 0)
        let s = try seconds {
            cost = try index.cost { try index.ingestDelta(snapshotID: hash, from: base, added: added, removed: removed) }
        }
        return StepRecord(chain: chain, added: added.count, removed: removed.count, cost: cost, streamed: 0, seconds: s)
    }

    struct Phase {
        var fulls: [StepRecord] = []
        var windowedFulls: [StepRecord] = []
        var forward: [StepRecord] = []
        var reverse: [StepRecord] = []
        var fullIDs: [String] = []
        var steps: Int { fulls.count + forward.count + reverse.count }
    }

    /// Runs the planner to `.done`, feeding each step from the model.
    /// `failDiffs` answers every offered delta as a failed `restic diff`
    /// would: through the full route instead.
    func drive(failDiffs: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Phase {
        var phase = Phase()
        let cap = snapshots.count * 2 + 100
        for _ in 0 ..< cap {
            let step = try index.nextStep()
            switch step {
            case .done:
                return phase
            case .full(let hash):
                guard let target = snapshots[hash] else { throw DatabaseError(message: "unknown \(hash)") }
                let (chain, tick) = target
                let windowed = try index.chainHasWindow(of: hash)
                let record = try full(hash, chain: chain, tick: tick, churnFrom: windowed ? hiTick[chain] : nil)
                phase.fulls.append(record)
                phase.fullIDs.append(hash)
                if windowed { phase.windowedFulls.append(record) }
                hiTick[chain] = max(hiTick[chain], tick)
            case .delta(let hash, let base):
                guard let target = snapshots[hash], let from = snapshots[base] else {
                    throw DatabaseError(message: "unknown \(hash) or \(base)")
                }
                let (chain, tick, baseTick) = (target.chain, target.tick, from.tick)
                if failDiffs {
                    let record = try full(hash, chain: chain, tick: tick, churnFrom: baseTick)
                    phase.fulls.append(record)
                    phase.windowedFulls.append(record)
                    phase.fullIDs.append(hash)
                } else {
                    let record = try delta(hash, from: base, chain: chain, tick: tick, baseTick: baseTick)
                    if tick < baseTick { phase.reverse.append(record) } else { phase.forward.append(record) }
                }
                if tick > baseTick { hiTick[chain] = max(hiTick[chain], tick) }
            }
            ingests += 1
            if readSamples.contains(ingests) { try await sampleReads("at \(ingests) indexed") }
        }
        Issue.record("the planner did not reach .done in \(cap) steps", sourceLocation: sourceLocation)
        return phase
    }

    /// S-7 under the bench flag: the planner and `isComplete` at this
    /// indexed count. Their plans have no snapshot-count term (the plan
    /// pins); these times show whether the constant is small.
    func sampleReads(_ label: String) async throws {
        guard shape.bench else { return }
        let label = label + " (\(snapshots.count) snapshots ever listed, \(listed.map(\.count).reduce(0, +)) listed now)"
        let rounds = 50
        let planner = try seconds { for _ in 0 ..< rounds { _ = try index.nextStep() } } / Double(rounds)
        let start = Date()
        for _ in 0 ..< rounds { _ = try await index.isComplete() }
        let complete = Date().timeIntervalSince(start) / Double(rounds)
        bench("S-7 \(label): nextStep \(ms(planner)), isComplete \(ms(complete)) (means of \(rounds))")
    }

    /// Compares the phase's mean cost with the mean of its per-write bounds.
    func expectChangeSized(
        _ label: String, _ records: [StepRecord], rows: (StepRecord) -> Int = { $0.cost.rows },
        rowBound bound: (StepRecord) -> Double = { ScaleBounds.rows(added: $0.added, removed: $0.removed) },
        walBound walFor: (StepRecord) -> Double = { ScaleBounds.wal(added: $0.added, removed: $0.removed) },
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard !records.isEmpty else {
            Issue.record("\(label): no writes were measured", sourceLocation: sourceLocation)
            return
        }
        let n = Double(records.count)
        let meanRows = Double(records.map(rows).reduce(0, +)) / n
        let rowBound = records.map(bound).reduce(0, +) / n
        let meanWAL = Double(records.map(\.cost.walBytes).reduce(0, +)) / n
        let walBound = records.map(walFor).reduce(0, +) / n
        let meanAdded = Double(records.map(\.added).reduce(0, +)) / n
        let meanRemoved = Double(records.map(\.removed).reduce(0, +)) / n
        print("SCALE \(label): n=\(records.count) mean added=\(String(format: "%.1f", meanAdded)) "
            + "removed=\(String(format: "%.1f", meanRemoved)) rows=\(String(format: "%.1f", meanRows)) "
            + "(bound \(String(format: "%.1f", rowBound)), max \(records.map(rows).max() ?? 0)) "
            + "WAL=\(kib(meanWAL)) (bound \(kib(walBound)), max \(kib(Double(records.map(\.cost.walBytes).max() ?? 0))))")
        #expect(meanRows <= rowBound, "\(label): rows", sourceLocation: sourceLocation)
        // A mean hides one population-sized write among many; no single
        // write may change a fifth of a chain's paths.
        let worst = records.map(rows).max() ?? 0
        let ceiling = Double(shape.pathsPerChain) / 5
        #expect(
            Double(worst) <= ceiling,
            "\(label): one write changed \(worst) rows; ceiling \(ceiling)",
            sourceLocation: sourceLocation
        )
        #expect(meanWAL <= walBound, "\(label): WAL", sourceLocation: sourceLocation)
        bench("\(label): mean \(ms(mean(records.map(\.seconds)))) per write, max \(ms(records.map(\.seconds).max() ?? 0))")
    }

    // MARK: Truth

    /// Every read of a sample of paths against the model: the versions of
    /// each path are the listed snapshots of its chain whose tick holds it,
    /// newest first.
    func expectExact(_ label: String, sample: Int = 60, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var generator = SeededGenerator(seed: UInt64(ingests) &+ 11)
        var mismatches: [String] = []
        for _ in 0 ..< sample {
            let chain = chains[Int(generator.next() % UInt64(chains.count))]
            let node = Int32(generator.next() % UInt64(chain.nodeCount))
            let path = chain.path(of: node)
            let truth = listed[chain.index].filter { chain.alive(node, at: $0) }.sorted(by: >)
                .map { id(chain: chain.index, tick: $0) }
            let got = try await index.versions(ofPath: path).map(\.id)
            if got != truth { mismatches.append("\(path): got \(got.count) versions, want \(truth.count)") }
        }
        print("SCALE exact \(label): \(sample - mismatches.count) of \(sample) sampled paths match the model")
        #expect(mismatches.isEmpty, "\(label): \(mismatches.prefix(5))", sourceLocation: sourceLocation)
        #expect(try await index.isComplete(), "\(label)", sourceLocation: sourceLocation)
    }

    // MARK: The run

    func run() async throws {
        var generator = SeededGenerator(seed: 20_260_928)
        let built = seconds {
            chains = (0 ..< shape.chains).map { ChainModel(index: $0, shape: shape, generator: &generator) }
        }
        let paths = chains.map(\.nodeCount).reduce(0, +)
        print("SCALE shape: \(shape.chains) chains, \(paths) paths in the model, "
            + "\(shape.historyTicks) history ticks, keep \(shape.keepRecent) recent")
        bench("model built in \(String(format: "%.1f", built)) s")

        // History: every tick of every chain listed at once; each chain's
        // newest is read in full, then reverse deltas down to its first.
        for c in 0 ..< shape.chains { listed[c] = Set(0 ..< shape.historyTicks) }
        let listedAtOnce = listed.map(\.count).reduce(0, +)
        let historyStart = Date()
        try reconcile()
        let history = try await drive()
        let historySeconds = Date().timeIntervalSince(historyStart)
        print("SCALE history: \(listedAtOnce) snapshots, \(history.fulls.count) full reads, "
            + "\(history.reverse.count) reverse deltas, \(history.forward.count) forward")
        bench("history: \(String(format: "%.1f", historySeconds)) s in all; full reads "
            + history.fulls.map { ms($0.seconds) + " for \($0.streamed) entries" }.joined(separator: ", "))
        #expect(history.fulls.count == shape.chains)
        #expect(history.reverse.count == listedAtOnce - shape.chains)
        #expect(history.forward.isEmpty)
        // S-3: a reverse delta is change-sized.
        expectChangeSized("S-3 reverse deltas", history.reverse)
        try await sampleReads("after the history, \(listedAtOnce) indexed")

        // Retention thins the older ticks: interior seq gaps everywhere.
        retain(now: shape.historyTicks - 1)
        try reconcile()
        let firstSweep = try index.cost { try index.housekeeping() }
        let retained = listed.map(\.count).reduce(0, +)
        print("SCALE retention: \(retained) of \(listedAtOnce) snapshots kept; housekeeping changed "
            + "\(firstSweep.rows) rows, \(kib(Double(firstSweep.walBytes)))")
        try violations(afterHousekeeping: true, "after retention")
        try await sampleReads("after retention")

        // Forward backups, one per chain and tick, each followed by the
        // same retention, as the app's own retention and refresh do.
        var forward: [StepRecord] = []
        var quiet: [StepRecord] = []
        var housekeepingCosts: [WriteCounters] = []
        var housekeepingSeconds: [Double] = []
        var tickSeconds: [Double] = []
        var tickWAL: [Double] = []
        for i in 0 ..< shape.forwardTicks {
            let tick = shape.historyTicks + i
            let start = Date()
            let before = try index.writeCounters()
            for c in 0 ..< shape.chains { listed[c].insert(tick) }
            retain(now: tick)
            try reconcile()
            var sweep = WriteCounters(rows: 0, walBytes: 0)
            housekeepingSeconds.append(try seconds { sweep = try index.cost { try index.housekeeping() } })
            housekeepingCosts.append(sweep)
            let phase = try await drive()
            #expect(phase.fulls.isEmpty && phase.reverse.isEmpty && phase.forward.count == shape.chains)
            if tick == shape.quietTick { quiet += phase.forward } else { forward += phase.forward }
            tickSeconds.append(Date().timeIntervalSince(start))
            tickWAL.append(Double((try index.writeCounters() - before).walBytes))
        }
        // S-1: a forward delta is change-sized.
        expectChangeSized("S-1 forward deltas", forward)
        // S-2: a backup that changed nothing.
        #expect(quiet.count == shape.chains)
        for record in quiet {
            #expect(record.added == 0 && record.removed == 0)
            #expect(record.cost.rows <= ScaleBounds.zeroChangeRows, "S-2: \(record.cost.rows) rows")
        }
        print("SCALE S-2 zero-change deltas: rows \(quiet.map(\.cost.rows)), WAL \(quiet.map(\.cost.walBytes)) bytes")
        print("SCALE forward housekeeping: mean \(String(format: "%.1f", mean(housekeepingCosts.map { Double($0.rows) }))) rows, "
            + "\(kib(mean(housekeepingCosts.map { Double($0.walBytes) })))")
        bench("per backup (reconcile, housekeeping and \(shape.chains) deltas): mean \(ms(mean(tickSeconds))), "
            + "WAL \(kib(mean(tickWAL))); housekeeping mean \(ms(mean(housekeepingSeconds))), "
            + "max \(ms(housekeepingSeconds.max() ?? 0))")
        try await expectExact("after the forward backups")

        try await summaries()
        try await search()
        try singleDeaths()
        try await fullRoute()
        try await massOmission()
        try await wholeChainDeath()

        try violations(afterHousekeeping: true, "at the end")
        try await expectExact("at the end")
        try await sampleReads("at the end")
        let size = try FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? Int ?? 0
        print("SCALE file: \(size) bytes, \(String(format: "%.1f", Double(size) / Double(paths))) B per model path")
    }

    /// S-5: a summary per path whatever its version count.
    func summaries() async throws {
        var generator = SeededGenerator(seed: 5)
        var picked: [(chain: Int, path: String)] = []
        let permanent = chains.map { $0.permanentFiles() }
        while picked.count < 200 {
            let c = picked.count % chains.count
            let node = permanent[c][Int(generator.next() % UInt64(permanent[c].count))]
            let path = chains[c].path(of: node)
            if !picked.contains(where: { $0.path == path }) { picked.append((c, path)) }
        }
        let paths = picked.map(\.path)
        let summaryStart = Date()
        let result = try await index.versionSummaries(ofPaths: paths)
        let summarySeconds = Date().timeIntervalSince(summaryStart)
        #expect(result.count == 200)
        var wrong = 0
        for (c, path) in picked {
            let newestTick = listed[c].max() ?? -1
            guard let summary = result[PathKey(path)],
                  summary.count == listed[c].count,
                  summary.newest.id == id(chain: c, tick: newestTick)
            else {
                wrong += 1
                continue
            }
        }
        #expect(wrong == 0, "S-5: \(wrong) of 200 summaries disagree with the model")
        print("SCALE S-5 summaries: \(result.count) of 200, each over \(listed.map(\.count).min() ?? 0)+ versions")
        let start = Date()
        var total = 0
        for path in paths { total += try await index.versions(ofPath: path).count }
        let versionsSeconds = Date().timeIntervalSince(start)
        #expect(total == result.values.map(\.count).reduce(0, +))
        bench("S-5 200 paths: versionSummaries \(ms(summarySeconds)); versions(ofPath:) x 200 \(ms(versionsSeconds)) "
            + "for \(total) versions")
    }

    /// A one-letter search, the Restore pane's worst keystroke.
    func search() async throws {
        let limit = await MainActor.run { AppModel.indexSearchLimit }
        let hits = try await index.searchPaths(matching: "i", limit: limit)
        #expect(hits.count == limit)
        guard shape.bench else { return }
        let start = Date()
        for _ in 0 ..< 5 { _ = try await index.searchPaths(matching: "i", limit: limit) }
        let common = Date().timeIntervalSince(start) / 5
        let start3 = Date()
        for _ in 0 ..< 5 { _ = try await index.searchPaths(matching: "inv", limit: limit) }
        let common3 = Date().timeIntervalSince(start3) / 5
        bench("search: one letter 'i' \(ms(common)), 'inv' \(ms(common3)) (means of 5, limit \(limit))")
    }

    /// S-4: housekeeping after one middle death costs that death's gap, at
    /// a snapshot count in the thousands; with nothing queued it writes
    /// nothing.
    func singleDeaths() throws {
        let newest = shape.historyTicks + shape.forwardTicks - 1
        // Ticks with one-tick files, inside the recent region, so both
        // neighbours are listed and indexed.
        let first = (newest - shape.keepRecent + 10) / 5 * 5 + 5
        let candidates = Array(stride(from: first, to: newest - 2, by: 5))
        var costs: [WriteCounters] = []
        var churns: [Int] = []
        var times: [Double] = []
        for (n, tick) in candidates.prefix(12).enumerated() {
            let c = n % shape.chains
            guard listed[c].contains(tick),
                  let below = listed[c].filter({ $0 < tick }).max(),
                  let above = listed[c].filter({ $0 > tick }).min()
            else { continue }
            let chain = chains[c]
            let left = chain.delta(from: below, to: tick)
            let right = chain.delta(from: tick, to: above)
            churns.append(left.added.count + left.removed.count + right.added.count + right.removed.count)
            listed[c].remove(tick)
            try reconcile()
            var cost = WriteCounters(rows: 0, walBytes: 0)
            times.append(try seconds { cost = try index.cost { try index.housekeeping() } })
            costs.append(cost)
        }
        #expect(costs.count >= 10)
        let meanRows = mean(costs.map { Double($0.rows) })
        let bound = mean(churns.map { ScaleBounds.housekeepingRows(churn: $0) })
        print("SCALE S-4 single deaths: n=\(costs.count) mean churn \(String(format: "%.1f", mean(churns.map(Double.init)))) "
            + "rows \(String(format: "%.1f", meanRows)) (bound \(String(format: "%.1f", bound)), max \(costs.map(\.rows).max() ?? 0)) "
            + "WAL \(kib(mean(costs.map { Double($0.walBytes) })))")
        #expect(meanRows <= bound, "S-4 rows")
        // Each of those deaths stranded one-tick files: housekeeping must
        // have deleted something, or the bound above measured nothing.
        #expect(costs.allSatisfy { $0.rows > 1 })
        bench("S-4 housekeeping after one middle death: mean \(ms(mean(times))), max \(ms(times.max() ?? 0))")
        let idle = try index.cost { try index.housekeeping() }
        #expect(idle == WriteCounters(rows: 0, walBytes: 0), "S-4: housekeeping with an empty queue wrote \(idle)")
        try violations(afterHousekeeping: true, "after the single deaths")
    }

    /// S-6: the full route into a populated chain — at a dead window end
    /// (every chain's newest forgotten, then a new backup), and as the
    /// fallback of a failed diff at an alive one. The read is
    /// population-sized; the writes must be the listing's churn against the
    /// runs at the window end.
    func fullRoute() async throws {
        var heads: [StepRecord] = []
        var fallbacks: [StepRecord] = []
        for round in 0 ..< shape.fullRouteRounds {
            let deadTick = shape.historyTicks + shape.forwardTicks + 2 * round
            for c in 0 ..< shape.chains {
                guard let newest = listed[c].max() else { continue }
                listed[c].remove(newest)
            }
            try reconcile()
            try index.housekeeping()
            for c in 0 ..< shape.chains { listed[c].insert(deadTick) }
            retain(now: deadTick)
            try reconcile()
            try index.housekeeping()
            let dead = try await drive()
            #expect(dead.windowedFulls.count == shape.chains, "S-6: a dead window end must take the full route")
            #expect(dead.forward.isEmpty && dead.reverse.isEmpty)
            heads += dead.windowedFulls

            let failTick = deadTick + 1
            for c in 0 ..< shape.chains { listed[c].insert(failTick) }
            retain(now: failTick)
            try reconcile()
            try index.housekeeping()
            let failed = try await drive(failDiffs: true)
            #expect(failed.windowedFulls.count == shape.chains)
            fallbacks += failed.windowedFulls
        }
        // One gate for both: the TEMP stage's rows ride the row counter
        // (one in, one out per streamed entry) and are subtracted; each
        // chunk that creates nodes pays its own transaction's FTS flush
        // (`ScaleBounds.fullRows`, `fullWAL`).
        expectChangeSized("S-6 full reads into a populated chain", heads + fallbacks, rows: \.durableRows,
                          rowBound: { ScaleBounds.fullRows(added: $0.added, removed: $0.removed, chunksWithAdds: $0.chunksWithAdds) },
                          walBound: { ScaleBounds.fullWAL(added: $0.added, removed: $0.removed, chunksWithAdds: $0.chunksWithAdds) })
        // A tripwire on the subtraction's premise. If the stage stops riding
        // the counter as two rows per entry (held in Swift, or cleared by a
        // statement the counter does not see), the durable count goes
        // negative — thousands below zero at this shape — and would absorb a
        // durable regression of that size. Recalibrate rather than loosen.
        #expect((heads + fallbacks).allSatisfy { $0.durableRows >= 0 },
                "S-6: the stage-row subtraction no longer matches what the counter sees")
        for (label, records) in [("at a dead window end", heads), ("after a failed diff", fallbacks)] {
            print("SCALE S-6 \(label): n=\(records.count) mean durable rows "
                + "\(String(format: "%.1f", mean(records.map { Double($0.durableRows) }))), "
                + "WAL \(kib(mean(records.map { Double($0.cost.walBytes) }))), "
                + "\(String(format: "%.1f", mean(records.map { Double($0.chunksWithAdds) }))) chunks with adds of "
                + "\(String(format: "%.1f", mean(records.map { Double($0.streamed) / Double(SnapshotIndex.chunkSize) }.map { $0.rounded(.up) })))")
            bench("S-6 full read \(label): mean \(ms(mean(records.map(\.seconds)))) for "
                + "\(records.first?.streamed ?? 0) entries, of which the final chunk and the compare "
                + "\(ms(mean(records.map(\.finalSeconds))))")
        }
        if shape.bench {
            // The compare's population read scans every chain's runs
            // (`full.fwdClose`, FINAL.md option P6): its size here.
            let runs = try await index.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM run") ?? 0 }
            bench("S-6 the compare read \(runs) runs across \(shape.chains) chains")
        }
        try violations(afterHousekeeping: false, "after the full routes")
        try await expectExact("after the full routes")
    }

    /// FINAL.md risk 6 and S-4's bulk case: a listing that omits half of
    /// every chain's snapshots (not the newest), one housekeeping pass that
    /// must leave nothing queued, then the next listing bringing them all
    /// back, each read again.
    func massOmission() async throws {
        var omitted: [[Int]] = []
        for c in 0 ..< shape.chains {
            let ticks = listed[c].sorted()
            let dropped = ticks.dropLast().enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            omitted.append(dropped)
            listed[c].subtract(dropped)
        }
        let count = omitted.map(\.count).reduce(0, +)
        var outcome = ReconcileOutcome()
        var sweep = WriteCounters(rows: 0, walBytes: 0)
        let omissionSeconds = try seconds {
            outcome = try reconcile()
            sweep = try index.cost { try index.housekeeping() }
        }
        #expect(outcome.died.count == count)
        print("SCALE S-4 bulk: \(count) snapshots forgotten at once; one housekeeping pass changed \(sweep.rows) rows")
        try violations(afterHousekeeping: true, "after one pass over a bulk forget")
        try await expectExact("after the omission")

        for c in 0 ..< shape.chains { listed[c].formUnion(omitted[c]) }
        let back = try reconcile()
        #expect(back.revived.count == count)
        #expect(try await index.isComplete() == false)
        let start = Date()
        let recovery = try await drive()
        let recoverySeconds = Date().timeIntervalSince(start)
        #expect(recovery.steps == count)
        print("SCALE recovery: \(count) returning snapshots read again in \(recovery.fulls.count) full reads "
            + "and \(recovery.forward.count + recovery.reverse.count) deltas")
        bench("mass omission of \(count): reconcile and housekeeping \(ms(omissionSeconds)); recovery "
            + "\(String(format: "%.1f", recoverySeconds)) s for \(recovery.steps) steps")
        try await expectExact("after the recovery")
    }

    /// A plan deleted with its backups: its chain loses every snapshot, and
    /// housekeeping drops its runs, its row and its nodes (the one scan of
    /// every chain's runs housekeeping has, `hk.orphanChainRuns`).
    func wholeChainDeath() async throws {
        let c = shape.chains - 1
        let sample = chains[c].permanentFiles().prefix(50).map { chains[c].path(of: $0) }
        listed[c] = []
        var sweep = WriteCounters(rows: 0, walBytes: 0)
        let s = try seconds {
            try reconcile()
            sweep = try index.cost { try index.housekeeping() }
        }
        print("SCALE whole-chain death: housekeeping changed \(sweep.rows) rows")
        bench("whole-chain death: reconcile and housekeeping \(ms(s))")
        try violations(afterHousekeeping: true, "after a whole chain died")
        let left = try await index.versionSummaries(ofPaths: Array(sample))
        #expect(left.isEmpty, "the dead chain's paths still answer: \(left.count)")
    }
}
