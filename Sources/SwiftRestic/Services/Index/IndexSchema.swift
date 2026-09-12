import Foundation

/// The index schema as versioned SQL text.
///
/// This file is the portable artifact of the index — the same discipline the
/// restic engine's seam keeps: the SQL is the contract, reviewable in one
/// place, and portable to any SQLite binding. (The SQL lives in Swift string
/// constants rather than resource files because these sources compile into
/// both the app and the test target, whose bundle roots differ; constants
/// need no bundle plumbing and version identically.)
///
/// Semantics the SQL alone cannot say:
/// - `seq` is a per-chain arrival ordinal, assigned at reconcile as
///   max+1 and never reassigned. New snapshots are newest, so seq follows
///   time in practice; a back-dated external snapshot would get a later seq
///   than its time suggests, and every interval consumer must read seq as
///   "chain position", never as time.
/// - A run `(path, chain, first_seq, last_seq)` asserts existence for every
///   *alive* snapshot of the chain with seq in the interval. Dead snapshots
///   keep their runs: revival is free, and queries filter `alive = 1`.
/// - Existence only. Size/mtime are deliberately not stored — `restic diff`
///   does not carry them, and guessing would poison the version list.
enum IndexSchema {
    static let v1 = """
    CREATE TABLE snapshot (
        id TEXT PRIMARY KEY,
        chain TEXT NOT NULL,
        seq INTEGER NOT NULL,
        time TEXT NOT NULL,
        alive INTEGER NOT NULL DEFAULT 1,
        indexed INTEGER NOT NULL DEFAULT 0,
        UNIQUE(chain, seq)
    );

    CREATE TABLE entry (
        path TEXT NOT NULL,
        chain TEXT NOT NULL,
        first_seq INTEGER NOT NULL,
        last_seq INTEGER NOT NULL,
        PRIMARY KEY (path, chain, first_seq)
    );

    CREATE INDEX entry_chain_last ON entry(chain, last_seq);
    CREATE INDEX snapshot_pending ON snapshot(alive, indexed, time);
    """

    /// The cross-snapshot search index: one row per distinct path ever seen,
    /// FTS5-indexed by basename. Deliberately a separate table from `entry` —
    /// runs are UPDATED on every backup, and an external-content FTS table
    /// fed by update triggers is the classic silent-drift trap. The search
    /// table only ever grows (INSERT OR IGNORE), so its FTS twin never needs
    /// a delete command and cannot drift. `is_dir` is nullable: rows rebuilt
    /// from a pre-v2 index have no kind on record.
    static let v2 = """
    CREATE TABLE search (
        path TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_dir INTEGER
    );

    CREATE VIRTUAL TABLE search_fts USING fts5(name, content='search', content_rowid='rowid');
    """
}
