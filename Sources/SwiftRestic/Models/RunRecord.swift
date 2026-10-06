import Foundation

/// The stored outcome of one backup, check, prune or restore run.
struct RunRecord: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case backup, forget, check, prune, restore

        /// The operation's word in titles and rows: "Backup", "Check", …
        var displayName: String { rawValue.capitalized }
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

        /// The marker a run row wears in lists. Success wears nothing — only
        /// trouble asks to be seen. Cancelled keeps a quiet monochrome
        /// outline so it can never be misread as success; the problem
        /// outcomes keep their alarm glyphs.
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
    /// Per-item errors reported by restic (unreadable files and the like) —
    /// restic's own words about the user's files, and the only warnings sent
    /// to external notification channels. Capped at `storedItemErrorLimit`
    /// entries so a pathological run cannot bloat `config.json`;
    /// `itemErrorCount` keeps the real total.
    ///
    /// Ordered, and the order is load-bearing (`unreadableItems` slices it):
    /// the unreadable items first — sources restic skipped, then its error
    /// events, one line per item — then the decoding-gap warning, then the
    /// "Retention skipped: …" line. Only the first group is counted.
    var itemErrors: [String] = []
    /// How many distinct unreadable items the run produced, which can exceed
    /// the capped `itemErrors` list. The lines stored after the unreadable
    /// items — the decoding-gap warning, the "Retention skipped" line — are
    /// never counted.
    var itemErrorCount: Int = 0
    /// restic's exit code for the run's own command — the `backup` (0, or 3
    /// when some source data could not be read), else the first exit the
    /// run's transcript saw: a failed backup's, a check's, a prune's, a
    /// restore's. Nil when restic never reached an exit (a before-hook
    /// abort, a launch failure, a stop by cancel or a cap) and on records
    /// from before this field existed.
    var exitCode: Int32?
    /// The unreadable items by cause — macOS's privacy protection or the
    /// files' own permissions — counted over every item, past the stored
    /// cap. Nil on records from before it was kept; those are counted from
    /// `unreadableItems`.
    var itemErrorTally: ItemErrorDiagnosis.Tally?
    /// Whether SwiftRestic had Full Disk Access when the backup finished,
    /// so the drawer can tell "grant it" from "it has it now, back up
    /// again" from "macOS protects these anyway". Backups only; nil on
    /// records from before it was stamped.
    var fullDiskAccessAtRun: FullDiskAccessStatus?
    /// Results of failing hooks.
    ///
    /// Kept apart from `itemErrors`: a hook is an arbitrary user script and
    /// its output can contain anything it printed — a verbose `curl` echoes
    /// its own `Authorization` header. These stay local and are never sent
    /// to a webhook or chat channel.
    var hookMessages: [String] = []
    /// Fatal error text, when `outcome == .failed`.
    var failureMessage: String?
    /// A plain-text result: the tail of what `prune` printed (it has no JSON
    /// output, so this is the only record of what it did; the drawer shows
    /// it among the run's messages), a check's verdict, or what Apply
    /// Retention Now… removed — the Result row of a check or a forget in
    /// the drawer and Copy Details (a check's in its log too), and a
    /// forget's Activity Detail and banner.
    var detailText: String?
    /// restic's `version` line when the run was stored, for Copy Details and
    /// the log header. Nil on records from before it was kept.
    var resticVersion: String?
    /// Whether `Logs/<id>.log` was written for this run. False on records
    /// from before logs existed and when the write failed, so Show Log…
    /// can say so without a file check on the render path.
    var hasLog: Bool = false

    // Restores only. A restore's `snapshotID` is the backup it read, as the
    // restore was asked for it — never the snapshot a run wrote, which is
    // why the snapshot→run join filters on `kind == .backup`.

    /// When the backup restored from was made, if the listing knew it.
    var snapshotTime: Date?
    /// The item restored, or nil for a whole backup or several items.
    var sourcePath: String?
    /// Several items restored in one restic call, each its path in the
    /// backup — all from one folder of it (`RestoreBatch.Group`). Nil for
    /// one item or a whole backup.
    var sourcePaths: [String]?
    /// Where it landed: the restored item itself (what Reveal in Finder
    /// selects), or for a whole backup or several items, the folder they
    /// were restored into.
    var destinationPath: String?
    var filesRestored: Int = 0
    /// Files restic left as they were because the destination already held
    /// them — all a repeat restore reports (`files_skipped`, no
    /// `files_restored` key).
    var filesSkipped: Int = 0

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
        // Stored lines can still carry restic's trailing newline; mapping
        // through `storedItemError` here keeps every surface clean.
        itemErrors = c.value(.itemErrors, default: [String]()).map(Self.storedItemError)
        itemErrorCount = c.value(.itemErrorCount, default: 0)
        exitCode = c.optional(.exitCode)
        itemErrorTally = c.optional(.itemErrorTally)
        fullDiskAccessAtRun = c.optional(.fullDiskAccessAtRun)
        hookMessages = c.value(.hookMessages, default: [])
        failureMessage = c.optional(.failureMessage)
        detailText = c.optional(.detailText)
        resticVersion = c.optional(.resticVersion)
        hasLog = c.value(.hasLog, default: false)
        snapshotTime = c.optional(.snapshotTime)
        sourcePath = c.optional(.sourcePath)
        sourcePaths = c.optional(.sourcePaths)
        destinationPath = c.optional(.destinationPath)
        filesRestored = c.value(.filesRestored, default: 0)
        filesSkipped = c.value(.filesSkipped, default: 0)
    }

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }
}

extension RunRecord {
    /// How many item-error lines a record stores; `itemErrorCount` keeps the
    /// real total past it.
    static let storedItemErrorLimit = 50

    /// An item-error line as stored and shown: without trailing whitespace.
    /// restic ends its extended-attribute errors with a newline, which would
    /// break every sentence these lines are spliced into. Only the tail
    /// goes: a line starts with the item's own path, never touched.
    static func storedItemError(_ line: String) -> String {
        var line = line
        while line.last?.isWhitespace == true { line.removeLast() }
        return line
    }

    /// The start of the line the backup engine stores after the unreadable
    /// items when retention could not run behind a written snapshot. The
    /// plan page recognises the line by this prefix, so the engine's
    /// spelling must stay in sync — and records already in history carry
    /// these exact bytes.
    static let retentionSkippedPrefix = "Retention skipped: "

    /// What a completed-with-errors backup says when nothing more specific
    /// explains it — restic exited 3 and named nothing. The in-app banner and
    /// the plan page's status row both fall back to it, so the two agree
    /// word for word.
    static let unexplainedWarningMessage = "Finished, but restic reported problems."

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
        let cancelled = ResticError.isCancellation(error)
        outcome = cancelled ? .cancelled : .failed
        failureMessage = cancelled ? cancellationMessage : error.localizedDescription
    }
}
