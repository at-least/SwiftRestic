import Foundation

/// One entry of `restic snapshots --json`, or the header object that `restic ls
/// --json` emits before the node stream.
struct Snapshot: Sendable, Equatable, Hashable, Identifiable, Decodable {
    var id: String
    var shortID: String
    var time: Date
    var tree: String?
    var paths: [String]
    var hostname: String?
    var username: String?
    var tags: [String]
    var programVersion: String?
    var summary: ResticSummary?

    private enum CodingKeys: String, CodingKey {
        case id, time, tree, paths, hostname, username, tags, summary
        case shortID = "short_id"
        case programVersion = "program_version"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID) ?? String(id.prefix(8))
        time = try c.decode(Date.self, forKey: .time)
        tree = try c.decodeIfPresent(String.self, forKey: .tree)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        programVersion = try c.decodeIfPresent(String.self, forKey: .programVersion)
        summary = try c.decodeIfPresent(ResticSummary.self, forKey: .summary)
    }

    /// Bytes actually written to the repository by the backup that made this
    /// snapshot — the number worth showing next to a snapshot in a list.
    var dataAdded: Int64? { summary?.dataAdded }
    var totalBytesProcessed: Int64? { summary?.totalBytesProcessed }
    var totalFilesProcessed: Int? { summary?.totalFilesProcessed }

    static func == (lhs: Snapshot, rhs: Snapshot) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One `message_type: node` line from `restic ls --json`.
struct SnapshotNode: Sendable, Equatable, Hashable, Identifiable, Decodable {
    enum Kind: String, Sendable, Decodable {
        case file, dir, symlink, irregular
        case dev, chardev, fifo, socket
    }

    var name: String
    var type: Kind
    var path: String
    var size: Int64?
    var mode: UInt32?
    var permissions: String?
    var uid: UInt32?
    var gid: UInt32?
    var mtime: Date?
    var atime: Date?
    var ctime: Date?
    var linkTarget: String?

    var id: String { path }
    var isDirectory: Bool { type == .dir }

    private enum CodingKeys: String, CodingKey {
        case name, type, path, size, mode, permissions, uid, gid, mtime, atime, ctime
        case linkTarget = "linktarget"
    }

    /// The optional members all default to `nil`, so a node can be built from
    /// just the three fields the browser and the search results need.
    init(name: String, type: Kind, path: String) {
        self.name = name
        self.type = type
        self.path = path
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(Kind.self, forKey: .type)) ?? .irregular
        path = try c.decode(String.self, forKey: .path)
        size = try c.decodeIfPresent(Int64.self, forKey: .size)
        mode = try c.decodeIfPresent(UInt32.self, forKey: .mode)
        permissions = try c.decodeIfPresent(String.self, forKey: .permissions)
        uid = try c.decodeIfPresent(UInt32.self, forKey: .uid)
        gid = try c.decodeIfPresent(UInt32.self, forKey: .gid)
        mtime = try c.decodeIfPresent(Date.self, forKey: .mtime)
        atime = try c.decodeIfPresent(Date.self, forKey: .atime)
        ctime = try c.decodeIfPresent(Date.self, forKey: .ctime)
        linkTarget = try c.decodeIfPresent(String.self, forKey: .linkTarget)
    }
}

/// One file `restic find --json` matched, inside one snapshot.
struct FindMatch: Sendable, Equatable, Hashable, Identifiable, Decodable {
    var path: String
    var type: String
    var size: Int64?
    var permissions: String?
    var mtime: Date?

    var id: String { path }
    var isDirectory: Bool { type == "dir" }
    var name: String { (path as NSString).lastPathComponent }

    /// The node shape the restore code already understands.
    var node: SnapshotNode {
        var node = SnapshotNode(
            name: name,
            type: SnapshotNode.Kind(rawValue: type) ?? .file,
            path: path
        )
        node.size = size
        node.mtime = mtime
        return node
    }
}

/// One snapshot's worth of `restic find --json` results.
struct FindResult: Sendable, Equatable, Decodable {
    var matches: [FindMatch]
    var hits: Int
    /// Full snapshot ID.
    var snapshot: String

    private enum CodingKeys: String, CodingKey { case matches, hits, snapshot }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matches = try c.decodeIfPresent([FindMatch].self, forKey: .matches) ?? []
        hits = try c.decodeIfPresent(Int.self, forKey: .hits) ?? 0
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot) ?? ""
    }
}

/// `restic stats --json`.
struct RepositoryStats: Sendable, Equatable, Decodable {
    var totalSize: Int64
    var totalFileCount: Int?
    var totalBlobCount: Int?
    var snapshotsCount: Int?
    var totalUncompressedSize: Int64?
    var compressionRatio: Double?
    var compressionSpaceSaving: Double?

    private enum CodingKeys: String, CodingKey {
        case totalSize = "total_size"
        case totalFileCount = "total_file_count"
        case totalBlobCount = "total_blob_count"
        case snapshotsCount = "snapshots_count"
        case totalUncompressedSize = "total_uncompressed_size"
        case compressionRatio = "compression_ratio"
        case compressionSpaceSaving = "compression_space_saving"
    }
}

/// The result of `restic diff <older> <newer>`.
///
/// `+` means "present only in `newer`", so the order the two IDs were passed in
/// is part of the result, not an implementation detail.
struct SnapshotDiff: Sendable, Equatable {
    /// How many change lines are kept. Past this the list stays useful for
    /// scanning and searching but is no longer complete; `isTruncated` says so
    /// and the statistics line still carries the real totals.
    static let changeLimit = 20_000

    var olderID: String
    var newerID: String
    var changes: [ResticDiffChange] = []
    var statistics: ResticDiffStatistics?
    var isTruncated = false

    func count(of category: ResticDiffChange.Category) -> Int {
        changes.reduce(0) { $0 + ($1.category == category ? 1 : 0) }
    }
}

extension Snapshot {
    /// The snapshot this one is most naturally compared against: the newest
    /// earlier one that backed up the same paths from the same host.
    ///
    /// A repository shared by several plans, or several Macs, holds snapshots of
    /// unrelated trees side by side. Diffing against "the row above" in that list
    /// shows every file as added and every other file as removed, which is noise;
    /// this mirrors restic's own `--group-by host,paths` grouping instead.
    func previousComparable(in snapshots: [Snapshot]) -> Snapshot? {
        snapshots
            .filter { $0.id != id && $0.time < time && $0.paths == paths && $0.hostname == hostname }
            .max { $0.time < $1.time }
    }
}
