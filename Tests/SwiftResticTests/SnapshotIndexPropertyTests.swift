import Foundation
import Testing

/// The randomized differential test (FINAL.md 5.2, N2): a seeded world of
/// snapshots with known contents drives the index through everything the
/// backfill can meet — stale listings, forgets at any frontier and in the
/// middle of a reverse backfill, a whole chain dying and returning, the
/// streamed snapshot dying and returning between two of its own chunks,
/// cancelled streams, a reopen mid-stream, injected diff failures, file<->dir
/// flips spelled both as complete diffs and as restic's `T`-only lines,
/// back-dated snapshots, snapshots set aside as unreadable, and housekeeping
/// skipped at random. The truth comes from the world, never from SQL.
///
/// After every write the stored-state checks must hold ((a)–(c) only right
/// after housekeeping). Check (i) runs by path: the nodes a reopen strands
/// by dropping an open stream's stage — FINAL.md risk 8, the one allowed
/// exception — are recorded at that reopen and excused alone, so a node
/// stranded any other way still fails the run, before or after a crash. At
/// the end of every round the planner must reach `.done`, and every read
/// must equal the truth.
///
/// The default scale is modest so `./build.sh test` stays quick: 3 seeds of
/// 15 rounds per variant. For the scale the harness ran, 40 seeds of 30
/// rounds, pass `SWIFTRESTIC_INDEX_PROPERTY=40,30` to the test process —
/// through xcodebuild that is `TEST_RUNNER_SWIFTRESTIC_INDEX_PROPERTY=40,30`,
/// which it forwards with the prefix stripped. Each variant prints the scale
/// it ran and its counters, so a log shows which scale was reached.
@Suite("snapshot index properties")
struct SnapshotIndexPropertyTests {
    struct Variant: Sendable, CustomTestStringConvertible {
        var name: String
        /// The streamed snapshot dies and returns between two of its chunks.
        var flaps: Bool
        /// Stale listings are dropped, as the coordinator's generation guard
        /// drops them, instead of being applied first.
        var guarded: Bool
        /// A cancelled stream is sometimes a crash: the store is reopened.
        var crashes: Bool
        var salt: UInt64

        var testDescription: String { name }
    }

    static let variants: [Variant] = [
        Variant(name: "plain", flaps: false, guarded: false, crashes: false, salt: 0),
        Variant(name: "flaps", flaps: true, guarded: false, crashes: false, salt: 17),
        Variant(name: "guarded flaps", flaps: true, guarded: true, crashes: false, salt: 29),
        Variant(name: "crashes", flaps: false, guarded: false, crashes: true, salt: 43),
    ]

    static var scale: (seeds: Int, rounds: Int) {
        guard let value = ProcessInfo.processInfo.environment["SWIFTRESTIC_INDEX_PROPERTY"] else { return (3, 15) }
        let parts = value.split(separator: ",").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (3, 15)
    }

    @Test("the index answers exactly what a brute-force model of the listings says", arguments: variants)
    func differential(_ variant: Variant) async throws {
        let (seeds, rounds) = Self.scale
        var totals: [String: Int] = [:]
        var failures: [String] = []
        for seed in 1 ... seeds {
            let run = try PropertyRun(seed: UInt64(seed) &* 1_000_003 &+ variant.salt, variant: variant)
            try await run.run(rounds: rounds)
            for (key, value) in run.stats { totals[key, default: 0] += value }
            failures += run.failures.prefix(5).map { "seed \(seed): \($0)" }
        }
        print("SnapshotIndexPropertyTests \(variant.name): seeds=\(seeds) rounds=\(rounds) "
            + totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        #expect(failures.isEmpty, "\(failures.prefix(12).joined(separator: "\n"))")
        #expect((totals["mismatch"] ?? 0) == 0)
        #expect((totals["violation"] ?? 0) == 0)
        #expect((totals["deltaThrew"] ?? 0) == 0)
        #expect((totals["tOnlyAccepted"] ?? 0) == 0)
        // The drivers must actually have exercised what they claim to.
        #expect((totals["delta"] ?? 0) > 0 && (totals["full"] ?? 0) > 0)
        #expect((totals["comparedHeld"] ?? 0) > 0)
        #expect((totals["tOnlyRefused"] ?? 0) > 0)
        if variant.flaps { #expect((totals["midStreamFlap"] ?? 0) > 0) }
        if variant.crashes { #expect((totals["crashReopen"] ?? 0) > 0) }
    }
}

// MARK: - The world

/// One snapshot of the model: its listing metadata, content and chain.
private struct WorldSnapshot {
    var id: String
    var micros: Int64
    var chain: String
    var content: IndexContent
    var snapshot: Snapshot
}

private struct World {
    var all: [String: WorldSnapshot] = [:]
    var alive: [String] = []
    var clock: Int64 = 10_000_000_000
    var usedTimes = Set<Int64>()
    var serial = 0

    var listing: [Snapshot] {
        alive.compactMap { all[$0] }.sorted { ($0.micros, $0.id) < ($1.micros, $1.id) }.map(\.snapshot)
    }
}

private let universeFiles = [
    "/r/a/inv-1.txt", "/r/a/inv-2.txt", "/r/a/img-3.jpg", "/r/b/rep.md", "/r/b/inv-4.pdf",
    "/r/c/x/img-5.jpg", "/r/c/x/f6", "/r/c/f7", "/r/f8", "/r/inv-9",
]

private struct Dice {
    var generator: SeededGenerator

    mutating func chance(_ p: Double) -> Bool {
        Double(generator.next() % 1_000_000) / 1_000_000 < p
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(generator.next() % UInt64(range.count))
    }

    mutating func int(_ range: Range<Int>) -> Int {
        range.lowerBound + Int(generator.next() % UInt64(range.count))
    }
}

// MARK: - One seeded run

private final class PropertyRun {
    let variant: SnapshotIndexPropertyTests.Variant
    let fixture: IndexFixture
    var dice: Dice
    var world = World()
    var stats: [String: Int] = [:]
    var failures: [String] = []
    /// Paths a reopen stranded (risk 8) that are stranded still: a leftover
    /// that a re-read adopts leaves the set, so stranding it again is
    /// caught.
    var crashLeftovers = Set<String>()
    private let planP = "swiftrestic-plan-00000000-0000-0000-0000-00000000000p"
    private let planQ = "swiftrestic-plan-00000000-0000-0000-0000-00000000000q"

    init(seed: UInt64, variant: SnapshotIndexPropertyTests.Variant) throws {
        self.variant = variant
        dice = Dice(generator: SeededGenerator(seed: seed))
        fixture = try IndexFixture()
    }

    var index: SnapshotIndex { fixture.index }

    func bump(_ key: String, by amount: Int = 1) { stats[key, default: 0] += amount }

    func fail(_ key: String, _ message: String) {
        bump(key)
        if failures.count < 20 { failures.append(message) }
    }

    // MARK: Checked writes

    private func check(_ operation: String, afterHousekeeping: Bool = false) {
        bump("invariantChecks")
        do {
            let found = try index.violations(afterHousekeeping: afterHousekeeping, excusing: ["i"])
            for line in found { fail("violation", "after \(operation): \(line)") }
            let stranded = try index.strandedPaths()
            let unexcused = stranded.subtracting(crashLeftovers)
            if !unexcused.isEmpty {
                fail("violation", "after \(operation): (i) beyond crash leftovers: \(unexcused.sorted())")
            }
            crashLeftovers.formIntersection(stranded)
        } catch {
            fail("violation", "the invariant check threw after \(operation): \(error)")
        }
    }

    private func write<T>(_ operation: String, afterHousekeeping: Bool = false, _ body: () throws -> T) throws -> T {
        defer { check(operation, afterHousekeeping: afterHousekeeping) }
        return try body()
    }

    /// A reconcile, then — as the coordinator does after every applied
    /// listing — housekeeping, skipped at random as a crash between the two
    /// would skip it.
    func reconcile(_ listing: [Snapshot]) throws {
        try write("reconcile") { _ = try index.reconcile(listing: listing) }
        if dice.chance(0.3) {
            bump("housekeepingSkipped")
        } else {
            try write("housekeeping", afterHousekeeping: true) { try index.housekeeping() }
        }
    }

    // MARK: Snapshots and contents

    func newSnapshot(chain: String, backDated: Bool) throws {
        world.serial += 1
        let id = IndexTestData.hexID(world.serial &* 7919 &+ Int(variant.salt))
        var micros: Int64
        if backDated {
            let oldest = world.alive.compactMap { world.all[$0]?.micros }.min() ?? world.clock
            micros = oldest - Int64(dice.int(1 ... 5)) * 3_600_000_000
        } else {
            world.clock += 3_600_000_000
            micros = world.clock
        }
        while world.usedTimes.contains(micros) { micros += 7 }
        world.usedTimes.insert(micros)
        let base = world.all.values.filter { $0.chain == chain }.max { $0.micros < $1.micros }?.content
        let tags: [String]
        let host: String
        switch chain {
        case "P": tags = [planP]; host = "mac"
        case "Q": tags = [planQ]; host = "mac"
        case "U-laptop": tags = []; host = "laptop"
        default: tags = ["user-tag"]; host = "other"
        }
        let snapshot = try IndexTestData.snapshot(id, micros: micros, tags: tags, hostname: host, paths: ["/r"])
        world.all[id] = WorldSnapshot(id: id, micros: micros, chain: chain, content: randomContent(from: base), snapshot: snapshot)
        world.alive.append(id)
    }

    /// The harness's content generator: a small universe with a directory
    /// `/r/k` that flips kind, gains and loses a child, and an empty
    /// directory that comes and goes.
    func randomContent(from base: IndexContent?) -> IndexContent {
        var files = Set<String>()
        var kIsDirectory = false, kChild = false, kPresent = true, emptyDirectory = false
        if let base {
            for file in universeFiles where base[file] != nil { files.insert(file) }
            kPresent = base["/r/k"] != nil
            kIsDirectory = base["/r/k"] ?? false
            kChild = base["/r/k/c"] != nil
            emptyDirectory = base["/r/e"] != nil
            for file in universeFiles where dice.chance(0.2) {
                if files.contains(file) { files.remove(file) } else { files.insert(file) }
            }
            if dice.chance(0.25) { kIsDirectory.toggle() }
            if dice.chance(0.2) { kPresent.toggle() }
            if dice.chance(0.3) { kChild.toggle() }
            if dice.chance(0.15) { emptyDirectory.toggle() }
            if dice.chance(0.1) { files = files.filter { !$0.hasPrefix("/r/c/") } }
        } else {
            for file in universeFiles where dice.chance(0.6) { files.insert(file) }
            kIsDirectory = dice.chance(0.5)
            kChild = dice.chance(0.5)
        }
        var content: IndexContent = ["/r": true]
        for file in files {
            content[file] = false
            var prefix = ""
            for component in SnapshotIndex.components(file).dropLast() {
                prefix += "/" + component
                content[prefix] = true
            }
        }
        if kPresent {
            content["/r/k"] = kIsDirectory
            if kIsDirectory, kChild { content["/r/k/c"] = false }
        }
        if emptyDirectory { content["/r/e"] = true }
        return content
    }

    // MARK: The run

    func run(rounds: Int) async throws {
        for _ in 0 ..< 5 { try newSnapshot(chain: "P", backDated: false) }
        for _ in 0 ..< 4 { try newSnapshot(chain: "Q", backDated: false) }

        for round in 0 ..< rounds {
            if round > 0 {
                if dice.chance(0.8) {
                    let chain = dice.chance(0.15)
                        ? (dice.chance(0.5) ? "U-other" : "U-laptop")
                        : (dice.chance(0.5) ? "P" : "Q")
                    try newSnapshot(chain: chain, backDated: dice.chance(0.12))
                }
                if dice.chance(0.08) { for _ in 0 ..< 3 { try newSnapshot(chain: "P", backDated: true) } }
                if dice.chance(0.3), !world.alive.isEmpty {
                    for _ in 0 ..< dice.int(1 ... 2) where !world.alive.isEmpty {
                        world.alive.remove(at: dice.int(0 ..< world.alive.count))
                    }
                }
                if dice.chance(0.06) {
                    // A copy: the closure may not read `world` while
                    // removeAll holds it for modification.
                    let all = world.all
                    world.alive.removeAll { all[$0]?.chain == "Q" }
                    bump("chainDeath")
                }
            }
            let listing = world.listing
            let stale: [Snapshot]? = dice.chance(0.2) && listing.count > 1 ? listing.filter { _ in dice.chance(0.7) } : nil
            var midForget: String?
            let midAt = dice.int(1 ... 4)
            if dice.chance(0.3), world.alive.count > 2 { midForget = world.alive[dice.int(0 ..< world.alive.count)] }
            var after = world
            if let midForget { after.alive.removeAll { $0 == midForget } }

            if let stale {
                if variant.guarded {
                    bump("staleDropped")
                } else {
                    bump("staleApplied")
                    try reconcile(stale)
                }
            }
            try reconcile(listing)
            try await runLoop(before: world, after: after, midAt: midForget == nil ? nil : midAt)
            world = after
            try await verify(label: "round \(round)")
            if variant.crashes, dice.chance(0.05) {
                // A relaunch between rounds; any stream still staged is lost.
                bump("crashReopen")
                try reopenAfterCrash()
            }
        }
    }

    /// A relaunch: the TEMP stage and the session go with the connection,
    /// and whatever the open stream had created that no run holds is
    /// stranded (risk 8). Those paths, and only those, become excusable.
    private func reopenAfterCrash() throws {
        try fixture.reopen()
        let stranded = try index.strandedPaths()
        bump("crashLeftovers", by: stranded.subtracting(crashLeftovers).count)
        crashLeftovers.formUnion(stranded)
    }

    /// The planner loop, its world view switching when the mid-backfill
    /// forget lands.
    func runLoop(before: World, after: World, midAt: Int?) async throws {
        var view = before
        var fired = midAt == nil
        var last: IndexStep?
        var repeats = 0
        for n in 0 ..< 400 {
            if let midAt, n == midAt, !fired {
                fired = true
                try reconcile(after.listing)
                view = after
            }
            let step = try index.nextStep()
            repeats = step == last ? repeats + 1 : 0
            last = step
            if repeats > 6 {
                fail("mismatch", "stuck on \(step)")
                return
            }
            switch step {
            case .done:
                if !fired {
                    fired = true
                    try reconcile(after.listing)
                    view = after
                    continue
                }
                if try await !index.isComplete() {
                    // Only snapshots set aside remain (anything else is a
                    // bug the stuck check reports): the next launch releases
                    // them before its first reconcile.
                    bump("released")
                    try write("releaseUnreadable") { _ = try index.releaseUnreadable() }
                    try reconcile(view.listing)
                    continue
                }
                return
            case .full(let id):
                guard view.alive.contains(id) else {
                    fail("mismatch", "planner asked for dead \(id.suffix(6))")
                    return
                }
                if dice.chance(0.04) {
                    bump("markedUnreadable")
                    try write("markUnreadable") { try index.markUnreadable(snapshotID: id) }
                    continue
                }
                feedFull(view, id, flap: variant.flaps ? { try self.flap(view) } : nil)
            case .delta(let id, let base):
                guard view.alive.contains(id) else {
                    fail("mismatch", "planner asked for dead \(id.suffix(6))")
                    return
                }
                guard view.alive.contains(base), !dice.chance(0.15),
                      let target = view.all[id]?.content, let from = view.all[base]?.content
                else {
                    bump("diffFailed")
                    feedFull(view, id, flap: nil)
                    continue
                }
                let complete = IndexTestData.diff(from: from, to: target)
                let flipped = from.keys.filter { target[$0] != nil && target[$0] != from[$0] }
                if !flipped.isEmpty, dice.chance(0.5) {
                    // restic's form: one `T` line in the new spelling, both
                    // subtrees omitted. The store must refuse it.
                    let (added, removed) = tOnly(complete, flipped: flipped)
                    do {
                        try write("T-only delta") {
                            try index.ingestDelta(snapshotID: id, from: base, added: added, removed: removed)
                        }
                        fail("tOnlyAccepted", "a T-only delta for \(id.suffix(6)) was accepted")
                    } catch IndexError.kindChanged {
                        bump("tOnlyRefused")
                    } catch {
                        fail("deltaThrew", "a T-only delta threw \(error)")
                    }
                    feedFull(view, id, flap: nil)
                    continue
                }
                do {
                    try write("delta") {
                        try index.ingestDelta(snapshotID: id, from: base, added: complete.added, removed: complete.removed)
                    }
                    bump("delta")
                } catch {
                    fail("deltaThrew", "delta \(id.suffix(6)) <- \(base.suffix(6)) threw \(error)")
                    feedFull(view, id, flap: nil)
                }
            }
        }
        fail("mismatch", "step cap")
    }

    /// Removes each flipped path's old spelling and both subtrees, keeping
    /// only the new spelling of the flipped path itself.
    private func tOnly(_ diff: (added: [String], removed: [String]), flipped: [String]) -> (added: [String], removed: [String]) {
        func under(_ path: String, _ root: String) -> Bool { path.hasPrefix(root + "/") }
        func bare(_ path: String) -> String { SnapshotIndex.canonical(path) }
        let added = diff.added.filter { path in !flipped.contains { under(bare(path), $0) } }
        let removed = diff.removed.filter { path in !flipped.contains { bare(path) == $0 || under(bare(path), $0) } }
        return (added, removed)
    }

    /// Streams `id`'s listing in random chunks after `beginFull`. A cancel
    /// returns without the final, sometimes as a crash (the store reopens);
    /// a flap makes the streamed snapshot die and return between chunks.
    func feedFull(_ view: World, _ id: String, flap: (() throws -> Void)?) {
        bump("full")
        let entries = IndexTestData.ls(view.all[id]?.content ?? [:])
        let size = dice.int(1 ... 4)
        var chunks = stride(from: 0, to: entries.count, by: size).map { Array(entries[$0 ..< min($0 + size, entries.count)]) }
        if dice.chance(0.5) { chunks.append([]) }
        let cancelAt = dice.chance(0.12) && chunks.count > 1 ? dice.int(1 ..< chunks.count) : nil
        let crash = variant.crashes && cancelAt != nil && dice.chance(0.5)
        let flapAt = flap != nil && dice.chance(0.2) && chunks.count > 1 ? dice.int(1 ..< chunks.count) : nil
        do {
            try write("beginFull") { try index.beginFull(snapshotID: id) }
            for (i, chunk) in chunks.enumerated() {
                if i == cancelAt {
                    bump("cancel")
                    if crash {
                        bump("crashReopen")
                        try reopenAfterCrash()
                    }
                    return
                }
                if i == flapAt {
                    bump("midStreamFlap")
                    try flap?()
                }
                try write("ingestFull") {
                    try index.ingestFull(snapshotID: id, entries: chunk, final: i == chunks.count - 1)
                }
            }
        } catch IndexError.streamIdentityChanged(_) where flap != nil {
            // The coordinator's full route gives up on this snapshot for the
            // pass; the planner offers it again. Only a flap may cause it:
            // anything else a full read throws is a bug, which a catch-all
            // would hide — the dice cut the retry's chunks another way, the
            // read succeeds and the answers come out exact.
            bump("fullThrew")
        } catch {
            fail("fullThrewUnexpectedly", "a full read of \(id.suffix(6)) threw \(error)")
        }
    }

    /// A stale listing that drops each listed snapshot with probability
    /// 0.4 — the streamed one among them, often — then the fresh listing.
    func flap(_ view: World) throws {
        let now = view.listing
        let staleNow = now.filter { _ in dice.chance(0.6) }
        try reconcile(staleNow)
        try reconcile(now)
    }

    // MARK: Verification against the model

    func verify(label: String) async throws {
        let index = self.index
        if try await !index.isComplete() { fail("mismatch", "\(label): isComplete false at done") }
        var everything = Set<String>()
        for snapshot in world.all.values { everything.formUnion(snapshot.content.keys) }
        let alive = world.alive.compactMap { world.all[$0] }
        let paths = everything.sorted()
        func truth(_ path: String, chain: String? = nil) -> [String] {
            alive.filter { $0.content[path] != nil && (chain == nil || $0.chain == chain) }
                .sorted { $0.micros > $1.micros }.map(\.id)
        }

        let summaries = try await index.versionSummaries(ofPaths: paths)
        for path in paths {
            let want = truth(path)
            // Proof the comparison ran on real answers: a mismatch count of
            // zero means nothing if nothing held was ever compared.
            if !want.isEmpty { bump("comparedHeld") }
            let got = try await index.versions(ofPath: path).map(\.id)
            if got != want { fail("mismatch", "\(label): versions(\(path)) got \(got.map { $0.suffix(4) }) want \(want.map { $0.suffix(4) })") }
            let summary = summaries[PathKey(path)]
            if want.isEmpty {
                if summary != nil { fail("mismatch", "\(label): summary for unheld \(path)") }
            } else if summary?.count != want.count || summary?.newest.id != want.first {
                fail("mismatch", "\(label): summary(\(path)) got \(String(describing: summary?.count)) want \(want.count)")
            }
        }
        for snapshot in alive {
            let got = try await index.contains(paths: paths, inSnapshot: snapshot.id)
            let want = snapshot.content.byPathKey
            if got != want {
                fail("mismatch", "\(label): contains(\(snapshot.id.suffix(4))) differs: extra \(Set(got.keys).subtracting(want.keys).map(\.path).sorted()) missing \(Set(want.keys).subtracting(got.keys).map(\.path).sorted())")
            }
        }
        for dead in world.all.keys where !world.alive.contains(dead) {
            if try await !index.contains(paths: paths, inSnapshot: dead).isEmpty {
                fail("mismatch", "\(label): contains answered for unlisted \(dead.suffix(4))")
            }
        }
        for chain in Set(alive.map(\.chain)) {
            guard let key = alive.first(where: { $0.chain == chain }).map({ SnapshotIndex.chainKey(for: $0.snapshot) }) else { continue }
            for path in ["/r/k", "/r/a/inv-1.txt", "/r/c/x", "/r"] {
                let got = try await index.versions(ofPath: path, inChain: key).map(\.id)
                let want = truth(path, chain: chain)
                if got != want { fail("mismatch", "\(label): versions(\(path), inChain: \(chain)) got \(got.count) want \(want.count)") }
            }
        }
        // Global search: paths some listed snapshot holds, each with its
        // kind in the newest listed snapshot holding it.
        for query in ["inv", "img", "k", "c", "e"] {
            var want: [String: (micros: Int64, isDirectory: Bool)] = [:]
            for snapshot in alive {
                for (path, isDirectory) in snapshot.content where Self.basenameMatches(path, query) {
                    if let known = want[path], known.micros > snapshot.micros { continue }
                    want[path] = (snapshot.micros, isDirectory)
                }
            }
            let got = try await index.searchPaths(matching: query, limit: 200)
            let gotSet = Set(got.map { "\($0.path)|\($0.isDirectory)" })
            let wantSet = Set(want.map { "\($0.key)|\($0.value.isDirectory)" })
            if gotSet != wantSet {
                fail("mismatch", "\(label): search(\(query)) extra \(gotSet.subtracting(wantSet).sorted()) missing \(wantSet.subtracting(gotSet).sorted())")
            }
        }
    }

    /// The FTS5 unicode61 view of a basename: lowercased alphanumeric runs;
    /// a query token matches any of them as a prefix.
    static func basenameMatches(_ path: String, _ query: String) -> Bool {
        let name = SnapshotIndex.components(path).last ?? ""
        return name.lowercased().split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(query) }
    }
}
