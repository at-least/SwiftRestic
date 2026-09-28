import Foundation
import GRDB
import Testing

// No `@testable import SwiftRestic`: the test target compiles the index's
// sources itself, so SnapshotIndex and its SQL are already right here — and
// importing the app module adds a dependency a cold build cannot satisfy.

/// The planner route of every statement the snapshot index prepares — what a
/// green functional test cannot see. Nothing in the app ever ANALYZEs, so
/// SQLite plans from its default cost model, and every read and write here
/// was designed against the plans that model gives (FINAL.md 5.3). A plan
/// that drifts — a new index the planner prefers, a literal turned into a
/// parameter so `run_closed` stops applying — turns a change-sized statement
/// into a table scan without failing any answer; these pins fail instead.
///
/// Rules: each statement's plan must contain its fragments, and any `SCAN`
/// must name a table its rule allows. The allowed scans are the documented
/// ones: the full compare's population read (`full.fwdClose`,
/// `full.revFreeze`) and a whole chain's death (`hk.orphanChainRuns`) over
/// `run`; the listing-sized reads of `snap` (`snap.all` per reconcile,
/// `unreadable.list` once per launch); the chain list; and the small or
/// temporary tables (the one-row listing marker, the one stream's stage,
/// the GC scratch list, the housekeeping queue, the cache owners, the FTS
/// cursor). The floor — the
/// same pins against SQLite 3.43.2 — is `Tools/sqlite-floor.sh`, a separate
/// manual step, not part of `./build.sh test`.
@Suite("snapshot index plans")
struct SnapshotIndexPlanTests {
    struct Rule {
        var contains: [String]
        var scans: Set<String> = []
        var excludes: [String] = []
    }

    private static let byPrimaryKeyVersions = [
        "SEARCH r USING PRIMARY KEY (node_id=?)",
        "SEARCH s USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
    ]

    /// FINAL.md 5.3's table, one entry per registered statement. A
    /// statement with no fragments is a plain insert or a whole-table
    /// delete: its plan must simply scan nothing.
    static let rules: [String: Rule] = [
        "node.lookup": Rule(contains: ["SEARCH node USING COVERING INDEX sqlite_autoindex_node_1 (parent=? AND name=?)"]),
        "node.insert": Rule(contains: []),
        "node.maxID": Rule(contains: ["SEARCH node"]),
        "node.byID": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid=?)"]),
        "node.ftsIndexNew": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid>?)"]),
        "snap.all": Rule(contains: ["SCAN snap"], scans: ["snap"]),
        "snap.byHash": Rule(contains: ["SEARCH snap USING INDEX sqlite_autoindex_snap_1 (hash=?)"]),
        "snap.delete": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snap.insert": Rule(contains: []),
        "snap.markIndexed": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snap.markUnreadable": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snap.repend": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chain.insert": Rule(contains: []),
        "chain.byKey": Rule(contains: ["SEARCH chain USING INDEX sqlite_autoindex_chain_1 (key=?)"]),
        "chain.nextSeq": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chain.takeSeq": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chain.byID": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chain.setWindow": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "gone.insert": Rule(contains: []),
        "gone.delete": Rule(contains: ["SEARCH temp.gone USING PRIMARY KEY (hash=?)"]),
        "hk.enqueue": Rule(contains: []),
        "listing.markApplied": Rule(contains: []),
        "unreadable.list": Rule(contains: ["SCAN snap USING COVERING INDEX snap_cover"], scans: ["snap"]),
        "fwd.close": Rule(
            contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=?)"], excludes: ["run_closed"]),
        "fwd.openRun": Rule(
            contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=?)"], excludes: ["run_closed"]),
        "fwd.insert": Rule(contains: []),
        "rev.freeze": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"]),
        "rev.bottomRun": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"]),
        "rev.insert": Rule(contains: []),
        "stage.insert": Rule(contains: []),
        "stage.clear": Rule(contains: []),
        // One row: the scan stops at the first (the SQL's LIMIT 1).
        "stage.owner": Rule(contains: ["SCAN temp.stage"], scans: ["temp.stage"]),
        "stage.runless": Rule(contains: ["SCAN st", "SEARCH r USING PRIMARY KEY (node_id=?)"], scans: ["st"]),
        "full.firstInsert": Rule(contains: ["SCAN temp.stage"], scans: ["temp.stage"]),
        "full.fwdClose": Rule(
            contains: ["SCAN run", "SEARCH g USING PRIMARY KEY (node_id=? AND snap_id=?)"], scans: ["run"]),
        "full.fwdInsert": Rule(
            contains: ["SCAN g", "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)"], scans: ["g"]),
        "full.revFreeze": Rule(
            contains: ["SCAN run", "SEARCH g USING PRIMARY KEY (node_id=? AND snap_id=?)"], scans: ["run"]),
        "full.revInsert": Rule(
            contains: ["SCAN g", "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"], scans: ["g"]),
        "plan.pendingChains": Rule(
            contains: [
                "SCAN chain USING COVERING INDEX sqlite_autoindex_chain_1",
                "SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=?)",
            ],
            scans: ["chain"]),
        "plan.pendingDesc": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=?)"], excludes: ["TEMP B-TREE"]),
        "plan.lowestAbove": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq>?)"], excludes: ["TEMP B-TREE"]),
        "plan.highestBelow": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq<?)"], excludes: ["TEMP B-TREE"]),
        "plan.windowEnd": Rule(contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq=?)"]),
        "plan.pendingBetween": Rule(
            contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)"],
            scans: ["CONSTANT"]),
        "hk.chains": Rule(contains: ["SCAN hk_pending"], scans: ["hk_pending"]),
        "hk.seqs": Rule(contains: ["SEARCH hk_pending USING PRIMARY KEY (chain_id=?)"]),
        "hk.done": Rule(contains: ["SEARCH hk_pending USING PRIMARY KEY (chain_id=?)"]),
        "hk.chainHasSnap": Rule(
            contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=?)"], scans: ["CONSTANT"]),
        "hk.chainDelete": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "hk.aliveBelow": Rule(contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq<?)"]),
        "hk.aliveAbove": Rule(contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>?)"]),
        // 3.43.2 reads run_closed as COVERING here, 3.51.0 not: the
        // fragment omits the word so both versions match.
        "hk.bottom": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq<?)"]),
        "hk.gap": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        "hk.top": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        "hk.orphanChainRuns": Rule(contains: ["SCAN run"], scans: ["run"]),
        "gc.clear": Rule(contains: []),
        "gc.insert": Rule(contains: []),
        "gc.keepCollectable": Rule(
            contains: [
                "SCAN temp.gc",
                "SEARCH run USING PRIMARY KEY (node_id=?)",
                "SEARCH node USING COVERING INDEX sqlite_autoindex_node_1 (parent=?)",
                "SEARCH temp.stage USING PRIMARY KEY (node_id=?)",
            ],
            scans: ["temp.gc"]),
        "gc.parents": Rule(contains: ["SCAN g", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["g"]),
        "gc.deleteFTS": Rule(contains: ["SCAN g", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["g"]),
        "gc.deleteNodes": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid=?)"]),
        "q.versionsTimed": Rule(contains: byPrimaryKeyVersions + ["USE TEMP B-TREE FOR ORDER BY"]),
        "q.versionsInChain": Rule(contains: [
            "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)",
            "SCALAR SUBQUERY",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
            "SEARCH s USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
        ]),
        "q.summaryCounts": Rule(contains: byPrimaryKeyVersions, excludes: ["TEMP B-TREE"]),
        "q.summaryNewest": Rule(contains: byPrimaryKeyVersions + ["USE TEMP B-TREE FOR ORDER BY"]),
        "q.containsKind": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq<?)"]),
        "q.aliveRuns": Rule(contains: [
            "SEARCH r USING PRIMARY KEY (node_id=?)",
            "CORRELATED SCALAR SUBQUERY",
            "SEARCH s USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
        ]),
        "q.newestCover": Rule(contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)"]),
        "q.searchFTS": Rule(
            contains: ["SCAN f VIRTUAL TABLE INDEX 0:M1", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["f"]),
        // `listing_applied` holds one row at most (its CHECK), so its scan
        // is one row.
        "q.notComplete": Rule(
            contains: [
                "SCAN listing_applied",
                "SCAN chain USING COVERING INDEX sqlite_autoindex_chain_1",
                "SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=?)",
            ],
            scans: ["listing_applied", "chain", "CONSTANT"]),
        "cache.ownerPut": Rule(contains: []),
        "cache.listingPut": Rule(contains: []),
        "cache.diffPut": Rule(contains: []),
        "cache.listingGet": Rule(contains: [
            "SEARCH dir_listing USING INDEX sqlite_autoindex_dir_listing_1 (snapshot_id=? AND dir_path=?)",
        ]),
        "cache.diffGet": Rule(contains: [
            "SEARCH diff_result USING INDEX sqlite_autoindex_diff_result_1 (older_id=? AND newer_id=?)",
        ]),
        "cache.sweepIDs": Rule(
            contains: ["SCAN o", "SEARCH s USING COVERING INDEX sqlite_autoindex_snap_1 (hash=?)"], scans: ["o"]),
        "cache.sweepListing": Rule(contains: ["INDEX sqlite_autoindex_dir_listing_1 (snapshot_id=?)"]),
        "cache.sweepDiffOlder": Rule(contains: ["INDEX sqlite_autoindex_diff_result_1 (older_id=?)"]),
        "cache.sweepDiffNewer": Rule(contains: ["INDEX diff_result_newer (newer_id=?)"]),
        "cache.sweepOwner": Rule(contains: ["SEARCH cache_owner USING PRIMARY KEY (snapshot_id=?)"]),
    ]

    /// What `rule` finds wrong with `plan`, or nothing.
    static func problems(_ plan: [String], _ rule: Rule) -> [String] {
        var found: [String] = []
        let text = plan.joined(separator: "\n")
        for fragment in rule.contains where !text.contains(fragment) { found.append("missing '\(fragment)'") }
        for fragment in rule.excludes where text.contains(fragment) { found.append("has '\(fragment)'") }
        for line in plan where line.hasPrefix("SCAN ") {
            let target = line.dropFirst("SCAN ".count).prefix { $0 != " " }
            if !rule.scans.contains(String(target)) { found.append("unexpected '\(line)'") }
        }
        return found
    }

    /// `EXPLAIN QUERY PLAN` with every parameter bound to NULL (the SQL uses
    /// plain `?` only, so the count is the number of question marks).
    static func plan(_ db: Database, _ sql: String) throws -> [String] {
        let nulls = Array(repeating: DatabaseValue.null, count: sql.filter { $0 == "?" }.count)
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: StatementArguments(nulls))
            .compactMap { $0["detail"] as String? }
    }

    /// A populated file through the public API — three chains (two plans and
    /// an untagged lineage) of about 1.7k paths each, a dozen snapshots per
    /// chain read newest-first then forward, retention deaths with
    /// housekeeping, closed runs of every shape, one unreadable snapshot and
    /// the browse caches — then reopened as a plain queue with the
    /// production configuration and the writer's TEMP tables. Plan choice
    /// without statistics does not depend on the rows; the seed is for
    /// realism, and the stat1 assertion keeps the premise honest.
    static func seededDatabase(_ fixture: IndexFixture) throws -> DatabaseQueue {
        let index = fixture.index
        var arrivals: [(n: Int, snapshot: Snapshot)] = []
        var contents: [String: IndexContent] = [:]
        let chains: [(tags: [String], root: String)] = [
            ([IndexTestData.planA], "/a"), ([IndexTestData.planB], "/b"), ([], "/u"),
        ]
        for (c, chain) in chains.enumerated() {
            var content: IndexContent = [chain.root: true]
            for d in 0 ..< 17 {
                content["\(chain.root)/d\(d)"] = true
                for f in 0 ..< 100 { content["\(chain.root)/d\(d)/f\(f)"] = false }
            }
            for n in 0 ..< 15 {
                if n > 0 {
                    for k in 0 ..< 10 {
                        content["\(chain.root)/d\(k)/f\((n * 7 + k) % 100)"] = nil
                        content["\(chain.root)/d\(k)/new\(n)-\(k)"] = false
                    }
                }
                let id = IndexTestData.hexID(c * 100 + n)
                contents[id] = content
                arrivals.append((n, try IndexTestData.snapshot(
                    id, micros: Int64(n * 10 + c) * 1_000_000, tags: chain.tags, paths: [chain.root])))
            }
        }
        // The first twelve of each chain are history, read newest first; the
        // last three arrive later as new backups, read forward.
        _ = try index.reconcile(listing: arrivals.filter { $0.n < 12 }.map(\.snapshot))
        try index.runToDone(contents)
        _ = try index.reconcile(listing: arrivals.map(\.snapshot))
        try index.runToDone(contents)
        // Retention thins the middle of each chain.
        let survivors = arrivals.filter { ![3, 5, 6, 9].contains($0.n) }.map(\.snapshot)
        _ = try index.reconcile(listing: survivors)
        try index.housekeeping()
        try index.recordListing(snapshotID: survivors[0].id, directory: "/a", nodes: [])
        try index.recordDiff(olderID: survivors[0].id, newerID: survivors[1].id, changes: [])
        _ = try index.reconcile(listing: survivors + [try IndexTestData.snapshot(
            IndexTestData.hexID(999), micros: 999_000_000, tags: [IndexTestData.planA], paths: ["/a"])])
        try index.markUnreadable(snapshotID: IndexTestData.hexID(999))
        try index.close()

        let queue = try DatabaseQueue(path: fixture.path, configuration: SnapshotIndex.configuration())
        try queue.writeWithoutTransaction { try $0.execute(sql: SnapshotIndexSchema.temporary) }
        return queue
    }

    /// Which SQLite this process runs on, printed on every run. The floor
    /// script (`Tools/sqlite-floor.sh`) swaps the library in through the
    /// dynamic loader and sets `SWIFTRESTIC_EXPECT_SQLITE_VERSION`, so a run
    /// where the swap silently did not happen fails here instead of passing
    /// as a floor run on the system library.
    @Test("the linked SQLite is the one the run expects")
    func linkedSQLiteVersion() throws {
        let version = try DatabaseQueue().read { try String.fetchOne($0, sql: "SELECT sqlite_version()") }
        print("SnapshotIndexPlanTests: sqlite_version()=\(version ?? "nil")")
        if let expected = ProcessInfo.processInfo.environment["SWIFTRESTIC_EXPECT_SQLITE_VERSION"] {
            #expect(version == expected)
        }
    }

    @Test("every registered statement has a rule and every rule a statement; parameters are plain")
    func registryMatchesRules() {
        let names = SnapshotIndex.registeredStatements.map(\.name)
        #expect(Set(names).count == names.count, "duplicate names")
        #expect(Set(names) == Set(Self.rules.keys), "unruled: \(Set(names).subtracting(Self.rules.keys).sorted()) stale: \(Set(Self.rules.keys).subtracting(names).sorted())")
        for (name, sql) in SnapshotIndex.registeredStatements {
            #expect(sql.range(of: #"\?\d"#, options: .regularExpression) == nil, "\(name) numbers its parameters")
        }
    }

    @Test("every statement plans as pinned, and nothing scans a table its rule does not allow")
    func plansArePinned() throws {
        let fixture = try IndexFixture()
        let queue = try Self.seededDatabase(fixture)
        defer { try? queue.close() }
        try queue.inDatabase { db in
            let statTables = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_schema WHERE name LIKE 'sqlite_stat%'")
            #expect(statTables == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node") ?? 0 > 5_000)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM run WHERE last_seq < 2147483647") ?? 0 > 0)
            for (name, sql) in SnapshotIndex.registeredStatements {
                guard let rule = Self.rules[name] else { continue }
                let plan = try Self.plan(db, sql)
                let found = Self.problems(plan, rule)
                #expect(found.isEmpty, "\(name): \(found) in plan \(plan)")
            }
        }
    }

    @Test("the checker fails a statement whose partial-index literal became a parameter")
    func checkerCatchesAScan() throws {
        let fixture = try IndexFixture()
        let queue = try Self.seededDatabase(fixture)
        defer { try? queue.close() }
        // hk.gap with the literal `last_seq < 2147483647` bound instead: the
        // planner can no longer prove the partial index applies.
        let bare = """
            DELETE FROM run WHERE chain_id = ? AND last_seq > ? AND last_seq < ? AND last_seq < ?
                AND first_seq > ?
            RETURNING node_id
            """
        let plan = try queue.inDatabase { try Self.plan($0, bare) }
        let rule = try #require(Self.rules["hk.gap"])
        #expect(plan.contains("SCAN run"), "\(plan)")
        #expect(!Self.problems(plan, rule).isEmpty)
    }
}
