import Foundation

/// `restic check` and `restic prune`. Both lock the repository — `prune`
/// exclusively and for a long time — so the scheduler treats a repository
/// under maintenance as busy and defers its backups.
struct MaintenancePolicy: Codable, Sendable, Hashable {
    private static let checkIntervalDays = 7
    private static let pruneIntervalDays = 30
    static let rotatingSlices = 12

    /// 1 … `rotatingSlices`.
    var nextCheckDataSlice: Int = 1

    /// The user's decision: data read in slices where reading costs only time
    /// (this Mac's disks, a network share, an SFTP server), so every pack is
    /// read once every `rotatingSlices` checks; the structure alone where
    /// reading may be billed. A structure-only check passed a pack with one
    /// bit flipped that its slice caught (restic 0.19.1).
    func scheduledDataSubset(for kind: Repository.Kind) -> CheckDataSubset? {
        switch kind {
        case .local, .sftp: .slice(min(max(1, nextCheckDataSlice), Self.rotatingSlices), of: Self.rotatingSlices)
        case .s3: nil
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

    /// From `addedAt` when the task never ran, so adding a repository does
    /// not start a check or a long prune at once.
    func nextDate(for task: MaintenanceTask, addedAt: Date) -> Date {
        switch task {
        case .check: (lastCheckAt ?? addedAt).addingTimeInterval(TimeInterval(Self.checkIntervalDays) * 86_400)
        case .prune: (lastPruneAt ?? addedAt).addingTimeInterval(TimeInterval(Self.pruneIntervalDays) * 86_400)
        }
    }
}

enum CheckDataSubset: Equatable, Sendable {
    case percent(Int)
    /// restic splits the packs into `total` groups by their IDs and reads
    /// group `n`.
    case slice(Int, of: Int)

    /// `--read-data-subset`
    var argument: String {
        switch self {
        case let .percent(percent): "\(percent)%"
        case let .slice(n, total): "\(n)/\(total)"
        }
    }
}

enum MaintenanceTask: String, Codable, Sendable, Hashable, CaseIterable {
    /// Ahead of `check` when both fall due at once: the exclusive, long one.
    case prune
    case check

    var displayName: String {
        switch self {
        case .prune: "Cleanup"
        case .check: "Verification"
        }
    }

    /// For the quit and removal dialogs.
    var runningClause: String {
        "A \(displayName.lowercased()) is running"
    }

    var inFlightTitle: String {
        switch self {
        case .prune: "Cleaning up…"
        case .check: "Verifying…"
        }
    }
}
