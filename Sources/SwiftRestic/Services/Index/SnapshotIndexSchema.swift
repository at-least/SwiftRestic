import Foundation

/// The snapshot index's schema and every statement it runs, as SQL text.
///
/// One place to review the whole contract: `SnapshotIndex` never spells SQL
/// inline, so `SnapshotIndex.registeredStatements` can name every statement
/// the plan tests must pin. (Swift constants rather than resource files:
/// these sources compile into both the app and the test target, whose bundle
/// roots differ, and constants need no bundle plumbing.)
///
/// The model the SQL encodes, in one paragraph — the invariants behind it are
/// on `SnapshotIndex`. A chain is one lineage of snapshots with a per-chain
/// arrival ordinal `seq` that is never reused. Each chain has one contiguous
/// window `[lo, hi]` of indexed seqs. A run `(node, chain, first_seq,
/// last_seq, is_dir)` asserts that the path exists, with that kind, in every
/// *indexed* snapshot of the chain whose seq lies in the closed interval, and
/// the two sentinels make a window move cost only the change: `first_seq = 0`
/// reads "from lo", `last_seq = 2147483647` reads "through hi". A snapshot
/// that leaves the listing loses its row, so runs over its seq simply claim
/// nothing there; every read is the interval test plus `state = 1`.
///
/// There is no migrator: the index is a rebuildable cache that has never
/// shipped, so a file with any other `user_version` is deleted and rebuilt.
enum SnapshotIndexSchema {
    /// The whole creation script, run once in one transaction on a file whose
    /// `sqlite_schema` is empty. Every feature here exists in SQLite 3.43.2
    /// (macOS 15): STRICT, WITHOUT ROWID, AUTOINCREMENT, partial indexes,
    /// RETURNING, UPSERT and FTS5 external content.
    static let create = """
    -- One lineage of snapshots. key: the plan tag 'swiftrestic-plan-<uuid>'; for an untagged
    -- snapshot 'lineage:' followed by the JSON array [hostname, byte-sorted paths...]
    -- (restic's default host+paths grouping). JSON, not NUL separators: GRDB binds text
    -- NUL-terminated, so a separator byte of 0 would cut every such key to 'lineage'.
    CREATE TABLE chain (
        id        INTEGER PRIMARY KEY,
        key       TEXT    NOT NULL UNIQUE,
        next_seq  INTEGER NOT NULL DEFAULT 1,   -- only grows; the row is deleted only with all its runs
        lo        INTEGER,                      -- window bottom seq; NULL until the first ingest
        hi        INTEGER                       -- window top seq; NULL iff lo IS NULL; moves only on ingest
    ) STRICT;

    -- One snapshot of the latest applied listing. There are no dead rows: a snapshot that
    -- leaves the listing has its row deleted (its seq is never reused, so runs over it claim nothing).
    CREATE TABLE snap (
        id        INTEGER PRIMARY KEY AUTOINCREMENT, -- never reused: stream identity, arrival tiebreak
        hash      TEXT    NOT NULL UNIQUE,           -- restic's 64-hex id
        chain_id  INTEGER NOT NULL,
        seq       INTEGER NOT NULL,                  -- per-chain arrival ordinal (chain.next_seq)
        time      INTEGER NOT NULL,                  -- snapshot time, microseconds since 1970
        state     INTEGER NOT NULL DEFAULT 0         -- 0 pending, 1 indexed, 2 unreadable
    ) STRICT;
    CREATE INDEX snap_cover ON snap (chain_id, state, seq);   -- every planner, read and housekeeping probe

    -- One row once any listing has been applied to this file. Until then the index has read nothing
    -- of the repository (a fresh or rebuilt file, a repository never refreshed) and must not read as
    -- complete, though no snapshot is pending: without it, that file and an empty repository look alike.
    CREATE TABLE listing_applied (
        id  INTEGER PRIMARY KEY CHECK (id = 1)
    ) STRICT;

    -- The path dictionary: one row per path component. id 1 is '/', permanent.
    CREATE TABLE node (
        id      INTEGER PRIMARY KEY,
        parent  INTEGER NOT NULL,                -- 0 only for the root
        name    TEXT    NOT NULL,                -- one component, restic's bytes (BINARY collation)
        UNIQUE (parent, name)
    ) STRICT;
    INSERT INTO node (id, parent, name) VALUES (1, 0, '');
    -- External-content FTS over node.name. A row is written for every node in the transaction
    -- that creates it and deleted with the node, by its immutable name. The root has none.
    CREATE VIRTUAL TABLE node_fts USING fts5(name, content='node', content_rowid='id');

    -- One existence episode, per kind, of a path in a chain: a closed seq interval.
    CREATE TABLE run (
        node_id    INTEGER NOT NULL,
        chain_id   INTEGER NOT NULL,
        first_seq  INTEGER NOT NULL,             -- 0 = BOTTOM: "from lo"
        last_seq   INTEGER NOT NULL,             -- 2147483647 = TOP: "through hi"
        is_dir     INTEGER NOT NULL,             -- kind in every indexed snapshot the run claims
        PRIMARY KEY (node_id, chain_id, first_seq)
    ) STRICT, WITHOUT ROWID;
    -- Closed runs only: the ones housekeeping may delete. Every statement that wants it
    -- restates the literal predicate (a bound parameter proves nothing to the planner).
    CREATE INDEX run_closed ON run (chain_id, last_seq) WHERE last_seq < 2147483647;

    -- Housekeeping queue: seqs whose death may have left closed runs that claim nothing.
    CREATE TABLE hk_pending (
        chain_id  INTEGER NOT NULL,
        seq       INTEGER NOT NULL,
        PRIMARY KEY (chain_id, seq)
    ) STRICT, WITHOUT ROWID;

    -- Browse caches: verbatim restic answers keyed by immutable snapshot IDs. No foreign key:
    -- rows for IDs never reconciled must be accepted; they are swept at the next reconcile.
    CREATE TABLE dir_listing (
        snapshot_id  TEXT NOT NULL,
        dir_path     TEXT NOT NULL,              -- canonical: ResticService.normalize
        nodes        TEXT NOT NULL,              -- JSON [CachedListingNode]; '[]' is a hit
        PRIMARY KEY (snapshot_id, dir_path)
    ) STRICT;
    CREATE TABLE diff_result (
        older_id  TEXT NOT NULL,
        newer_id  TEXT NOT NULL,
        changes   TEXT NOT NULL,                 -- JSON [CachedDiffChange], complete uncapped walks only
        PRIMARY KEY (older_id, newer_id)
    ) STRICT;
    CREATE INDEX diff_result_newer ON diff_result (newer_id);
    -- Every snapshot ID that has any cache row: makes the sweep keyed, not a table scan.
    CREATE TABLE cache_owner (
        snapshot_id  TEXT PRIMARY KEY
    ) STRICT, WITHOUT ROWID;

    PRAGMA user_version = 2;
    """

    /// Created on the pool's writer connection when the store opens. TEMP
    /// tables never enter the WAL and vanish with the connection — which is
    /// the point for all three: a reopen ends any stream (`stage`), forgets
    /// the process's tombstones (`gone`), and `gc` is scratch.
    static let temporary = """
    -- The one open full-listing stream: one snapshot's rows at a time (beginFull clears it
    -- before its session stages anything). Keyed node-first so GC can ask "is it staged?".
    CREATE TEMP TABLE IF NOT EXISTS stage (
        node_id  INTEGER NOT NULL,
        snap_id  INTEGER NOT NULL,
        is_dir   INTEGER NOT NULL,
        PRIMARY KEY (node_id, snap_id)
    ) WITHOUT ROWID;
    -- Tombstones: hashes of rows deleted during this process, read only for ReconcileOutcome.revived.
    CREATE TEMP TABLE IF NOT EXISTS gone (hash TEXT PRIMARY KEY) WITHOUT ROWID;
    -- Scratch list of node ids for one GC level.
    CREATE TEMP TABLE IF NOT EXISTS gc (id INTEGER PRIMARY KEY);
    """

    /// Every statement the store runs. Names are the ones FINAL.md's plan
    /// table uses. Parameters are plain `?` throughout, so a statement's
    /// argument count is its number of question marks — the plan tests bind
    /// that many NULLs.
    ///
    /// Two literals are load-bearing and must never become parameters:
    /// `2147483647` in every `last_seq` predicate that wants `run_closed`
    /// (the planner uses a partial index only when the query restates its
    /// WHERE term verbatim), and the state values in the planner statements
    /// that `snap_cover` covers.
    enum SQL {
        // MARK: Nodes
        static let nodeLookup = "SELECT id FROM node WHERE parent = ? AND name = ?"
        /// Yields to an existing row: a caller that skipped the lookup (a
        /// child of a directory it just created) then looks the node up.
        static let nodeInsert =
            "INSERT INTO node (parent, name) VALUES (?, ?) ON CONFLICT (parent, name) DO NOTHING RETURNING id"
        static let nodeMaxID = "SELECT COALESCE(MAX(id), 0) FROM node"
        static let nodeByID = "SELECT parent, name FROM node WHERE id = ?"
        /// One statement indexes every node the transaction created: `?` is
        /// the largest node id before its first insert.
        static let nodeFTSIndexNew = "INSERT INTO node_fts (rowid, name) SELECT id, name FROM node WHERE id > ?"

        // MARK: Snapshots and chains
        static let snapAll = "SELECT id, hash, chain_id, seq FROM snap"
        static let snapByHash = "SELECT id, chain_id, seq, state FROM snap WHERE hash = ?"
        static let snapDelete = "DELETE FROM snap WHERE id = ?"
        static let snapInsert = "INSERT INTO snap (hash, chain_id, seq, time, state) VALUES (?, ?, ?, ?, 0)"
        static let snapMarkIndexed = "UPDATE snap SET state = 1 WHERE id = ?"
        static let snapMarkUnreadable = "UPDATE snap SET state = 2 WHERE id = ?"
        static let snapRepend = "UPDATE snap SET state = 0, seq = ? WHERE id = ? RETURNING hash"
        static let chainInsert = "INSERT INTO chain (key) VALUES (?) ON CONFLICT (key) DO NOTHING"
        static let chainByKey = "SELECT id, next_seq FROM chain WHERE key = ?"
        static let chainNextSeq = "UPDATE chain SET next_seq = ? WHERE id = ?"
        /// One fresh seq for the chain: `next_seq` before the increment.
        static let chainTakeSeq = "UPDATE chain SET next_seq = next_seq + 1 WHERE id = ? RETURNING next_seq - 1"
        static let chainByID = "SELECT lo, hi FROM chain WHERE id = ?"
        static let chainSetWindow = "UPDATE chain SET lo = ?, hi = ? WHERE id = ?"
        static let goneInsert = "INSERT OR IGNORE INTO temp.gone (hash) VALUES (?)"
        static let goneDelete = "DELETE FROM temp.gone WHERE hash = ?"
        static let hkEnqueue = "INSERT OR IGNORE INTO hk_pending (chain_id, seq) VALUES (?, ?)"
        static let listingMarkApplied = "INSERT INTO listing_applied (id) VALUES (1) ON CONFLICT DO NOTHING"
        static let unreadableList = "SELECT id, chain_id, seq FROM snap WHERE state = 2"

        // MARK: Forward delta (target above hi, base = the alive hi snapshot)
        static let forwardClose =
            "UPDATE run SET last_seq = ? WHERE node_id = ? AND chain_id = ? AND last_seq = 2147483647"
        static let forwardOpenRun =
            "SELECT is_dir FROM run WHERE node_id = ? AND chain_id = ? AND last_seq = 2147483647"
        static let forwardInsert =
            "INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir) VALUES (?, ?, ?, 2147483647, ?)"

        // MARK: Reverse delta (target below lo, base = the alive lo snapshot)
        static let reverseFreeze =
            "UPDATE run SET first_seq = ? WHERE node_id = ? AND chain_id = ? AND first_seq = 0"
        static let reverseBottomRun =
            "SELECT is_dir FROM run WHERE node_id = ? AND chain_id = ? AND first_seq = 0"
        static let reverseInsert =
            "INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir) VALUES (?, ?, 0, ?, ?)"

        // MARK: Full ingest: a staged `restic ls` compared with the sentinel-ended runs
        static let stageInsert = "INSERT OR IGNORE INTO temp.stage (node_id, snap_id, is_dir) VALUES (?, ?, ?)"
        static let stageClear = "DELETE FROM temp.stage"
        /// Whose stream the stage holds: one snapshot's rows at most, so the
        /// first row answers. `LIMIT 1` is what keeps the scan to one row.
        static let stageOwner = "SELECT snap_id FROM temp.stage LIMIT 1"
        static let stageRunless = """
            SELECT DISTINCT st.node_id FROM temp.stage st
            WHERE NOT EXISTS (SELECT 1 FROM run r WHERE r.node_id = st.node_id)
            """
        static let fullFirstInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT node_id, ?, 0, 2147483647, is_dir FROM temp.stage WHERE snap_id = ?
            """
        static let fullForwardClose = """
            UPDATE run SET last_seq = ? WHERE chain_id = ? AND last_seq = 2147483647
                AND NOT EXISTS (SELECT 1 FROM temp.stage g
                    WHERE g.node_id = run.node_id AND g.snap_id = ? AND g.is_dir = run.is_dir)
            """
        static let fullForwardInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT g.node_id, ?, ?, 2147483647, g.is_dir FROM temp.stage g
            WHERE g.snap_id = ? AND NOT EXISTS (SELECT 1 FROM run r
                WHERE r.node_id = g.node_id AND r.chain_id = ? AND r.last_seq = 2147483647 AND r.is_dir = g.is_dir)
            """
        static let fullReverseFreeze = """
            UPDATE run SET first_seq = ? WHERE chain_id = ? AND first_seq = 0
                AND NOT EXISTS (SELECT 1 FROM temp.stage g
                    WHERE g.node_id = run.node_id AND g.snap_id = ? AND g.is_dir = run.is_dir)
            """
        static let fullReverseInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT g.node_id, ?, 0, ?, g.is_dir FROM temp.stage g
            WHERE g.snap_id = ? AND NOT EXISTS (SELECT 1 FROM run r
                WHERE r.node_id = g.node_id AND r.chain_id = ? AND r.first_seq = 0 AND r.is_dir = g.is_dir)
            """

        // MARK: Planner (state 0 only: unreadable snapshots are passed over)
        static let pendingChains = """
            SELECT id FROM chain
            WHERE EXISTS (SELECT 1 FROM snap WHERE snap.chain_id = chain.id AND snap.state = 0)
            """
        static let pendingDesc = "SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 ORDER BY seq DESC"
        static let lowestPendingAbove = """
            SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 AND seq > ? ORDER BY seq LIMIT 1
            """
        static let highestPendingBelow = """
            SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 AND seq < ? ORDER BY seq DESC LIMIT 1
            """
        static let windowEnd = "SELECT hash FROM snap WHERE chain_id = ? AND state = 1 AND seq = ?"
        static let pendingBetween = """
            SELECT EXISTS (SELECT 1 FROM snap WHERE chain_id = ? AND state = 0 AND seq > ? AND seq < ?)
            """

        // MARK: Housekeeping: only queued chains, only the gaps around queued seqs
        static let hkChains = "SELECT DISTINCT chain_id FROM hk_pending"
        static let hkSeqs = "SELECT seq FROM hk_pending WHERE chain_id = ? ORDER BY seq"
        static let hkDone = "DELETE FROM hk_pending WHERE chain_id = ?"
        static let hkChainHasSnap = "SELECT EXISTS (SELECT 1 FROM snap WHERE chain_id = ?)"
        static let hkChainDelete = "DELETE FROM chain WHERE id = ?"
        static let hkAliveBelow = """
            SELECT seq FROM snap WHERE chain_id = ? AND state = 1 AND seq < ? ORDER BY seq DESC LIMIT 1
            """
        static let hkAliveAbove = """
            SELECT seq FROM snap WHERE chain_id = ? AND state = 1 AND seq > ? ORDER BY seq LIMIT 1
            """
        static let hkBottom = """
            DELETE FROM run WHERE chain_id = ? AND last_seq < ? AND last_seq < 2147483647
            RETURNING node_id
            """
        static let hkGap = """
            DELETE FROM run WHERE chain_id = ? AND last_seq > ? AND last_seq < ? AND last_seq < 2147483647
                AND first_seq > ?
            RETURNING node_id
            """
        static let hkTop = """
            DELETE FROM run WHERE chain_id = ? AND last_seq > ? AND last_seq < 2147483647 AND first_seq > ?
            RETURNING node_id
            """
        static let hkOrphanChainRuns = "DELETE FROM run WHERE chain_id = ? RETURNING node_id"

        // MARK: Node GC, one level at a time over temp.gc
        static let gcClear = "DELETE FROM temp.gc"
        static let gcInsert = "INSERT OR IGNORE INTO temp.gc (id) VALUES (?)"
        static let gcKeepCollectable = """
            DELETE FROM temp.gc WHERE id NOT IN (SELECT id FROM node)
                OR EXISTS (SELECT 1 FROM run WHERE run.node_id = gc.id)
                OR EXISTS (SELECT 1 FROM node WHERE node.parent = gc.id)
                OR EXISTS (SELECT 1 FROM temp.stage WHERE stage.node_id = gc.id)
            """
        static let gcParents = "SELECT n.parent FROM temp.gc g JOIN node n ON n.id = g.id"
        static let gcDeleteFTS = """
            INSERT INTO node_fts (node_fts, rowid, name)
            SELECT 'delete', n.id, n.name FROM temp.gc g JOIN node n ON n.id = g.id
            """
        static let gcDeleteNodes = "DELETE FROM node WHERE id IN (SELECT id FROM temp.gc)"

        // MARK: Reads
        static let versionsTimed = """
            SELECT s.hash, s.time FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ?
            ORDER BY s.time DESC, s.id DESC
            """
        static let versionsInChain = """
            SELECT s.hash, s.time FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ? AND r.chain_id = (SELECT id FROM chain WHERE key = ?)
            ORDER BY s.time DESC, s.id DESC
            """
        static func summaryCounts(placeholders: String) -> String {
            """
            SELECT r.node_id, count(*), max(s.time) FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id IN (\(placeholders))
            GROUP BY r.node_id
            """
        }
        static let summaryNewest = """
            SELECT s.hash FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ? AND s.time = ?
            ORDER BY s.id DESC LIMIT 1
            """
        static func containsKind(placeholders: String) -> String {
            """
            SELECT node_id, is_dir FROM run
            WHERE node_id IN (\(placeholders)) AND chain_id = ? AND first_seq <= ? AND last_seq >= ?
            """
        }
        static let aliveRuns = """
            SELECT r.chain_id, r.first_seq, r.last_seq, r.is_dir FROM run r
            WHERE r.node_id = ? AND EXISTS (SELECT 1 FROM snap s
                WHERE s.chain_id = r.chain_id AND s.state = 1 AND s.seq BETWEEN r.first_seq AND r.last_seq)
            """
        static let newestCover = """
            SELECT time, id FROM snap
            WHERE chain_id = ? AND state = 1 AND seq BETWEEN ? AND ?
            ORDER BY time DESC, id DESC LIMIT 1
            """
        static let searchFTS = """
            SELECT n.id, n.name FROM node_fts f JOIN node n ON n.id = f.rowid
            WHERE node_fts MATCH ? ORDER BY n.name
            """
        /// A file no listing has reached knows nothing, so it is incomplete
        /// whatever its (empty) tables say. Past that, chain-driven, one
        /// `snap_cover` probe per chain and state: a snapshot still to read,
        /// or one set aside as unreadable, keeps the index incomplete.
        static let notComplete = """
            SELECT NOT EXISTS (SELECT 1 FROM listing_applied)
                OR EXISTS (SELECT 1 FROM chain
                    WHERE EXISTS (SELECT 1 FROM snap WHERE snap.chain_id = chain.id AND snap.state IN (0, 2)))
            """

        // MARK: Browse caches
        static let cacheOwnerPut = "INSERT INTO cache_owner (snapshot_id) VALUES (?) ON CONFLICT DO NOTHING"
        static let cacheListingPut =
            "INSERT INTO dir_listing (snapshot_id, dir_path, nodes) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
        static let cacheDiffPut =
            "INSERT INTO diff_result (older_id, newer_id, changes) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
        static let cacheListingGet = "SELECT nodes FROM dir_listing WHERE snapshot_id = ? AND dir_path = ?"
        static let cacheDiffGet = "SELECT changes FROM diff_result WHERE older_id = ? AND newer_id = ?"
        /// Every snap row is a listed snapshot, so "no snap row" is "not
        /// listed" — forgotten, or never reconciled at all.
        static let cacheSweepIDs = """
            SELECT o.snapshot_id FROM cache_owner o
            WHERE NOT EXISTS (SELECT 1 FROM snap s WHERE s.hash = o.snapshot_id)
            """
        static let cacheSweepListing = "DELETE FROM dir_listing WHERE snapshot_id = ?"
        static let cacheSweepDiffOlder = "DELETE FROM diff_result WHERE older_id = ?"
        static let cacheSweepDiffNewer = "DELETE FROM diff_result WHERE newer_id = ?"
        static let cacheSweepOwner = "DELETE FROM cache_owner WHERE snapshot_id = ?"

        /// `count` comma-separated `?`s for an IN list.
        static func placeholders(_ count: Int) -> String {
            Array(repeating: "?", count: count).joined(separator: ", ")
        }
    }
}
