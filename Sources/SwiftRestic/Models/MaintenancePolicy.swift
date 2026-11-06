import Foundation

/// Periodic repository upkeep: `restic check` to verify integrity and
/// `restic prune` to reclaim the space that `forget` freed.
///
/// Both hold a lock on the repository — `prune` an exclusive one that can run for
/// a long time — so the scheduler treats a repository under maintenance as busy
/// and defers backups to it rather than letting them collide.
struct MaintenancePolicy: Codable, Sendable, Hashable {
    static let checkIntervalDays = 7
    static let pruneIntervalDays = 30
    static let rotatingSlices = 12

    /// The slice the next scheduled check reads, 1 … `rotatingSlices`.
    var nextCheckDataSlice: Int = 1

    /// A scheduled check's data by where the repository is (the user's pick):
    /// its data read in slices where reading costs only time — this Mac's
    /// disks, a network share, an SFTP server — so every pack is read once
    /// every `rotatingSlices` checks; the structure alone where reading may
    /// be billed. A structure-only check passed a pack with one bit flipped
    /// that its slice caught (restic 0.19.1).
    func scheduledDataSubset(for kind: Repository.Kind) -> CheckDataSubset? {
        switch kind {
        case .local, .sftp: .slice(min(max(1, nextCheckDataSlice), Self.rotatingSlices), of: Self.rotatingSlices)
        case .rest, .s3, .b2, .azure, .gcs, .rclone: nil
        }
    }

    var lastCheckAt: Date?
    var lastPruneAt: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nextCheckDataSlice = c.value(.nextCheckDataSlice, default: 1)
        lastCheckAt = c.optional(.lastCheckAt)
        lastPruneAt = c.optional(.lastPruneAt)
    }

    /// A repository that has never had the task run counts from when it was
    /// added, not from now — otherwise adding a repository would immediately
    /// kick off a check or a long prune.
    func nextDate(for task: MaintenanceTask, addedAt: Date) -> Date {
        switch task {
        case .check: (lastCheckAt ?? addedAt).addingTimeInterval(TimeInterval(Self.checkIntervalDays) * 86_400)
        case .prune: (lastPruneAt ?? addedAt).addingTimeInterval(TimeInterval(Self.pruneIntervalDays) * 86_400)
        }
    }
}

/// What `restic check` reads of the backed-up data besides the structure.
enum CheckDataSubset: Equatable, Sendable {
    case percent(Int)
    /// Slice `n` of `total`: restic splits the packs into `total` groups by
    /// their IDs and reads group `n`.
    case slice(Int, of: Int)

    /// restic's `--read-data-subset` value.
    var argument: String {
        switch self {
        case let .percent(percent): "\(percent)%"
        case let .slice(n, total): "\(n)/\(total)"
        }
    }

    var words: String {
        switch self {
        case .percent(100): "all of the data"
        case let .percent(percent): "\(percent)% of the data"
        case let .slice(n, total): "part \(n) of \(total)"
        }
    }
}

enum MaintenanceTask: String, Codable, Sendable, Hashable, CaseIterable {
    /// Takes an exclusive lock and can run for a long time, so it
    /// is ordered ahead of `check` when both fall due at once.
    case prune
    case check

    var displayName: String {
        switch self {
        case .prune: "Cleanup"
        case .check: "Verification"
        }
    }

    var inFlightTitle: String {
        switch self {
        case .prune: "Cleaning up…"
        case .check: "Verifying…"
        }
    }
}
