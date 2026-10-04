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
/// ones: the full compare's population read (`fullForwardClose`,
/// `fullReverseFreeze`) and a whole chain's death (`hkOrphanChainNodes`,
/// the fill that queues its nodes) over `run`; the listing-sized reads of
/// `snap` (`snapAll` per reconcile, `unreadableList` once per launch); the
/// chain list; and the small or
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

    /// FINAL.md 5.3's table, one entry per registered statement, keyed by
    /// the statement's property name in `SnapshotIndexSchema.Statements`. A
    /// statement with no fragments is a plain insert or a whole-table
    /// delete: its plan must simply scan nothing.
    static let rules: [String: Rule] = [
        "nodeLookup": Rule(contains: ["SEARCH node USING COVERING INDEX sqlite_autoindex_node_1 (parent=? AND name=?)"]),
        "nodeInsert": Rule(contains: []),
        "nodeMaxID": Rule(contains: ["SEARCH node"]),
        "nodeByID": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid=?)"]),
        "nodeFTSIndexNew": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid>?)"]),
        "snapAll": Rule(contains: ["SCAN snap"], scans: ["snap"]),
        "snapByHash": Rule(contains: ["SEARCH snap USING INDEX sqlite_autoindex_snap_1 (hash=?)"]),
        "snapDelete": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snapInsert": Rule(contains: []),
        "snapMarkIndexed": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snapMarkUnreadable": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "snapRepend": Rule(contains: ["SEARCH snap USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chainInsert": Rule(contains: []),
        "chainByKey": Rule(contains: ["SEARCH chain USING INDEX sqlite_autoindex_chain_1 (key=?)"]),
        "chainNextSeq": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chainTakeSeq": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chainByID": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "chainSetWindow": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "hkEnqueue": Rule(contains: []),
        "listingMarkApplied": Rule(contains: []),
        "unreadableList": Rule(contains: ["SCAN snap USING COVERING INDEX snap_cover"], scans: ["snap"]),
        "forwardClose": Rule(
            contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=?)"], excludes: ["run_closed"]),
        "forwardOpenRun": Rule(
            contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=?)"], excludes: ["run_closed"]),
        "forwardInsert": Rule(contains: []),
        "reverseFreeze": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"]),
        "reverseBottomRun": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"]),
        "reverseInsert": Rule(contains: []),
        "editInsert": Rule(contains: []),
        "blindInsert": Rule(contains: []),
        "stageInsert": Rule(contains: []),
        "stageClear": Rule(contains: []),
        // One row: the scan stops at the first (the SQL's LIMIT 1).
        "stageOwner": Rule(contains: ["SCAN temp.stage"], scans: ["temp.stage"]),
        "stageRunlessNodes": Rule(contains: ["SCAN st", "SEARCH r USING PRIMARY KEY (node_id=?)"], scans: ["st"]),
        "fullFirstInsert": Rule(contains: ["SCAN temp.stage"], scans: ["temp.stage"]),
        "fullForwardClose": Rule(
            contains: ["SCAN run", "SEARCH g USING PRIMARY KEY (node_id=? AND snap_id=?)"], scans: ["run"]),
        "fullForwardInsert": Rule(
            contains: ["SCAN g", "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)"], scans: ["g"]),
        "fullReverseFreeze": Rule(
            contains: ["SCAN run", "SEARCH g USING PRIMARY KEY (node_id=? AND snap_id=?)"], scans: ["run"]),
        "fullReverseInsert": Rule(
            contains: ["SCAN g", "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq=?)"], scans: ["g"]),
        // 3.43.2 runs a WHERE clause's EXISTS as a CORRELATED SCALAR
        // SUBQUERY over `SEARCH snap USING …`; 3.54.0's EXISTS-to-JOIN
        // optimization makes it a join it prints `SEARCH snap EXISTS USING
        // …`. Either way one snap_cover probe per outer row that stops at
        // the first match. The fragment starts after the word so both
        // versions match.
        "pendingChains": Rule(
            contains: [
                "SCAN chain USING COVERING INDEX sqlite_autoindex_chain_1",
                "USING COVERING INDEX snap_cover (chain_id=? AND state=?)",
            ],
            scans: ["chain"]),
        "pendingDesc": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=?)"], excludes: ["TEMP B-TREE"]),
        "lowestPendingAbove": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq>?)"], excludes: ["TEMP B-TREE"]),
        "highestPendingBelow": Rule(
            contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq<?)"], excludes: ["TEMP B-TREE"]),
        "windowEnd": Rule(contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq=?)"]),
        "pendingBetween": Rule(
            contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)"],
            scans: ["CONSTANT"]),
        "hkChains": Rule(contains: ["SCAN hk_pending"], scans: ["hk_pending"]),
        "hkSeqs": Rule(contains: ["SEARCH hk_pending USING PRIMARY KEY (chain_id=?)"]),
        "hkDone": Rule(contains: ["SEARCH hk_pending USING PRIMARY KEY (chain_id=?)"]),
        "hkChainHasSnap": Rule(
            contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=?)"], scans: ["CONSTANT"]),
        "hkChainDelete": Rule(contains: ["SEARCH chain USING INTEGER PRIMARY KEY (rowid=?)"]),
        "hkAliveBelow": Rule(contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq<?)"]),
        "hkAliveAbove": Rule(contains: ["SEARCH snap USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>?)"]),
        // 3.43.2 reads run_closed as COVERING here, 3.51.0 not: the
        // fragment omits the word so both versions match.
        "hkBottom": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq<?)"]),
        "hkGap": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        "hkTop": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        // Each housekeeping delete's fill reads exactly its runs: the same
        // partial index (both libraries plan it COVERING), and for a whole
        // chain's death the one scan of `run` — after which the delete finds
        // the chain's runs by the ids the fill queued, scanning nothing.
        "hkBottomNodes": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq<?)"]),
        "hkGapNodes": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        "hkTopNodes": Rule(contains: ["INDEX run_closed (chain_id=? AND last_seq>? AND last_seq<?)"]),
        "hkOrphanChainNodes": Rule(contains: ["SCAN run"], scans: ["run"]),
        "hkOrphanChainRuns": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=?)"]),
        // The content marks a death strands, by seq within the chain: the
        // edits through their chain index, the blinds by their key.
        "hkEditsUpTo": Rule(contains: ["INDEX edit_chain (chain_id=? AND seq<?)"]),
        "hkEditsAbove": Rule(contains: ["INDEX edit_chain (chain_id=? AND seq>?)"]),
        "hkBlindsUpTo": Rule(contains: ["SEARCH blind USING PRIMARY KEY (chain_id=? AND seq<?)"]),
        "hkBlindsAbove": Rule(contains: ["SEARCH blind USING PRIMARY KEY (chain_id=? AND seq>?)"]),
        "gcClear": Rule(contains: []),
        "gcInsert": Rule(contains: []),
        "gcKeepCollectable": Rule(
            contains: [
                "SCAN temp.gc",
                "SEARCH run USING PRIMARY KEY (node_id=?)",
                "SEARCH node USING COVERING INDEX sqlite_autoindex_node_1 (parent=?)",
                "SEARCH temp.stage USING PRIMARY KEY (node_id=?)",
            ],
            scans: ["temp.gc"]),
        "gcParents": Rule(contains: ["SCAN g", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["g"]),
        "gcDeleteFTS": Rule(contains: ["SCAN g", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["g"]),
        "gcDeleteEdits": Rule(contains: ["SEARCH edit USING PRIMARY KEY (node_id=?)"]),
        "gcDeleteNodes": Rule(contains: ["SEARCH node USING INTEGER PRIMARY KEY (rowid=?)"]),
        "versionsTimed": Rule(contains: byPrimaryKeyVersions + ["USE TEMP B-TREE FOR ORDER BY"]),
        "versionsInChain": Rule(contains: [
            "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)",
            "SCALAR SUBQUERY",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
            "SEARCH s USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
        ]),
        "summaryCounts": Rule(contains: byPrimaryKeyVersions, excludes: ["TEMP B-TREE"]),
        "summaryNewest": Rule(contains: byPrimaryKeyVersions + ["USE TEMP B-TREE FOR ORDER BY"]),
        "containsKind": Rule(contains: ["SEARCH run USING PRIMARY KEY (node_id=? AND chain_id=? AND first_seq<?)"]),
        // The EXISTS as pendingChains': one probe per run.
        "aliveRuns": Rule(contains: [
            "SEARCH r USING PRIMARY KEY (node_id=?)",
            "USING COVERING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
        ]),
        "newestCover": Rule(contains: ["SEARCH snap USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)"]),
        // One folder's children: the (parent, name) index in name order —
        // the GROUP BY's own order, so no sort — then each child's runs in
        // the chain and the indexed snapshots they cover.
        "childrenInChain": Rule(
            contains: [
                "SEARCH n USING COVERING INDEX sqlite_autoindex_node_1 (parent=?)",
                "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)",
                "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
                "SEARCH s USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
            ],
            excludes: ["TEMP B-TREE"]),
        // versionsInChain's route, its extra columns read off the same rows.
        "heldInChain": Rule(contains: [
            "SEARCH r USING PRIMARY KEY (node_id=? AND chain_id=?)",
            "SCALAR SUBQUERY",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
            "SEARCH s USING INDEX snap_cover (chain_id=? AND state=? AND seq>? AND seq<?)",
        ]),
        "editSeqs": Rule(contains: [
            "SEARCH edit USING PRIMARY KEY (node_id=? AND chain_id=?)",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
        ]),
        "blindSeqs": Rule(contains: [
            "SEARCH blind USING PRIMARY KEY (chain_id=? AND seq>? AND seq<?)",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
        ]),
        // The chain's indexed snapshots, sorted by time: one chain's
        // listing, not the repository's.
        "chainNewestIndexed": Rule(contains: [
            "SEARCH snap USING INDEX snap_cover (chain_id=? AND state=?)",
            "SEARCH chain USING COVERING INDEX sqlite_autoindex_chain_1 (key=?)",
        ]),
        "searchFTS": Rule(
            contains: ["SCAN f VIRTUAL TABLE INDEX 0:M1", "SEARCH n USING INTEGER PRIMARY KEY (rowid=?)"], scans: ["f"]),
        // `listing_applied` holds one row at most (its CHECK), so its scan
        // is one row. The inner EXISTS as pendingChains'.
        "notComplete": Rule(
            contains: [
                "SCAN listing_applied",
                "SCAN chain USING COVERING INDEX sqlite_autoindex_chain_1",
                "USING COVERING INDEX snap_cover (chain_id=? AND state=?)",
            ],
            scans: ["listing_applied", "chain", "CONSTANT"]),
        "cacheOwnerPut": Rule(contains: []),
        "cacheListingPut": Rule(contains: []),
        "cacheDiffPut": Rule(contains: []),
        "cacheFileNodePut": Rule(contains: []),
        "cacheListingGet": Rule(contains: [
            "SEARCH dir_listing USING INDEX sqlite_autoindex_dir_listing_1 (snapshot_id=? AND dir_path=?)",
        ]),
        "cacheDiffGet": Rule(contains: [
            "SEARCH diff_result USING INDEX sqlite_autoindex_diff_result_1 (older_id=? AND newer_id=?)",
        ]),
        "cacheFileNodeGet": Rule(contains: ["SEARCH file_node USING PRIMARY KEY (snapshot_id=? AND path=?)"]),
        "cacheSweepIDs": Rule(
            contains: ["SCAN o", "SEARCH s USING COVERING INDEX sqlite_autoindex_snap_1 (hash=?)"], scans: ["o"]),
        "cacheSweepListing": Rule(contains: ["INDEX sqlite_autoindex_dir_listing_1 (snapshot_id=?)"]),
        "cacheSweepDiffOlder": Rule(contains: ["INDEX sqlite_autoindex_diff_result_1 (older_id=?)"]),
        "cacheSweepDiffNewer": Rule(contains: ["INDEX diff_result_newer (newer_id=?)"]),
        "cacheSweepFileNode": Rule(contains: ["SEARCH file_node USING PRIMARY KEY (snapshot_id=?)"]),
        "cacheSweepOwner": Rule(contains: ["SEARCH cache_owner USING PRIMARY KEY (snapshot_id=?)"]),
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
    static func seededDatabase(_ fixture: IndexFixture) async throws -> DatabaseQueue {
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
        try await index.recordListing(snapshotID: survivors[0].id, directory: "/a", nodes: [])
        try await index.recordDiff(olderID: survivors[0].id, newerID: survivors[1].id, changes: [])
        try await index.recordFileNodes(["/a/d0/f1": [survivors[0].id: IndexTestData.cachedNode("/a/d0/f1")]])
        _ = try index.reconcile(listing: survivors + [try IndexTestData.snapshot(
            IndexTestData.hexID(999), micros: 999_000_000, tags: [IndexTestData.planA], paths: ["/a"])])
        try index.markUnreadable(snapshotID: IndexTestData.hexID(999))
        try index.close()

        let queue = try DatabaseQueue(path: fixture.path, configuration: SnapshotIndex.configuration())
        try await queue.writeWithoutTransaction { try $0.execute(sql: SnapshotIndexSchema.temporary) }
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
        let unread = SnapshotIndex.reflectStatements(
            SnapshotIndexSchema.SQL.statements, inList: SnapshotIndexSchema.SQL.placeholders(1)).others
        #expect(unread.isEmpty, "stored properties that are not statements: \(unread)")
        #expect(Set(names) == Set(Self.rules.keys), "unruled: \(Set(names).subtracting(Self.rules.keys).sorted()) stale: \(Set(Self.rules.keys).subtracting(names).sorted())")
        for (name, sql) in SnapshotIndex.registeredStatements {
            #expect(sql.range(of: #"\?\d"#, options: .regularExpression) == nil, "\(name) numbers its parameters")
        }
    }

    /// The registry is read by reflection, so what it holds must be the
    /// statements the store runs, text for text — a plain one and an IN
    /// list at `lookupChunk` placeholders.
    @Test("the registry holds the statements' own text")
    func registryReadsTheStatements() throws {
        typealias SQL = SnapshotIndexSchema.SQL
        let registered = Dictionary(uniqueKeysWithValues: SnapshotIndex.registeredStatements.map { ($0.name, $0.sql) })
        #expect(registered["nodeLookup"] == SQL.nodeLookup)
        let summaryCounts = try #require(registered["summaryCounts"])
        #expect(summaryCounts == SQL.summaryCounts(placeholders: SQL.placeholders(SnapshotIndex.lookupChunk)))
        #expect(summaryCounts.filter { $0 == "?" }.count == SnapshotIndex.lookupChunk)
        let containsKind = try #require(registered["containsKind"])
        #expect(containsKind.filter { $0 == "?" }.count == SnapshotIndex.lookupChunk + 3)
    }

    /// The reader on a stand-in: a new stored statement is registered by
    /// being declared, with no list to edit, and a stored property it
    /// cannot take for a statement is reported rather than dropped — a
    /// dropped one would be a statement nobody pins.
    @Test("the registry's reader takes every stored statement and reports anything else")
    func registryReaderTakesStoredStatements() {
        struct StandIn {
            let plain = "SELECT 1"
            let inList = SnapshotIndexSchema.InList { placeholders in "SELECT 2 WHERE x IN (\(placeholders))" }
            let stray = 7
        }
        let read = SnapshotIndex.reflectStatements(StandIn(), inList: "?, ?")
        #expect(read.statements.map(\.name) == ["plain", "inList"])
        #expect(read.statements.map(\.sql) == ["SELECT 1", "SELECT 2 WHERE x IN (?, ?)"])
        #expect(read.others == ["stray"])
    }

    @Test("every statement plans as pinned, and nothing scans a table its rule does not allow")
    func plansArePinned() async throws {
        let fixture = try IndexFixture()
        let queue = try await Self.seededDatabase(fixture)
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
    func checkerCatchesAScan() async throws {
        let fixture = try IndexFixture()
        let queue = try await Self.seededDatabase(fixture)
        defer { try? queue.close() }
        // hkGap with the literal `last_seq < 2147483647` bound instead: the
        // planner can no longer prove the partial index applies.
        let bare = """
            DELETE FROM run WHERE chain_id = ? AND last_seq > ? AND last_seq < ? AND last_seq < ?
                AND first_seq > ?
            RETURNING node_id
            """
        let plan = try queue.inDatabase { try Self.plan($0, bare) }
        let rule = try #require(Self.rules["hkGap"])
        #expect(plan.contains("SCAN run"), "\(plan)")
        #expect(!Self.problems(plan, rule).isEmpty)
    }
}
