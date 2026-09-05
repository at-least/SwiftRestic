import Foundation

/// The stored outcome of one backup, prune or check run.
struct RunRecord: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case backup, forget, check, prune, restore, initialize
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded, completedWithErrors, failed, cancelled

        var displayName: String {
            switch self {
            case .succeeded: "Succeeded"
            case .completedWithErrors: "Completed with errors"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        var symbolName: String {
            switch self {
            case .succeeded: "checkmark.circle.fill"
            case .completedWithErrors: "exclamationmark.triangle.fill"
            case .failed: "xmark.octagon.fill"
            case .cancelled: "slash.circle.fill"
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .backup
    var planID: UUID?
    var planName: String = ""
    var repositoryID: UUID?
    var startedAt: Date = .now
    var finishedAt: Date = .now
    var outcome: Outcome = .succeeded
    var snapshotID: String?
    var filesNew: Int = 0
    var filesChanged: Int = 0
    var filesUnmodified: Int = 0
    var bytesProcessed: Int64 = 0
    var dataAdded: Int64 = 0
    /// Per-item errors reported by restic (unreadable files and the like).
    ///
    /// These are restic's own words about the user's files, and are the only
    /// warnings sent to external notification channels. Capped at 50 entries so
    /// a pathological run cannot bloat `config.json`; `itemErrorCount` keeps the
    /// real total.
    var itemErrors: [String] = []
    /// How many per-item errors the run actually produced, which can exceed the
    /// capped `itemErrors` list.
    var itemErrorCount: Int = 0
    /// Results of failing hooks.
    ///
    /// Kept apart from `itemErrors` on purpose: a hook is an arbitrary user
    /// script and its output can contain anything it happened to print — a
    /// verbose `curl` echoes its own `Authorization` header. These stay local and
    /// are never sent to a webhook or chat channel.
    var hookMessages: [String] = []
    /// Fatal error text, when `outcome == .failed`.
    var failureMessage: String?
    /// Tail of what the command printed. `prune` has no JSON output at all, so
    /// this is the only record of what it did.
    var detailText: String?

    init(
        kind: Kind = .backup,
        planID: UUID? = nil,
        planName: String = "",
        repositoryID: UUID? = nil,
        startedAt: Date = .now
    ) {
        self.kind = kind
        self.planID = planID
        self.planName = planName
        self.repositoryID = repositoryID
        self.startedAt = startedAt
        self.finishedAt = startedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .backup)
        planID = c.optional(.planID)
        planName = c.value(.planName, default: "")
        repositoryID = c.optional(.repositoryID)
        startedAt = c.value(.startedAt, default: .now)
        finishedAt = c.value(.finishedAt, default: .now)
        outcome = c.value(.outcome, default: .succeeded)
        snapshotID = c.optional(.snapshotID)
        filesNew = c.value(.filesNew, default: 0)
        filesChanged = c.value(.filesChanged, default: 0)
        filesUnmodified = c.value(.filesUnmodified, default: 0)
        bytesProcessed = c.value(.bytesProcessed, default: 0)
        dataAdded = c.value(.dataAdded, default: 0)
        itemErrors = c.value(.itemErrors, default: [])
        itemErrorCount = c.value(.itemErrorCount, default: 0)
        hookMessages = c.value(.hookMessages, default: [])
        failureMessage = c.optional(.failureMessage)
        detailText = c.optional(.detailText)
    }

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
}
