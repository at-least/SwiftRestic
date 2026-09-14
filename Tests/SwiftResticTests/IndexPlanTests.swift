import GRDB
import Testing

// No `@testable import SwiftRestic`: the test target compiles the model
// layer's sources itself, so SQLiteIndexStore is already right here — and
// importing the app module adds a dependency a cold build cannot satisfy
// (CI's "no such module 'SwiftRestic'").

/// The planner routes behind `recordContent`'s chunk statements — the thing
/// a green functional test cannot see. Nothing in the app ever ANALYZEs, so
/// SQLite plans from its default cost model, and that model can route
/// boundary statements through `entry_chain_last`, whose seek visits every
/// run ending at the boundary instead of just the statement's paths (73 ms
/// vs 3 ms per chunk over 200k runs; the arithmetic is on the SQL builders).
/// The `+` guards pin the primary-key route; these tests pin the guards.
@Suite("index plan")
struct IndexPlanTests {
    /// The production schema through the production migrator, on an
    /// in-memory database holding the shape a fully indexed predecessor
    /// leaves behind: one chain whose 50k runs all end at one seq. Plan
    /// choice is statistics-independent, so the seed is for realism only —
    /// the stat1 assertion at the bottom is what keeps the test honest,
    /// because statistics are exactly what flip these plans.
    private func makeSeededDatabase() throws -> DatabaseQueue {
        let db = try DatabaseQueue(configuration: SQLiteIndexStore.configuration())
        try SQLiteIndexStore.migrator().migrate(db)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO snapshot (id, chain, seq, time, alive, indexed) VALUES ('s1', 'c', 4, 't', 1, 1)"
            )
            try db.execute(
                sql: """
                WITH RECURSIVE i(x) AS (
                    SELECT 1 UNION ALL SELECT x + 1 FROM i WHERE x < 50000
                )
                INSERT INTO entry
                SELECT '/seed/' || x || '/file', 'c', 4, 4 FROM i
                """
            )
        }
        return db
    }

    /// One chunk of two paths against the seeded runs — statement text and
    /// argument lists exactly as `recordContent` issues them.
    private func assertPrimaryKeyRoute(
        _ db: Database,
        sql: String,
        arguments: StatementArguments,
        label: String
    ) throws {
        let plan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
            .compactMap { $0["detail"] as String? }
            .joined(separator: "\n")
        #expect(plan.contains("sqlite_autoindex_entry_1"), "\(label) took no primary-key route: \(plan)")
        #expect(!plan.contains("entry_chain_last"), "\(label) took the chain-last route: \(plan)")
    }

    @Test("chunk statements drive the primary key, never entry_chain_last")
    func chunkStatementsUsePrimaryKeyPlan() throws {
        let db = try makeSeededDatabase()

        try db.read { db in
            try assertPrimaryKeyRoute(
                db,
                sql: SQLiteIndexStore.extendRunSQL(pathPlaceholders: "?, ?"),
                arguments: [5, "c", 4, "/a", "/b"],
                label: "extend"
            )
            // Unguarded on purpose — see reachBackSQL's doc comment.
            try assertPrimaryKeyRoute(
                db,
                sql: SQLiteIndexStore.reachBackSQL(pathPlaceholders: "?, ?"),
                arguments: [5, "c", 5, "/a", "/b"],
                label: "reach-back"
            )
            try assertPrimaryKeyRoute(
                db,
                sql: SQLiteIndexStore.seamSelectSQL(pathPlaceholders: "?, ?"),
                arguments: ["c", 5, 5, "/a", "/b"],
                label: "seam select"
            )
            try assertPrimaryKeyRoute(
                db,
                sql: SQLiteIndexStore.seamMergeSQL(),
                arguments: [5, "c", "/a", 4],
                label: "seam merge"
            )
            try assertPrimaryKeyRoute(
                db,
                sql: SQLiteIndexStore.seamDeleteSQL(),
                arguments: ["c", "/a", 4],
                label: "seam delete"
            )
        }

        let statTables = try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'sqlite_stat1'"
            )
        }
        #expect(statTables == 0)
    }
}
