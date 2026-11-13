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
        case .prune: "Freeing space"
        case .check: "Verification"
        }
    }

    /// For the quit and removal dialogs.
    func runningClause(count: Int) -> String {
        switch self {
        case .prune: count == 1 ? "Space is being freed" : "Space is being freed on \(count) locations"
        case .check: count == 1 ? "A verification is running" : "\(count) verifications are running"
        }
    }

    /// Follows a location's name: "“NAS” is freeing space".
    var locationClause: String {
        switch self {
        case .prune: "is freeing space"
        case .check: "is running a verification"
        }
    }

    /// A skip the user asked about: "Freeing space on “NAS” was skipped".
    func skippedTitle(location: String) -> String {
        switch self {
        case .prune: "Freeing space on “\(location)” was skipped"
        case .check: "Verification of “\(location)” was skipped"
        }
    }

    var inFlightTitle: String {
        switch self {
        case .prune: "Freeing space…"
        case .check: "Verifying…"
        }
    }
}
