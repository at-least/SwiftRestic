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

        /// The marker a run row wears in lists. Success wears nothing — a
        /// clean run is the quiet default, and only trouble asks to be seen
        /// (the unread-dot rule Mail's message list follows). Cancelled keeps
        /// a quiet monochrome outline so it can never be misread as success;
        /// the two problem outcomes keep their alarm glyphs.
        var symbolName: String? {
            switch self {
            case .succeeded: nil
            case .cancelled: "slash.circle"
            case .completedWithErrors: "exclamationmark.triangle.fill"
            case .failed: "xmark.octagon.fill"
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
    /// warnings sent to external notification channels. Capped at
    /// `storedItemErrorLimit` entries so a pathological run cannot bloat
    /// `config.json`; `itemErrorCount` keeps the real total.
    ///
    /// Ordered, and the order is load-bearing (`unreadableItems` slices it):
    /// the unreadable items first — sources restic skipped, then its error
    /// events, one line per item — then the decoding-gap warning, then the
    /// "Retention skipped: …" line. Only the first group is counted.
    var itemErrors: [String] = []
    /// How many distinct unreadable items the run produced, which can exceed
    /// the capped `itemErrors` list. Records written before the dedupe
    /// counted restic's events instead (a folder it could not list twice) and
    /// the decoding-gap line with them; the lines stored after the unreadable
    /// items are never counted.
    var itemErrorCount: Int = 0
    /// restic's exit code for the `backup` command itself: 0, or 3 when some
    /// source data could not be read — any other code throws before a record
    /// keeps it. Nil on runs restic never finished and on records from before
    /// this field existed.
    var exitCode: Int32?
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
        exitCode = c.optional(.exitCode)
        hookMessages = c.value(.hookMessages, default: [])
        failureMessage = c.optional(.failureMessage)
        detailText = c.optional(.detailText)
    }

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
}

extension RunRecord {
    /// How many item-error lines a record stores; `itemErrorCount` keeps the
    /// real total past it.
    static let storedItemErrorLimit = 50

    /// Whether the snapshot a backup wrote holds everything it was asked to.
    /// restic keeps no such fact in the snapshot itself (`snapshots --json`
    /// has no error field), so the run record is the only place it lives.
    enum SnapshotCompleteness: Sendable, Equatable {
        case complete, incomplete, unknown
    }

    /// Nil unless this is a backup that wrote a snapshot. restic's exit code
    /// alone decides: 3 means some source data could not be read
    /// (`restic backup --help`: "incomplete snapshot created"), and nothing
    /// else leaves a snapshot short — retention skips, decoding gaps and
    /// failing hooks all come after a whole snapshot, so the outcome is no
    /// guide. A record from before the exit code was stored is incomplete
    /// only if it named an unreadable item; otherwise it proves nothing
    /// either way and reads unknown, never complete.
    var snapshotCompleteness: SnapshotCompleteness? {
        guard kind == .backup, snapshotID != nil else { return nil }
        if let exitCode {
            return exitCode == ResticError.backupPartialSuccessCode ? .incomplete : .complete
        }
        return itemErrorCount > 0 ? .incomplete : .unknown
    }

    /// The stored lines naming what restic could not read, without the
    /// decoding and retention lines stored after them. `min` because a run
    /// with more unreadable items than the cap stored only the cap's worth,
    /// and a bare `prefix(itemErrorCount)` would reach into the trailing
    /// lines. A scan-time complaint about an item the archiver then read
    /// fine (a permission changed mid-run) is still among them — rare, and
    /// restic gives no way to tell.
    var unreadableItems: ArraySlice<String> {
        itemErrors.prefix(min(itemErrorCount, Self.storedItemErrorLimit))
    }

    /// The backup run that wrote each snapshot, keyed by full snapshot ID —
    /// not by repository: two repository entries pointing at one restic
    /// repository list the same snapshot, which the same run wrote. Backup
    /// records only, so a restore naming the snapshot it read never becomes
    /// its status; the first in array order wins, and runs are stored newest
    /// first.
    static func backupRunsBySnapshot(_ runs: [RunRecord]) -> [String: RunRecord] {
        var map: [String: RunRecord] = [:]
        map.reserveCapacity(runs.count)
        for run in runs where run.kind == .backup {
            guard let snapshotID = run.snapshotID, map[snapshotID] == nil else { continue }
            map[snapshotID] = run
        }
        return map
    }
}

extension RunRecord {
    /// Maps a thrown error onto the outcome fields: task cancellation — Swift's
    /// or restic's own — reads as `.cancelled`, with the caller saying whether
    /// it was the user's stop or the app quitting, and anything else as
    /// `.failed` with the error's message. Callers keep their own side effects:
    /// stamps, banners, bookkeeping.
    mutating func setOutcome(from error: Error, cancellationMessage: String) {
        let cancelled = error is CancellationError || (error as? ResticError) == .cancelled
        outcome = cancelled ? .cancelled : .failed
        failureMessage = cancelled ? cancellationMessage : error.localizedDescription
    }
}
