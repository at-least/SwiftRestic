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

    /// Off by default: pruning rewrites pack files and can take a long time.
    var pruneEnabled: Bool = false
    var pruneIntervalDays: Int = 30

    var lastCheckAt: Date?
    var lastPruneAt: Date?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkEnabled = c.value(.checkEnabled, default: true)
        checkIntervalDays = c.value(.checkIntervalDays, default: 7)
        checkReadDataPercent = c.value(.checkReadDataPercent, default: 0)
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

    var summary: String {
        var parts: [String] = []
        if checkEnabled {
            let depth = checkReadDataPercent > 0 ? " (reads \(checkReadDataPercent)% of data)" : ""
            parts.append("Check every \(checkIntervalDays)d\(depth)")
        }
        if pruneEnabled { parts.append("Prune every \(pruneIntervalDays)d") }
        return parts.isEmpty ? "Off" : parts.joined(separator: ", ")
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
        case .prune: "Prune"
        case .check: "Check"
        }
    }
}
