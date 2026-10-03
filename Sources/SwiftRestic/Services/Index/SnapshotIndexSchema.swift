import Foundation

/// The snapshot index's schema and every statement it runs, as SQL text.
///
/// One place to review the whole contract: `SnapshotIndex` spells no
/// statement inline (the open-time schema probe, the connection pragmas and
/// the test-support invariant checks aside), and every statement here is a
/// stored property of `Statements`, so `SnapshotIndex.registeredStatements`
/// finds each one the plan tests must pin by reflection. (Swift values
/// rather than resource files: these sources compile into both the app and
/// the test target, whose bundle roots differ, and values need no bundle
/// plumbing.)
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
/// nothing there; every read is the interval test plus `state = 1`. Within a
/// run, an `edit` at seq `e` says the file's content changed between `e` and
/// the indexed snapshot below it, and a `blind` at `e` that no diff compared
/// that pair; two indexed snapshots one run covers hold the same content
/// unless an edit or blind lies above the lower and at or below the upper.
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

    -- A file's content changed between two neighbouring indexed snapshots of a chain, as the
    -- `restic diff` that compared them said (M): recorded at the upper seq of the pair, the
    -- snapshot whose content differs from the indexed one below it at the time. Existence
    -- changes are the runs'; these split one run into the versions a browser shows.
    CREATE TABLE edit (
        node_id   INTEGER NOT NULL,
        chain_id  INTEGER NOT NULL,
        seq       INTEGER NOT NULL,
        PRIMARY KEY (node_id, chain_id, seq)
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX edit_chain ON edit (chain_id, seq);   -- housekeeping's sweeps by seq
    -- A window step a full read took beside an indexed neighbour: no diff compared the pair,
    -- so any path's content may differ across it. At the pair's upper seq, as an edit is.
    CREATE TABLE blind (
        chain_id  INTEGER NOT NULL,
        seq       INTEGER NOT NULL,
        PRIMARY KEY (chain_id, seq)
    ) STRICT, WITHOUT ROWID;

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
        dir_path     TEXT NOT NULL,              -- canonical: ResticPath.normalized
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

    PRAGMA user_version = 3;
    """

    /// Created on the pool's writer connection when the store opens. TEMP
    /// tables never enter the WAL and vanish with the connection — which is
    /// the point for both: a reopen ends any stream (`stage`), and `gc` is
    /// scratch.
    static let temporary = """
    -- The one open full-listing stream: one snapshot's rows at a time (beginFull clears it
    -- before its session stages anything). Keyed node-first so GC can ask "is it staged?".
    CREATE TEMP TABLE IF NOT EXISTS stage (
        node_id  INTEGER NOT NULL,
        snap_id  INTEGER NOT NULL,
        is_dir   INTEGER NOT NULL,
        PRIMARY KEY (node_id, snap_id)
    ) WITHOUT ROWID;
    -- Node ids queued for collection: housekeeping's and a discarded stage's fills queue the
    -- first level, collectNodes each next one, and it leaves the table empty.
    CREATE TEMP TABLE IF NOT EXISTS gc (id INTEGER PRIMARY KEY);
    """

    /// Every statement the store runs, one stored `let` each, named by its
    /// property: `SnapshotIndex.registeredStatements` lists them by
    /// reflecting over `SQL.statements`, and `SnapshotIndexPlanTests` pins
    /// each under the same name, so declaring a statement is registering it
    /// — there is no second list to forget. Reflection sees stored
    /// properties only: a statement written as a computed property, a
    /// method or a `static` member would escape the pins, so write none. A
    /// statement whose text depends on an IN list's length is an `InList`.
    /// The `private static` fragments below (the housekeeping pairs' shared
    /// FROM and WHERE, and the fill built from one) are pieces of
    /// statements, not statements: nothing runs them alone, and each
    /// statement built from them is a stored `let` the pins see whole.
    /// (FINAL.md's plan table predates this and spells the names dotted, and
    /// a name here is not always its dotted one without the dot: its
    /// `chain.byID` is `chainByID` here, but its `plan.lowestAbove` is
    /// `lowestPendingAbove`, its `fwd.close` `forwardClose` and its
    /// `q.summaryCounts` `summaryCounts`.)
    ///
    /// Parameters are plain `?` throughout, so a statement's argument count
    /// is its number of question marks — the plan tests bind that many
    /// NULLs.
    ///
    /// Two literals are load-bearing and must never become parameters:
    /// `2147483647` in every `last_seq` predicate that wants `run_closed`
    /// (the planner uses a partial index only when the query restates its
    /// WHERE term verbatim), and the state values in the planner statements
    /// that `snap_cover` covers.
    struct Statements: Sendable {
        // MARK: Nodes
        let nodeLookup = "SELECT id FROM node WHERE parent = ? AND name = ?"
        /// Yields to an existing row: a caller that skipped the lookup (a
        /// child of a directory it just created) then looks the node up.
        let nodeInsert =
            "INSERT INTO node (parent, name) VALUES (?, ?) ON CONFLICT (parent, name) DO NOTHING RETURNING id"
        let nodeMaxID = "SELECT COALESCE(MAX(id), 0) FROM node"
        let nodeByID = "SELECT parent, name FROM node WHERE id = ?"
        /// One statement indexes every node the transaction created: `?` is
        /// the largest node id before its first insert.
        let nodeFTSIndexNew = "INSERT INTO node_fts (rowid, name) SELECT id, name FROM node WHERE id > ?"

        // MARK: Snapshots and chains
        let snapAll = "SELECT id, hash, chain_id, seq FROM snap"
        let snapByHash = "SELECT id, chain_id, seq, state FROM snap WHERE hash = ?"
        let snapDelete = "DELETE FROM snap WHERE id = ?"
        let snapInsert = "INSERT INTO snap (hash, chain_id, seq, time, state) VALUES (?, ?, ?, ?, 0)"
        let snapMarkIndexed = "UPDATE snap SET state = 1 WHERE id = ?"
        let snapMarkUnreadable = "UPDATE snap SET state = 2 WHERE id = ?"
        let snapRepend = "UPDATE snap SET state = 0, seq = ? WHERE id = ? RETURNING hash"
        let chainInsert = "INSERT INTO chain (key) VALUES (?) ON CONFLICT (key) DO NOTHING"
        let chainByKey = "SELECT id, next_seq FROM chain WHERE key = ?"
        let chainNextSeq = "UPDATE chain SET next_seq = ? WHERE id = ?"
        /// One fresh seq for the chain: `next_seq` before the increment.
        let chainTakeSeq = "UPDATE chain SET next_seq = next_seq + 1 WHERE id = ? RETURNING next_seq - 1"
        let chainByID = "SELECT lo, hi FROM chain WHERE id = ?"
        let chainSetWindow = "UPDATE chain SET lo = ?, hi = ? WHERE id = ?"
        let hkEnqueue = "INSERT OR IGNORE INTO hk_pending (chain_id, seq) VALUES (?, ?)"
        let listingMarkApplied = "INSERT INTO listing_applied (id) VALUES (1) ON CONFLICT DO NOTHING"
        let unreadableList = "SELECT id, chain_id FROM snap WHERE state = 2"

        // MARK: Forward delta (target above hi, base = the alive hi snapshot)
        let forwardClose =
            "UPDATE run SET last_seq = ? WHERE node_id = ? AND chain_id = ? AND last_seq = 2147483647"
        let forwardOpenRun =
            "SELECT is_dir FROM run WHERE node_id = ? AND chain_id = ? AND last_seq = 2147483647"
        let forwardInsert =
            "INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir) VALUES (?, ?, ?, 2147483647, ?)"

        // MARK: Reverse delta (target below lo, base = the alive lo snapshot)
        let reverseFreeze =
            "UPDATE run SET first_seq = ? WHERE node_id = ? AND chain_id = ? AND first_seq = 0"
        let reverseBottomRun =
            "SELECT is_dir FROM run WHERE node_id = ? AND chain_id = ? AND first_seq = 0"
        let reverseInsert =
            "INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir) VALUES (?, ?, 0, ?, ?)"

        // MARK: Content changes (an edit per `M` a delta saw, a blind per full step)
        let editInsert = "INSERT OR IGNORE INTO edit (node_id, chain_id, seq) VALUES (?, ?, ?)"
        let blindInsert = "INSERT OR IGNORE INTO blind (chain_id, seq) VALUES (?, ?)"

        // MARK: Full ingest: a staged `restic ls` compared with the sentinel-ended runs
        let stageInsert = "INSERT OR IGNORE INTO temp.stage (node_id, snap_id, is_dir) VALUES (?, ?, ?)"
        let stageClear = "DELETE FROM temp.stage"
        /// Whose stream the stage holds: one snapshot's rows at most, so the
        /// first row answers. `LIMIT 1` is what keeps the scan to one row.
        let stageOwner = "SELECT snap_id FROM temp.stage LIMIT 1"
        /// The stage's nodes no run holds, queued in `temp.gc` for
        /// `discardStage` to collect once the stage is cleared. No
        /// `DISTINCT`: the queue's key and `OR IGNORE` deduplicate.
        let stageRunlessNodes = """
            INSERT OR IGNORE INTO temp.gc (id) SELECT st.node_id FROM temp.stage st
            WHERE NOT EXISTS (SELECT 1 FROM run r WHERE r.node_id = st.node_id)
            """
        let fullFirstInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT node_id, ?, 0, 2147483647, is_dir FROM temp.stage WHERE snap_id = ?
            """
        let fullForwardClose = """
            UPDATE run SET last_seq = ? WHERE chain_id = ? AND last_seq = 2147483647
                AND NOT EXISTS (SELECT 1 FROM temp.stage g
                    WHERE g.node_id = run.node_id AND g.snap_id = ? AND g.is_dir = run.is_dir)
            """
        let fullForwardInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT g.node_id, ?, ?, 2147483647, g.is_dir FROM temp.stage g
            WHERE g.snap_id = ? AND NOT EXISTS (SELECT 1 FROM run r
                WHERE r.node_id = g.node_id AND r.chain_id = ? AND r.last_seq = 2147483647 AND r.is_dir = g.is_dir)
            """
        let fullReverseFreeze = """
            UPDATE run SET first_seq = ? WHERE chain_id = ? AND first_seq = 0
                AND NOT EXISTS (SELECT 1 FROM temp.stage g
                    WHERE g.node_id = run.node_id AND g.snap_id = ? AND g.is_dir = run.is_dir)
            """
        let fullReverseInsert = """
            INSERT INTO run (node_id, chain_id, first_seq, last_seq, is_dir)
            SELECT g.node_id, ?, 0, ?, g.is_dir FROM temp.stage g
            WHERE g.snap_id = ? AND NOT EXISTS (SELECT 1 FROM run r
                WHERE r.node_id = g.node_id AND r.chain_id = ? AND r.first_seq = 0 AND r.is_dir = g.is_dir)
            """

        // MARK: Planner (state 0 only: unreadable snapshots are passed over)
        let pendingChains = """
            SELECT id FROM chain
            WHERE EXISTS (SELECT 1 FROM snap WHERE snap.chain_id = chain.id AND snap.state = 0)
            """
        let pendingDesc = "SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 ORDER BY seq DESC"
        let lowestPendingAbove = """
            SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 AND seq > ? ORDER BY seq LIMIT 1
            """
        let highestPendingBelow = """
            SELECT hash, time FROM snap WHERE chain_id = ? AND state = 0 AND seq < ? ORDER BY seq DESC LIMIT 1
            """
        let windowEnd = "SELECT hash FROM snap WHERE chain_id = ? AND state = 1 AND seq = ?"
        let pendingBetween = """
            SELECT EXISTS (SELECT 1 FROM snap WHERE chain_id = ? AND state = 0 AND seq > ? AND seq < ?)
            """

        // MARK: Housekeeping: only queued chains, only the gaps around queued seqs
        let hkChains = "SELECT DISTINCT chain_id FROM hk_pending"
        let hkSeqs = "SELECT seq FROM hk_pending WHERE chain_id = ? ORDER BY seq"
        let hkDone = "DELETE FROM hk_pending WHERE chain_id = ?"
        let hkChainHasSnap = "SELECT EXISTS (SELECT 1 FROM snap WHERE chain_id = ?)"
        let hkChainDelete = "DELETE FROM chain WHERE id = ?"
        let hkAliveBelow = """
            SELECT seq FROM snap WHERE chain_id = ? AND state = 1 AND seq < ? ORDER BY seq DESC LIMIT 1
            """
        let hkAliveAbove = """
            SELECT seq FROM snap WHERE chain_id = ? AND state = 1 AND seq > ? ORDER BY seq LIMIT 1
            """

        /// The runs each housekeeping delete removes, as the FROM clause and
        /// WHERE both of its statements share: the delete, and before it the
        /// fill that queues those runs' nodes in `temp.gc` for collection —
        /// in SQL, so a whole chain's death never carries its path population
        /// through Swift. One text per pair: the two can never disagree on
        /// which runs they mean.
        private static let bottomRuns = "run WHERE chain_id = ? AND last_seq < ? AND last_seq < 2147483647"
        private static let gapRuns = """
            run WHERE chain_id = ? AND last_seq > ? AND last_seq < ? AND last_seq < 2147483647
                AND first_seq > ?
            """
        private static let topRuns =
            "run WHERE chain_id = ? AND last_seq > ? AND last_seq < 2147483647 AND first_seq > ?"
        private static let orphanChainRuns = "run WHERE chain_id = ?"

        /// A pair's fill: the nodes of `runs`, queued for `collectNodes`.
        private static func queueNodes(of runs: String) -> String {
            "INSERT OR IGNORE INTO temp.gc (id) SELECT node_id FROM " + runs
        }

        let hkBottomNodes = Self.queueNodes(of: Self.bottomRuns)
        let hkGapNodes = Self.queueNodes(of: Self.gapRuns)
        let hkTopNodes = Self.queueNodes(of: Self.topRuns)
        let hkOrphanChainNodes = Self.queueNodes(of: Self.orphanChainRuns)

        /// `RETURNING` stays on the three range deletes though nothing reads
        /// its rows: it makes SQLite collect the keys before deleting (two
        /// passes — an `OpenEphemeral` in EXPLAIN) instead of deleting under
        /// its `run_closed` cursor, and SQLite 3.43.2, the floor, runs that
        /// about twice as fast: 86 against 175 ms for one 77.6k-run gap
        /// (3.51.0 is the other way round, 107 against 47, but with the fill
        /// in front neither library is slower than when Swift carried the
        /// ids: 105 against 114 ms on 3.43.2, 131 against 147 on 3.51.0).
        let hkBottom = "DELETE FROM " + Self.bottomRuns + "\nRETURNING node_id"
        let hkGap = "DELETE FROM " + Self.gapRuns + "\nRETURNING node_id"
        let hkTop = "DELETE FROM " + Self.topRuns + "\nRETURNING node_id"
        /// A whole chain's runs, found by the ids its fill just queued —
        /// every run of the chain has its node there, and ids another fill
        /// of the same pass queued fail `chain_id` — so the delete searches
        /// `run` by key and only the fill scans it. Deleting by `chain_id`
        /// alone would scan `run` a second time: the same cost as the fill
        /// again when the chain holds few runs (80 against 40 ms at 2.4M
        /// runs, 0 or 50 of them the chain's), where by key a runless
        /// chain's death costs what it did when the delete returned the ids
        /// to Swift (40 ms, the fill's scan). A large chain's pays per id
        /// queued: 348 against the old 480 ms for 400k runs on 3.51.0 (324
        /// against 512 on 3.43.2); one plain second scan would have been
        /// 198 (188).
        let hkOrphanChainRuns =
            "DELETE FROM " + Self.orphanChainRuns + " AND node_id IN (SELECT id FROM temp.gc)"

        /// The content marks a death left with no indexed snapshot on one
        /// side: at or below the lowest indexed seq above a dead bottom (its
        /// pair's lower snapshot is gone), above the highest below a dead
        /// top. A whole chain's death is the first with the top sentinel.
        let hkEditsUpTo = "DELETE FROM edit WHERE chain_id = ? AND seq <= ?"
        let hkEditsAbove = "DELETE FROM edit WHERE chain_id = ? AND seq > ?"
        let hkBlindsUpTo = "DELETE FROM blind WHERE chain_id = ? AND seq <= ?"
        let hkBlindsAbove = "DELETE FROM blind WHERE chain_id = ? AND seq > ?"

        // MARK: Node GC, one level at a time over temp.gc
        let gcClear = "DELETE FROM temp.gc"
        let gcInsert = "INSERT OR IGNORE INTO temp.gc (id) VALUES (?)"
        /// Keeps, of the queued ids, only nodes nothing needs: gone from the
        /// queue are the root (id 1, created with the schema and never again:
        /// every collection that deletes a child of the root queues it as
        /// that child's parent, and a listing may name "/" and give it runs
        /// and a stage row), ids with no node, and nodes a run, a child or a
        /// stage row holds. The root gone, its parent 0 is never queued.
        let gcKeepCollectable = """
            DELETE FROM temp.gc WHERE id = 1 OR id NOT IN (SELECT id FROM node)
                OR EXISTS (SELECT 1 FROM run WHERE run.node_id = gc.id)
                OR EXISTS (SELECT 1 FROM node WHERE node.parent = gc.id)
                OR EXISTS (SELECT 1 FROM temp.stage WHERE stage.node_id = gc.id)
            """
        let gcParents = "SELECT n.parent FROM temp.gc g JOIN node n ON n.id = g.id"
        let gcDeleteFTS = """
            INSERT INTO node_fts (node_fts, rowid, name)
            SELECT 'delete', n.id, n.name FROM temp.gc g JOIN node n ON n.id = g.id
            """
        /// A collected node's edits go with it: a later node could take its
        /// id, and the edits would then split another path's versions.
        let gcDeleteEdits = "DELETE FROM edit WHERE node_id IN (SELECT id FROM temp.gc)"
        let gcDeleteNodes = "DELETE FROM node WHERE id IN (SELECT id FROM temp.gc)"

        // MARK: Reads
        let versionsTimed = """
            SELECT s.hash, s.time FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ?
            ORDER BY s.time DESC, s.id DESC
            """
        let versionsInChain = """
            SELECT s.hash, s.time FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ? AND r.chain_id = (SELECT id FROM chain WHERE key = ?)
            ORDER BY s.time DESC, s.id DESC
            """
        let summaryCounts = InList { placeholders in
            """
            SELECT r.node_id, count(*), max(s.time) FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id IN (\(placeholders))
            GROUP BY r.node_id
            """
        }
        let summaryNewest = """
            SELECT s.hash FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ? AND s.time = ?
            ORDER BY s.id DESC LIMIT 1
            """
        let containsKind = InList { placeholders in
            """
            SELECT node_id, is_dir FROM run
            WHERE node_id IN (\(placeholders)) AND chain_id = ? AND first_seq <= ? AND last_seq >= ?
            """
        }
        let aliveRuns = """
            SELECT r.chain_id, r.first_seq, r.last_seq, r.is_dir FROM run r
            WHERE r.node_id = ? AND EXISTS (SELECT 1 FROM snap s
                WHERE s.chain_id = r.chain_id AND s.state = 1 AND s.seq BETWEEN r.first_seq AND r.last_seq)
            """
        let newestCover = """
            SELECT time, id FROM snap
            WHERE chain_id = ? AND state = 1 AND seq BETWEEN ? AND ?
            ORDER BY time DESC, id DESC LIMIT 1
            """
        /// A folder's children across one chain's indexed history, each with
        /// the newest indexed snapshot holding it: SQLite takes the bare
        /// columns of a single-`max()` aggregate from the row with the max,
        /// so the kind, hash and seq are that snapshot's. Grouped by name —
        /// unique under one parent — so the groups arrive in the order the
        /// `(parent, name)` index walks and no sort is needed.
        let childrenInChain = """
            SELECT n.name, r.is_dir, s.seq, s.hash, max(s.time) FROM node n
            JOIN run r ON r.node_id = n.id AND r.chain_id = (SELECT id FROM chain WHERE key = ?)
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE n.parent = ?
            GROUP BY n.name
            """
        /// `versionsInChain` with each snapshot's seq and the run that
        /// claims it (its `first_seq`, unique per node and chain): what a
        /// content-version split walks. In the versions' time order, which
        /// is also what keeps the planner on the run's key rather than on
        /// every indexed snapshot of the chain.
        let heldInChain = """
            SELECT s.hash, s.time, s.seq, r.first_seq FROM run r
            JOIN snap s ON s.chain_id = r.chain_id AND s.state = 1
                AND s.seq BETWEEN r.first_seq AND r.last_seq
            WHERE r.node_id = ? AND r.chain_id = (SELECT id FROM chain WHERE key = ?)
            ORDER BY s.time DESC, s.id DESC
            """
        let editSeqs = "SELECT seq FROM edit WHERE node_id = ? AND chain_id = (SELECT id FROM chain WHERE key = ?)"
        let blindSeqs = """
            SELECT seq FROM blind WHERE chain_id = (SELECT id FROM chain WHERE key = ?) AND seq > ? AND seq <= ?
            """
        /// The chain's newest indexed snapshot, the versions' own order.
        let chainNewestIndexed = """
            SELECT seq FROM snap WHERE chain_id = (SELECT id FROM chain WHERE key = ?) AND state = 1
            ORDER BY time DESC, id DESC LIMIT 1
            """
        let searchFTS = """
            SELECT n.id, n.name FROM node_fts f JOIN node n ON n.id = f.rowid
            WHERE node_fts MATCH ? ORDER BY n.name
            """
        /// A file no listing has reached knows nothing, so it is incomplete
        /// whatever its (empty) tables say. Past that, chain-driven, one
        /// `snap_cover` probe per chain and state: a snapshot still to read,
        /// or one set aside as unreadable, keeps the index incomplete.
        let notComplete = """
            SELECT NOT EXISTS (SELECT 1 FROM listing_applied)
                OR EXISTS (SELECT 1 FROM chain
                    WHERE EXISTS (SELECT 1 FROM snap WHERE snap.chain_id = chain.id AND snap.state IN (0, 2)))
            """

        // MARK: Browse caches
        let cacheOwnerPut = "INSERT INTO cache_owner (snapshot_id) VALUES (?) ON CONFLICT DO NOTHING"
        let cacheListingPut =
            "INSERT INTO dir_listing (snapshot_id, dir_path, nodes) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
        let cacheDiffPut =
            "INSERT INTO diff_result (older_id, newer_id, changes) VALUES (?, ?, ?) ON CONFLICT DO NOTHING"
        let cacheListingGet = "SELECT nodes FROM dir_listing WHERE snapshot_id = ? AND dir_path = ?"
        let cacheDiffGet = "SELECT changes FROM diff_result WHERE older_id = ? AND newer_id = ?"
        /// Every snap row is a listed snapshot, so "no snap row" is "not
        /// listed" — forgotten, or never reconciled at all.
        let cacheSweepIDs = """
            SELECT o.snapshot_id FROM cache_owner o
            WHERE NOT EXISTS (SELECT 1 FROM snap s WHERE s.hash = o.snapshot_id)
            """
        let cacheSweepListing = "DELETE FROM dir_listing WHERE snapshot_id = ?"
        let cacheSweepDiffOlder = "DELETE FROM diff_result WHERE older_id = ?"
        let cacheSweepDiffNewer = "DELETE FROM diff_result WHERE newer_id = ?"
        let cacheSweepOwner = "DELETE FROM cache_owner WHERE snapshot_id = ?"
    }

    /// A statement over an IN list, whose text depends on how many ids the
    /// list holds: stored as the function from the list's placeholders
    /// (`SQL.placeholders(n)`) to the statement, and called as
    /// `SQL.summaryCounts(placeholders:)`. A struct rather than a bare
    /// closure property because the registry reads it through `Mirror`, and
    /// a function value taken out of a `Mirror` child and called crashes the
    /// process (Swift 6.4, both optimisation levels), while a struct that
    /// holds the function casts and calls cleanly.
    ///
    /// Its callers prepare it per call (`Row.fetchAll(db, sql:)`), never
    /// through `cachedStatement`: GRDB's statement cache is per connection
    /// and never evicts, and each list length is its own text, so caching
    /// would keep a statement per length on every reader — measured at
    /// about 30 MB of SQLite heap on one connection for both IN-list
    /// statements at every length up to 200 — to save 25–80 µs a call.
    /// Caching only the length a capped search repeats (its 200 ids) would
    /// keep one statement per shape, but it would save 60–80 µs a capped call
    /// and tie the store to the app's result cap. Padding every list to one
    /// length with NULLs would keep one text, but it made a one-id call four
    /// times slower, and a NULL pad in a `NOT IN` list would make that list
    /// match nothing.
    struct InList: Sendable {
        private let build: @Sendable (_ placeholders: String) -> String

        init(_ build: @escaping @Sendable (_ placeholders: String) -> String) {
            self.build = build
        }

        func callAsFunction(placeholders: String) -> String {
            build(placeholders)
        }
    }

    /// How the store spells a statement: `SQL.nodeLookup` is the
    /// `nodeLookup` property of the one `Statements` value, reached through
    /// a key path. Call sites read as they did when the statements were
    /// static constants, while the statements stay stored properties that
    /// reflection can list (a `static let` is invisible to `Mirror`).
    ///
    /// Declare no statement here. A `static let` on this enum compiles at
    /// every `SQL.x` call site, because ordinary lookup finds it before the
    /// dynamic member, and never reaches the registry, so no plan test would
    /// pin it — and nothing at run time can notice. Add it to `Statements`.
    @dynamicMemberLookup
    enum SQL {
        /// The one instance: what `SQL.x` reads and what the registry
        /// reflects over.
        static let statements = Statements()

        static subscript<T>(dynamicMember keyPath: KeyPath<Statements, T>) -> T {
            statements[keyPath: keyPath]
        }

        /// `count` comma-separated `?`s for an IN list.
        static func placeholders(_ count: Int) -> String {
            Array(repeating: "?", count: count).joined(separator: ", ")
        }
    }
}
