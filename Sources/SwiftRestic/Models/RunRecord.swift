import Foundation

/// The stored outcome of one backup, check, prune or restore run.
struct RunRecord: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case backup, forget, check, prune, restore

        /// The operation's word in titles and rows: "Backup", "Check", …
        /// A forget is "Retention", the word every other surface uses for it
        /// (the plan page's row, Apply Retention Now, "Retention skipped");
        /// a prune is the maintenance task's own word.
        var displayName: String {
            switch self {
            case .forget: "Retention"
            case .prune: MaintenanceTask.prune.displayName
            default: rawValue.capitalized
            }
        }

        /// The webhook payload's `operation`, which receivers match on: the
        /// words it carried before the app called a prune a cleanup, so a
        /// rename on screen never changes what a filter reads.
        var payloadOperation: String {
            switch self {
            case .forget: "Retention"
            default: rawValue.capitalized
            }
        }
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded, completedWithErrors, failed, cancelled
        /// A run whose plan's folder or repository is on a drive that is
        /// away, or whose network repository's server is out of reach:
        /// nothing was written. A skipped backup stamps its slot; no
        /// problem surface counts it (`detailText` says why).
        case skipped

        /// What every problem surface counts — Activity's Problems filter,
        /// the overview, a stretch, a retry: a failure, or a run that
        /// finished with warnings.
        var isProblem: Bool { self == .failed || self == .completedWithErrors }

        var displayName: String {
            switch self {
            case .succeeded: "Succeeded"
            case .completedWithErrors: "Completed with warnings"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            case .skipped: "Skipped"
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
            case .skipped: "minus.circle"
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
    /// The path each stored unreadable line names, keyed by the line, where
    /// restic named one (`ResticService.unreadableItemPaths`). Nil on records
    /// written before it was kept: their lines get no per-item actions.
    var unreadableItemPaths: [String: String]?
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
    /// Retention Now removed — the Result row of a check or a forget in
    /// the drawer and Copy Details (a check's in its log too), and a
    /// forget's Activity Detail and banner.
    var detailText: String?
    /// restic's `version` line when the run was stored, for Copy Details and
    /// the log header. Nil on records from before it was kept.
    var resticVersion: String?
    /// Whether `Logs/<id>.log` was written for this run. False on records
    /// from before logs existed and when the write failed, so Show Log
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
    /// Where it landed: the restored item itself (what Show in Finder
    /// selects), or for a whole backup or several items, the folder they
    /// were restored into.
    var destinationPath: String?
    var filesRestored: Int = 0
    /// Files restic left as they were because the destination already held
    /// them — all a repeat restore reports (`files_skipped`, no
    /// `files_restored` key).
    var filesSkipped: Int = 0

    /// The plan's path when a backup failed because it is missing from this
    /// Mac and on no drive that is away (`folderGoneMessage(path:)`). Nil
    /// for any other run.
    var missingSources: [String]?

    /// The network shares a backup, check or prune needed that refused to
    /// reconnect for a cause only the user clears
    /// (`ShareReconnect.Outcome.refused`), by volume name: the run failed
    /// for them. Nil for any other run.
    var refusedShares: [String]?

    /// True when a backup failed because the repository's disk filled up
    /// (`repositoryFullMessage`): what it uploaded before it stopped stays
    /// until a prune. Nil for any other run.
    var repositoryFull: Bool?

    /// How many snapshots the repository refused to delete when the run's
    /// retention ran (`ResticError.snapshotsNotRemoved`) — an append-only
    /// server, a locked bucket: the plan's editor is the fix. Nil for any
    /// other run.
    var retentionRefused: Int?

    /// What a check read besides the structure, in the repository page's
    /// words — "part 3 of 12", "5% of the data", "all of the data" — or
    /// "structure only". Nil for any other run, and for a check an older
    /// build recorded.
    var checkRead: String?

    /// A check an older build recorded stored "data slice 3 of 12",
    /// "5% of data" or "all data"; read in today's words, so Last check
    /// never mixes the two.
    static func currentCheckWords(_ stored: String) -> String {
        if stored == "all data" { return "all of the data" }
        if stored.hasSuffix("% of data") { return stored.dropLast("data".count) + "the data" }
        if stored.hasPrefix("data slice ") { return "part " + stored.dropFirst("data slice ".count) }
        return stored
    }

    // A standing skip (`continuingSkip(of:)`), or a standing failure for the
    // same folders gone or shares refused (`continuingStandingFailure(of:)`):
    // one record for every run it lasted. Nil for a run that stands alone.

    /// How many runs the record stands for.
    var skipCount: Int?
    /// When the first of them started.
    var skippedSince: Date?
    /// The snapshots the runs this record counts wrote before its own,
    /// newest first — a backup around an away drive wrote one per run, in
    /// older builds whose plans held several folders. Each
    /// resolves to this record (`backupRunsBySnapshot`), so an earlier
    /// backup keeps its incomplete mark and its drawer after the merge. Nil
    /// for a whole skip's record; no run writes it now.
    var continuedSnapshotIDs: [String]?

    /// A failed or completed-with-errors backup's stretch: how many of its
    /// plan's backups in a row, this one the last, ended the same way for
    /// the same cause (`fillingProblemStretches`). Stored as the record is
    /// appended, before the history cap trims those before it. Nil for any
    /// other run.
    var problemStretch: Int?

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
        unreadableItemPaths = c.optional(.unreadableItemPaths)
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
        missingSources = c.optional(.missingSources)
        refusedShares = c.optional(.refusedShares)
        repositoryFull = c.optional(.repositoryFull)
        retentionRefused = c.optional(.retentionRefused)
        checkRead = (c.optional(.checkRead) as String?).map(Self.currentCheckWords)
        skipCount = c.optional(.skipCount)
        skippedSince = c.optional(.skippedSince)
        continuedSnapshotIDs = c.optional(.continuedSnapshotIDs)
        problemStretch = c.optional(.problemStretch)
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

    /// A network repository's server out of reach (`ServerProbe`): "“Home
    /// Server” cannot be reached (connection refused)." — a skipped run's
    /// reason and its listing's words.
    static func serverUnreachableReason(repositoryName: String, why: String) -> String {
        "“\(repositoryName)” cannot be reached (\(why))."
    }

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

    /// The unreadable items a surface lists and how many more Activity's
    /// drawer holds past them, counted from restic's total (`itemErrorCount`),
    /// never the stored lines, which are capped: the drawer lists every
    /// stored line, the plan page's card the first few
    /// (`PlanStatus.listedItemLimit`).
    func unreadableItemListing(limit: Int? = nil) -> (listed: ArraySlice<String>, unlisted: Int) {
        let listed = limit.map { unreadableItems.prefix($0) } ?? unreadableItems
        return (listed, max(0, itemErrorCount - listed.count))
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
            for continued in run.continuedSnapshotIDs ?? [] where map[continued] == nil {
                map[continued] = run
            }
        }
        return map
    }
}

extension RunRecord {
    /// restic's fatal line when every source of a backup is missing
    /// (restic 0.19.1, exit 1, no snapshot written).
    static let everySourceMissingMessage = "Fatal: all source directories/files do not exist"

    /// Why a backup was skipped, for Activity's Detail: the drives its
    /// folders — or the repository — live on, every one away, and why each
    /// network share among them could not be reconnected
    /// (`ShareReconnect`). A folder missing from this Mac is no skip
    /// (`folderGoneMessage(path:)`).
    static func skippedReason(sources: [String], reconnectFailures: [String: String] = [:]) -> String {
        guard let drives = notConnected(sources) else { preconditionFailure("a skip with a source not on a volume: \(sources)") }
        return drives + "." + reconnectClauses(reconnectFailures, sources: sources)
    }

    /// " Reconnecting “NAS” failed: the server could not be reached." for
    /// each drive of `sources` whose share failed, in the order they name
    /// them; empty when none did.
    private static func reconnectClauses(_ failures: [String: String], sources: [String]) -> String {
        var volumes: [String] = []
        for source in sources {
            if let volume = VolumePresence.volumeName(of: (source as NSString).expandingTildeInPath), !volumes.contains(volume) {
                volumes.append(volume)
            }
        }
        return volumes.compactMap { volume in failures[volume].map { " Reconnecting “\(volume)” failed: \($0)." } }.joined()
    }

    /// A backup's failure in plain words when restic could not write into
    /// the local repository's folder for want of space — "“TinyDisk” is
    /// full — …", naming the drive, or this Mac's disk — and what the failed
    /// run left behind; nil for any other failure, restic's words standing.
    static func repositoryFullMessage(resticMessage: String, repository: Repository) -> String? {
        guard repository.kind == .local, resticMessage.contains("no space left on device") else { return nil }
        var root = repository.resolvedLocalPath
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        // restic names the file it was writing: "write <repository>/data/…".
        guard resticMessage.contains("write \(root)/") else { return nil }
        let disk = VolumePresence.volumeName(of: root).map { "“\($0)”" } ?? "This Mac’s disk"
        return "\(disk) is full — the backup needed more room than it has free. "
            + "What it uploaded before it stopped stays in the repository until a cleanup frees it."
    }

    /// Why a backup failed when the plan's folder is not on this Mac and no
    /// drive it could wait for is away: named, and what to do — a plan's
    /// path is fixed, so where the folder is now takes a new plan.
    static func folderGoneMessage(path: String) -> String {
        "“\((path as NSString).lastPathComponent)” is not on this Mac — it was moved, renamed or deleted. "
            + folderGoneAdvice
    }

    /// What to do about a plan's folder gone from this Mac — a failed
    /// backup's words and the Files tab's (`FolderAbsence.remedy`).
    static let folderGoneAdvice = "Put it back, or back it up where it is now with a new plan."

    /// This failure as the continuation of `previous`, the plan's newest
    /// backup before it, failed for the same cause only the user clears —
    /// the same folders gone (`missingSources`) or network shares refused
    /// (`refusedShares`) — and carrying no hook's complaint: one record,
    /// this run's, counting the runs as a standing skip does
    /// (`continuingSkip(of:)`, whose fields it shares). An hourly plan whose
    /// folder was deleted, or whose share's password changed, is one row and
    /// one notification, not one an hour. Nil when it does not continue it.
    func continuingStandingFailure(of previous: RunRecord) -> RunRecord? {
        guard kind == .backup, previous.kind == .backup,
              let planID, previous.planID == planID, previous.repositoryID == repositoryID,
              outcome == .failed, previous.outcome == .failed,
              missingSources != nil || refusedShares != nil,
              missingSources == previous.missingSources, refusedShares == previous.refusedShares,
              previous.hookMessages.isEmpty
        else { return nil }
        var merged = self
        merged.skipCount = (previous.skipCount ?? 1) + 1
        merged.skippedSince = previous.skippedSince ?? previous.startedAt
        return merged
    }

    /// A backup that went around an away drive's folders and wrote a
    /// snapshot of the rest: the rest is backed up, the drive's folders are
    /// not, which the Protection card names and a later whole backup heals.
    /// Only older builds, whose plans held several folders,
    /// recorded one — a plan of one path is backed up or skipped whole —
    /// and the history keeps them.
    var isPartialSkip: Bool {
        kind == .backup && outcome == .skipped && snapshotID != nil
    }

    /// "“Archive SSD” is not connected", naming each drive once, or nil
    /// when a source is not on a volume under /Volumes.
    static func notConnected(_ sources: [String]) -> String? {
        var volumes: [String] = []
        for source in sources {
            guard let volume = VolumePresence.volumeName(of: (source as NSString).expandingTildeInPath) else { return nil }
            if !volumes.contains(volume) { volumes.append(volume) }
        }
        guard !volumes.isEmpty else { return nil }
        let names = volumes.map { "“\($0)”" }
        return "\(Format.list(names)) \(names.count == 1 ? "is" : "are") not connected"
    }

    /// This skipped backup as the continuation of `previous` — the plan's
    /// newest backup before it, skipped for the same reason, the same
    /// stored lines (a retention skip is news) and `previous` carrying no
    /// hook's complaint: one record, this run's, counting `previous`'s runs
    /// and keeping when the skips began. An hourly plan whose drive is away
    /// a week is one row, not 168, and leaves the history cap to real runs.
    /// A skip writes no snapshot; one an earlier build stored with a
    /// snapshot of the other folders (`isPartialSkip`) stays its own
    /// record, keeping that snapshot's run. Nil when it does not continue
    /// it.
    func continuingSkip(of previous: RunRecord) -> RunRecord? {
        guard kind == .backup, previous.kind == .backup,
              let planID, previous.planID == planID, previous.repositoryID == repositoryID,
              outcome == .skipped, previous.outcome == .skipped,
              (snapshotID == nil) == (previous.snapshotID == nil),
              detailText == previous.detailText, itemErrors == previous.itemErrors, previous.hookMessages.isEmpty
        else { return nil }
        var merged = self
        merged.skipCount = (previous.skipCount ?? 1) + 1
        merged.skippedSince = previous.skippedSince ?? previous.startedAt
        return merged
    }

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

extension RunRecord {
    /// A backup run of the plan `planID` names.
    func isBackup(ofPlan planID: UUID?) -> Bool {
        kind == .backup && self.planID == planID
    }
}
