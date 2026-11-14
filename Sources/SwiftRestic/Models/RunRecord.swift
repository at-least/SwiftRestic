import Foundation

struct RunRecord: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case backup, check, prune, restore

        var displayName: String {
            switch self {
            case .prune: MaintenanceTask.prune.displayName
            case .check: MaintenanceTask.check.displayName
            default: rawValue.capitalized
            }
        }
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded, completedWithErrors, failed, cancelled
        /// A drive that is away or a server out of reach: nothing was
        /// written. A skipped backup stamps its slot; no problem surface
        /// counts it (`detailText` says why).
        case skipped

        /// What every problem surface counts: Activity's Problems filter,
        /// the overview, a stretch, a retry.
        var isProblem: Bool { self == .failed || self == .completedWithErrors }

        /// Read through `RunRecord.outcomeName`, which words a warning by
        /// what the run met.
        fileprivate var displayName: String {
            switch self {
            case .succeeded: "Succeeded"
            case .completedWithErrors: "Completed with warnings"
            case .failed: "Failed"
            case .cancelled: "Stopped"
            case .skipped: "Skipped"
            }
        }

        /// Success wears nothing. Cancelled keeps a quiet outline so it is
        /// never misread as success.
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
    /// restic's words about the user's files. Capped at
    /// `storedItemErrorLimit` so a pathological run cannot bloat the
    /// history; `itemErrorCount` keeps the total.
    ///
    /// The order is relied on (`unreadableItems` slices it): the unreadable
    /// items first — sources restic skipped, then its error events — then
    /// the decoding-gap warning, then the "Retention skipped: …" line. Only
    /// the first group is counted.
    var itemErrors: [String] = []
    var itemErrorCount: Int = 0
    /// Keyed by the line, where restic named a path. By bytes: two lines
    /// that differ only in Unicode normalization name two items to restic.
    /// Nil: the lines get no per-item actions.
    var unreadableItemPaths: [PathKey: String]?
    /// The `backup`'s exit (0, or 3 when some source could not be read),
    /// else the first exit the run's transcript saw. Nil when restic never
    /// reached an exit (a launch failure, a stop by cancel or a cap).
    var exitCode: Int32?
    /// Counted over every item, past the stored cap. Nil: counted from
    /// `unreadableItems`.
    var itemErrorTally: ItemErrorDiagnosis.Tally?
    /// Lets the drawer tell "grant it" from "it has it now, back up again"
    /// from "macOS protects these anyway". Backups only.
    var fullDiskAccessAtRun: FullDiskAccessStatus?
    var failureMessage: String?
    /// `ResticError.resticDetail`, for the run's details text.
    var resticDetail: String?
    /// What `prune` freed, read from its plain text (no JSON output in
    /// restic 0.19.1), a check's verdict, or why a backup was skipped.
    var detailText: String?
    /// restic's `version` line when the run was stored.
    var resticVersion: String?

    // Restores only. A restore's `snapshotID` is the backup it read, never
    // a snapshot a run wrote: the snapshot→run join filters on
    // `kind == .backup`.

    var snapshotTime: Date?
    /// Nil for a whole backup or several items.
    var sourcePath: String?
    /// All from one folder of the backup (`RestoreBatch.Group`). Nil for
    /// one item or a whole backup.
    var sourcePaths: [String]?
    /// The restored item itself (what Show in Finder selects), or for a
    /// whole backup or several items, the folder they went into.
    var destinationPath: String?
    var filesRestored: Int = 0
    /// All a repeat restore reports (`files_skipped`, no `files_restored`
    /// key).
    var filesSkipped: Int = 0

    /// A backup failed because the plan's path is missing from this Mac and
    /// on no drive that is away (`folderGoneMessage(path:)`).
    var missingSources: [String]?

    /// By volume name: shares that refused to reconnect for a cause only the
    /// user clears (`ShareReconnect.Outcome.refused`), failing the run.
    var refusedShares: [String]?

    /// What the backup uploaded before the disk filled stays until a prune
    /// (`repositoryFullMessage`).
    var repositoryFull: Bool?

    // A standing skip (`continuingSkip(of:)`), or a standing failure for the
    // same folders gone or shares refused (`continuingStandingFailure(of:)`):
    // one record for every run it lasted. Nil for a run that stands alone.

    var skipCount: Int?
    /// When the first of them started.
    var skippedSince: Date?
    /// Snapshots the merged runs wrote before this record's own, newest
    /// first, each resolving to this record (`backupRunsBySnapshot`). No run
    /// writes it; it is read from stored records.
    var continuedSnapshotIDs: [String]?
    /// The IDs `restic rewrite` gave this run's snapshot since, oldest
    /// first, each resolving to this record (`backupRunsBySnapshot`), so a
    /// rewritten backup keeps its incomplete mark and its drawer. restic's
    /// `original` names only the snapshot just before, so the chain grows
    /// one listing at a time (`adoptingRewrites`).
    var rewrittenSnapshotIDs: [String]?

    /// `fillingProblemStretches`. Stored as the record is appended, before
    /// the history cap trims those before it.
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
        // Stored lines can carry restic's trailing newline.
        itemErrors = c.value(.itemErrors, default: [String]()).map(Self.storedItemError)
        itemErrorCount = c.value(.itemErrorCount, default: 0)
        unreadableItemPaths = c.optional(.unreadableItemPaths)
        exitCode = c.optional(.exitCode)
        itemErrorTally = c.optional(.itemErrorTally)
        fullDiskAccessAtRun = c.optional(.fullDiskAccessAtRun)
        // "Cancelled" is a stop's stored word in older records; unmapped, it
        // would show as a second message beside the outcome.
        let storedFailure: String? = c.optional(.failureMessage)
        failureMessage = storedFailure == "Cancelled" ? RunRecord.Outcome.cancelled.displayName : storedFailure
        resticDetail = c.optional(.resticDetail)
        detailText = c.optional(.detailText)
        resticVersion = c.optional(.resticVersion)
        snapshotTime = c.optional(.snapshotTime)
        sourcePath = c.optional(.sourcePath)
        sourcePaths = c.optional(.sourcePaths)
        destinationPath = c.optional(.destinationPath)
        filesRestored = c.value(.filesRestored, default: 0)
        filesSkipped = c.value(.filesSkipped, default: 0)
        missingSources = c.optional(.missingSources)
        refusedShares = c.optional(.refusedShares)
        repositoryFull = c.optional(.repositoryFull)
        skipCount = c.optional(.skipCount)
        skippedSince = c.optional(.skippedSince)
        continuedSnapshotIDs = c.optional(.continuedSnapshotIDs)
        rewrittenSnapshotIDs = c.optional(.rewrittenSnapshotIDs)
        problemStretch = c.optional(.problemStretch)
    }

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    /// The outcome in this kind's words. A backup's warnings are files it
    /// could not read, else old backups it could not remove; a
    /// verification's are damage.
    var outcomeName: String {
        guard outcome == .completedWithErrors else { return outcome.displayName }
        if kind == .check { return "Problems found" }
        let skippedFiles = itemErrorCount > 0 || exitCode == ResticError.backupPartialSuccessCode
        let retentionSkipped = trailingItemErrors.contains { $0.hasPrefix(Self.retentionSkippedPrefix) }
        return !skippedFiles && retentionSkipped ? "Old backups not removed" : Self.someFilesSkipped
    }

    static let someFilesSkipped = "Some files skipped"
}

extension RunRecord {
    static let storedItemErrorLimit = 50

    /// restic ends its extended-attribute errors with a newline, which would
    /// break every sentence these lines are spliced into. Only the tail goes:
    /// a line starts with the item's path.
    static func storedItemError(_ line: String) -> String {
        var line = line
        while line.last?.isWhitespace == true { line.removeLast() }
        return line
    }

    /// Stored when retention could not run after a written snapshot. The
    /// plan page recognises the line by it, and stored records carry these
    /// exact bytes.
    static let retentionSkippedPrefix = "Retention skipped: "
    static let retentionSkippedOnScreenPrefix = "Old backups not removed: "

    /// A skipped run's reason and its listing's words.
    static func serverUnreachableReason(repositoryName: String, why: String) -> String {
        "“\(repositoryName)” cannot be reached (\(why))."
    }

    /// restic exited 3 and named nothing. The banner and the plan page's
    /// status row share it.
    static let unexplainedWarningMessage = "Finished, but some items may not be backed up."

    /// restic keeps no such fact in the snapshot (`snapshots --json` has no
    /// error field), so the run record is the only place it lives.
    enum SnapshotCompleteness: Sendable, Equatable {
        case complete, incomplete, unknown
    }

    /// restic's exit code alone decides: 3 is "incomplete snapshot created"
    /// (`restic backup --help`). The outcome is no guide: retention skips
    /// and decoding gaps both come after a whole snapshot. Without an exit
    /// code, a record proves nothing unless it named an unreadable item, so
    /// it reads unknown, never complete.
    var snapshotCompleteness: SnapshotCompleteness? {
        guard kind == .backup, snapshotID != nil else { return nil }
        if let exitCode {
            return exitCode == ResticError.backupPartialSuccessCode ? .incomplete : .complete
        }
        return itemErrorCount > 0 ? .incomplete : .unknown
    }

    /// `unlisted` counts from restic's total, never the capped stored lines.
    func unreadableItemListing(limit: Int? = nil) -> (listed: ArraySlice<String>, unlisted: Int) {
        let listed = limit.map { unreadableItems.prefix($0) } ?? unreadableItems
        return (listed, max(0, itemErrorCount - listed.count))
    }

    /// `min`: past the cap, a bare `prefix(itemErrorCount)` would reach into
    /// the trailing lines. A scan-time complaint about an item the archiver
    /// then read fine (a permission changed mid-run) is still among them;
    /// restic gives no way to tell.
    var unreadableItems: ArraySlice<String> {
        itemErrors.prefix(min(itemErrorCount, Self.storedItemErrorLimit))
    }

    var trailingItemErrors: ArraySlice<String> {
        itemErrors.dropFirst(unreadableItems.count)
    }

    var trailingItemErrorsOnScreen: [String] {
        trailingItemErrors.map { line in
            guard line.hasPrefix(Self.retentionSkippedPrefix) else { return line }
            return Self.retentionSkippedOnScreenPrefix + line.dropFirst(Self.retentionSkippedPrefix.count)
        }
    }

    /// Keyed by full snapshot ID, not by repository: two repository entries
    /// pointing at one restic repository list the same snapshot. Backups
    /// only, so a restore never becomes a snapshot's status. Runs are stored
    /// newest first, and the first wins.
    static func backupRunsBySnapshot(_ runs: [RunRecord]) -> [String: RunRecord] {
        var map: [String: RunRecord] = [:]
        map.reserveCapacity(runs.count)
        for run in runs where run.kind == .backup {
            guard let snapshotID = run.snapshotID, map[snapshotID] == nil else { continue }
            map[snapshotID] = run
            for continued in (run.continuedSnapshotIDs ?? []) + (run.rewrittenSnapshotIDs ?? []) where map[continued] == nil {
                map[continued] = run
            }
        }
        return map
    }

    static func adoptingRewrites(_ runs: [RunRecord], listing: [Snapshot]) -> [RunRecord]? {
        var map = backupRunsBySnapshot(runs)
        var runs = runs
        var changed = false
        // Until nothing moves: a rewrite of a rewrite (one kept without
        // --forget) can list ahead of the snapshot it names.
        var adoptedThisPass = true
        while adoptedThisPass {
            adoptedThisPass = false
            for snapshot in listing where map[snapshot.id] == nil {
                guard let original = snapshot.original, let run = map[original],
                      let index = runs.firstIndex(where: { $0.id == run.id })
                else { continue }
                runs[index].rewrittenSnapshotIDs = (runs[index].rewrittenSnapshotIDs ?? []) + [snapshot.id]
                map[snapshot.id] = runs[index]
                adoptedThisPass = true
                changed = true
            }
        }
        return changed ? runs : nil
    }
}

extension RunRecord {
    /// restic 0.19.1, exit 1, no snapshot written.
    static let everySourceMissingMessage = "Fatal: all source directories/files do not exist"

    /// For Activity's Detail. A folder missing from this Mac is no skip
    /// (`folderGoneMessage(path:)`).
    static func skippedReason(sources: [String], reconnectFailures: [String: String] = [:]) -> String {
        guard let drives = notConnected(sources) else { preconditionFailure("a skip with a source not on a volume: \(sources)") }
        return drives + "." + reconnectClauses(reconnectFailures, sources: sources)
    }

    private static func reconnectClauses(_ failures: [String: String], sources: [String]) -> String {
        let volumes = BackupPlan.withoutDuplicates(volumeNames(sources).compactMap { $0 })
        return volumes.compactMap { volume in failures[volume].map { " Reconnecting “\(volume)” failed: \($0)." } }.joined()
    }

    /// nil for any other failure: restic's words stand.
    static func repositoryFullMessage(resticMessage: String, repository: Repository) -> String? {
        guard repository.kind == .local, resticMessage.contains("no space left on device") else { return nil }
        let root = ResticPath.normalized(repository.resolvedLocalPath)
        // restic names the file it was writing: "write <repository>/data/…".
        guard resticMessage.contains("write \(root)/") else { return nil }
        let disk = VolumePresence.volumeName(of: root).map { "“\($0)”" } ?? "This Mac’s disk"
        return "\(disk) is full — the backup needed more room than it has free. "
            + "What it uploaded before it stopped stays in the location until space is freed."
    }

    /// The plan's folder is not on this Mac and no drive it could wait for
    /// is away. Locate Folder… is `AppModel.movePlan`.
    static func folderGoneMessage(path: String) -> String {
        "“\((path as NSString).lastPathComponent)” is not on this Mac — it was moved, renamed or deleted. "
            + "Put it back, or click Locate Folder… to back it up where it is now."
    }

    /// `previous`: the plan's newest backup before this one. The same
    /// folders gone or shares refused make one record, counted as a
    /// standing skip is, so an hourly plan whose folder was deleted is one
    /// row and one notification, not one an hour.
    func continuingStandingFailure(of previous: RunRecord) -> RunRecord? {
        guard continuesPlanBackup(previous),
              outcome == .failed, previous.outcome == .failed,
              missingSources != nil || refusedShares != nil,
              missingSources == previous.missingSources, refusedShares == previous.refusedShares
        else { return nil }
        return merged(after: previous)
    }

    static func notConnected(_ sources: [String]) -> String? {
        let found = volumeNames(sources)
        guard !found.isEmpty, !found.contains(nil) else { return nil }
        let names = BackupPlan.withoutDuplicates(found.compactMap { $0 }).map { "“\($0)”" }
        return "\(Format.list(names)) \(names.count == 1 ? "is" : "are") not connected"
    }

    private static func volumeNames(_ sources: [String]) -> [String?] {
        sources.map { VolumePresence.volumeName(of: ResticService.expandTilde($0)) }
    }

    private func continuesPlanBackup(_ previous: RunRecord) -> Bool {
        kind == .backup && previous.kind == .backup
            && planID != nil && previous.planID == planID && previous.repositoryID == repositoryID
    }

    private func merged(after previous: RunRecord) -> RunRecord {
        var merged = self
        merged.skipCount = (previous.skipCount ?? 1) + 1
        merged.skippedSince = previous.skippedSince ?? previous.startedAt
        return merged
    }

    /// `previous`: the plan's newest backup before this one. The same reason
    /// and stored lines (a retention skip is news) make one record, so an
    /// hourly plan whose drive is away a week is one row, not 168, and
    /// leaves the history cap to real runs.
    func continuingSkip(of previous: RunRecord) -> RunRecord? {
        guard continuesPlanBackup(previous),
              outcome == .skipped, previous.outcome == .skipped,
              detailText == previous.detailText, itemErrors == previous.itemErrors
        else { return nil }
        return merged(after: previous)
    }

    /// `cancellationMessage`: the caller says whether the user stopped it or
    /// the app quit.
    mutating func setOutcome(
        from error: Error,
        cancellationMessage: String,
        location: (name: String, kind: Repository.Kind)?
    ) {
        let cancelled = ResticError.isCancellation(error)
        outcome = cancelled ? .cancelled : .failed
        failureMessage = cancelled ? cancellationMessage : ResticError.words(for: error, location: location)
        resticDetail = (error as? ResticError)?.resticDetail
    }
}

extension RunRecord {
    func isBackup(ofPlan planID: UUID?) -> Bool {
        kind == .backup && self.planID == planID
    }
}
