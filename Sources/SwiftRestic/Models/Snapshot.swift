import Foundation

/// One entry of `restic snapshots --json`, or `restic ls --json`'s header.
struct Snapshot: Sendable, Equatable, Hashable, Identifiable, Decodable {
    var id: String
    var shortID: String
    var time: Date
    var paths: [String]
    var hostname: String?
    var tags: [String]
    /// The `--exclude` patterns the backup ran with; restic omits the key
    /// for none. The adopt sheet prefills from them.
    var excludes: [String]
    /// The one field of restic's `summary` anything reads. Listings are the
    /// app's largest arrays, so the rest is not carried.
    var dataAdded: Int64?
    /// The snapshot `restic rewrite` made this one from: the one just
    /// before, not the first of a chain (0.19.1, probed: a third rewrite's
    /// `original` named the second's ID, already gone). Nil for a backup's
    /// own snapshot.
    var original: String?

    /// restic's `short_id`: the ID's first this-many characters.
    static let shortIDLength = 8

    private enum CodingKeys: String, CodingKey {
        case id, time, paths, hostname, tags, excludes, summary, original
        case shortID = "short_id"
    }

    private struct Summary: Decodable {
        var dataAdded: Int64?
        private enum CodingKeys: String, CodingKey { case dataAdded = "data_added" }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // `short_id` is deprecated upstream, so a release may stop writing it.
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID) ?? String(id.prefix(Snapshot.shortIDLength))
        time = try c.decode(Date.self, forKey: .time)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? []
        dataAdded = try c.decodeIfPresent(Summary.self, forKey: .summary)?.dataAdded
        original = try c.decodeIfPresent(String.self, forKey: .original)
    }

    static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One `message_type: node` line from `restic ls --json`.
struct SnapshotNode: Sendable, Equatable, Hashable, Identifiable, Decodable {
    enum Kind: String, Sendable, Codable {
        case file, dir, symlink, irregular
        case dev, chardev, fifo, socket
    }

    /// Identity is the path, so `Identifiable`, `Equatable` and sets agree.
    static func == (lhs: SnapshotNode, rhs: SnapshotNode) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    var name: String
    var type: Kind
    var path: String
    var size: Int64?
    var mtime: Date?

    var id: String { path }
    var isDirectory: Bool { type == .dir }

    private enum CodingKeys: String, CodingKey {
        case name, type, path, size, mtime
    }

    init(name: String, type: Kind, path: String, size: Int64? = nil, mtime: Date? = nil) {
        self.name = name
        self.type = type
        self.path = path
        self.size = size
        self.mtime = mtime
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(Kind.self, forKey: .type)
        path = try c.decode(String.self, forKey: .path)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        mtime = try c.decodeIfPresent(Date.self, forKey: .mtime)
    }
}

extension SnapshotNode {
    /// For a snapshot's own root paths, which restic never lists.
    static func directory(path: String) -> SnapshotNode {
        SnapshotNode(name: SnapshotLineage.component(of: path), type: .dir, path: path)
    }
}

/// One file `restic find --json` matched, inside one snapshot.
struct FindMatch: Sendable, Equatable, Hashable, Identifiable, Decodable {
    var path: String
    var type: SnapshotNode.Kind
    var size: Int64?
    var mtime: Date?

    var id: String { path }
    var isDirectory: Bool { type == .dir }
    var name: String { SnapshotLineage.component(of: path) }

    static func == (lhs: FindMatch, rhs: FindMatch) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }

    var node: SnapshotNode {
        var node = SnapshotNode(name: name, type: type, path: path)
        node.size = size
        node.mtime = mtime
        return node
    }
}

/// One snapshot's worth of `restic find --json` results. Both keys are
/// required: restic 0.19.1 writes them in every result, and a result with
/// no snapshot would group and restore under a backup ID of "".
struct FindResult: Sendable, Equatable, Decodable {
    var matches: [FindMatch]
    /// The full ID.
    var snapshot: String
}

/// `restic stats --json`.
struct RepositoryStats: Sendable, Equatable, Decodable {
    var totalSize: Int64
    var snapshotsCount: Int?

    private enum CodingKeys: String, CodingKey {
        case totalSize = "total_size"
        case snapshotsCount = "snapshots_count"
    }
}

extension Snapshot {
    /// The newest earlier snapshot of the same paths from the same host
    /// (`SnapshotLineage`'s rule, restic's `--group-by host,paths`), not the
    /// row above: a shared repository holds unrelated trees side by side.
    func previousComparable(in snapshots: [Snapshot]) -> Snapshot? {
        let key = lineageKey
        return snapshots
            .filter { $0.id != id && $0.time < time && $0.lineageKey == key }
            .max { $0.time < $1.time }
    }

    /// First-seen order, once each.
    static func distinctHosts(of snapshots: [Snapshot]) -> [String] {
        BackupPlan.withoutDuplicates(snapshots.map { $0.hostname ?? "Unknown Mac" })
    }
}
