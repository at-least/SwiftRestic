import Foundation

/// Periodic repository upkeep: `restic check` to verify integrity and
/// `restic prune` to reclaim the space that `forget` freed.
///
/// Both hold a lock on the repository — `prune` an exclusive one that can run for
/// a long time — so the scheduler treats a repository under maintenance as busy
/// and defers backups to it rather than letting them collide.
struct MaintenancePolicy: Codable, Sendable, Hashable {
    var checkEnabled: Bool = true
    var checkIntervalDays: Int = 7
    /// Percentage of pack data to actually read and verify. 0 checks structure
    /// only, which is fast; reading data is thorough and slow.
    var checkReadDataPercent: Int = 0
    /// How many slices a scheduled check reads the data in, the next one
    /// each time (`--read-data-subset=n/N`), so every pack is read once
    /// every N checks; 0 for the percentage above. A structure-only check
    /// passed a pack with one bit flipped that its slice caught (restic
    /// 0.19.1, 2026-10-17).
    var checkDataSlices: Int = 0
    /// The slice the next scheduled check reads, 1 … `checkDataSlices`.
    var nextCheckDataSlice: Int = 1

    /// The scheduled check's depth, as the editor offers it.
    enum CheckDepth: Hashable, Sendable {
        case structure
        /// The data in `rotatingSlices` slices, one per check.
        case rotating
        case percent(Int)
    }

    static let rotatingSlices = 12

    var checkDepth: CheckDepth {
        get {
            if checkDataSlices > 0 { return .rotating }
            return checkReadDataPercent > 0 ? .percent(checkReadDataPercent) : .structure
        }
        set {
            switch newValue {
            case .structure: (checkDataSlices, checkReadDataPercent) = (0, 0)
            case .rotating: (checkDataSlices, checkReadDataPercent) = (Self.rotatingSlices, 0)
            case let .percent(percent): (checkDataSlices, checkReadDataPercent) = (0, percent)
            }
        }
    }

    /// What a scheduled check reads besides the structure: the rotation's
    /// next slice, a percentage, or nothing.
    var scheduledDataSubset: CheckDataSubset? {
        if checkDataSlices > 0 { return .slice(min(max(1, nextCheckDataSlice), checkDataSlices), of: checkDataSlices) }
        return checkReadDataPercent > 0 ? .percent(checkReadDataPercent) : nil
    }

    /// A new repository's depth by where it is (the user's pick): its data
    /// read in slices where reading costs only time — this Mac's disks, a
    /// network share, an SFTP server; the structure alone where reading may
    /// be billed — a cloud provider, an rclone remote, a REST server on a
    /// metered host — until chosen in the editor.
    static func defaultCheckDepth(for kind: Repository.Kind) -> CheckDepth {
        switch kind {
        case .local, .sftp: .rotating
        case .rest, .s3, .b2, .azure, .gcs, .rclone: .structure
        }
    }

    /// Off here and for a repository saved without the key — pruning rewrites
    /// pack files and can take a long time — while a repository added from
    /// now on starts from `forNewRepository`.
    var pruneEnabled: Bool = false
    var pruneIntervalDays: Int = 30

    /// What the editor gives a new repository: prune on, every 30 days, the
    /// first one 30 days after the repository is added — retention runs
    /// after every backup, and only a prune frees what it removed — and its
    /// kind's check depth. A repository saved before keeps its own settings.
    static func forNewRepository(kind: Repository.Kind) -> MaintenancePolicy {
        var policy = MaintenancePolicy()
        policy.pruneEnabled = true
        policy.checkDepth = defaultCheckDepth(for: kind)
        return policy
    }

    var lastCheckAt: Date?
    var lastPruneAt: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkEnabled = c.value(.checkEnabled, default: true)
        checkIntervalDays = c.value(.checkIntervalDays, default: 7)
        checkReadDataPercent = c.value(.checkReadDataPercent, default: 0)
        checkDataSlices = c.value(.checkDataSlices, default: 0)
        nextCheckDataSlice = c.value(.nextCheckDataSlice, default: 1)
        pruneEnabled = c.value(.pruneEnabled, default: false)
        pruneIntervalDays = c.value(.pruneIntervalDays, default: 30)
        lastCheckAt = c.optional(.lastCheckAt)
        lastPruneAt = c.optional(.lastPruneAt)
    }

    /// When the given task next falls due.
    ///
    /// A repository that has never had the task run counts from when it was
    /// added, not from now — otherwise adding a repository would immediately
    /// kick off a check or a long prune.
    func nextDate(for task: MaintenanceTask, addedAt: Date) -> Date? {
        switch task {
        case .check:
            guard checkEnabled, checkIntervalDays > 0 else { return nil }
            return (lastCheckAt ?? addedAt)
                .addingTimeInterval(TimeInterval(checkIntervalDays) * 86_400)
        case .prune:
            guard pruneEnabled, pruneIntervalDays > 0 else { return nil }
            return (lastPruneAt ?? addedAt)
                .addingTimeInterval(TimeInterval(pruneIntervalDays) * 86_400)
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

    /// What the check read, in the repository page's words.
    var words: String {
        switch self {
        case .percent(100): "all of the data"
        case let .percent(percent): "\(percent)% of the data"
        case let .slice(n, total): "part \(n) of \(total)"
        }
    }
}

/// The upkeep operations the scheduler can start.
enum MaintenanceTask: String, Codable, Sendable, Hashable, CaseIterable {
    /// Reclaims space. Takes an exclusive lock and can run for a long time, so it
    /// is ordered ahead of `check` when both fall due at once.
    case prune
    case check

    var displayName: String {
        switch self {
        case .prune: "Cleanup"
        case .check: "Check"
        }
    }
}
