import Foundation

/// The one action that fixes a failure whose cause the app knows, offered in
/// the Activity drawer and the plan's problem row.
enum RunFix: Equatable {
    /// The password is missing, or restic exit 12: the stored one does not
    /// open the repository. Prompts for the password alone
    /// (`PasswordPromptSheet`).
    case enterPassword(UUID)
    /// restic exit 10 on a server or in the cloud. Those locations are
    /// fixed, so where the repository is now takes a new repository, which
    /// the missing one's plans move to (`AppModel.movePlans`).
    case addRepository(UUID)
    /// restic exit 10 on a disk, or a drive that never comes back under its
    /// name: pick the folder it moved to (`AppModel.locateRepository`).
    case locate(UUID)
    /// The plan's folder is not on this Mac (`RunRecord.missingSources`). A
    /// plan's path is fixed, so the folder's new place takes a new plan in
    /// the same repository, replacing this one (`AppModel.movePlan(id:toPath:)`).
    case locateFolder(planID: UUID)
    /// A network share in `RunRecord.refusedShares` refused to reconnect:
    /// its password alone (`AppRouter.Intent.enterSharePassword`).
    case enterSharePassword(ShareOwner)
    /// The disk filled up during a backup (`RunRecord.repositoryFull`): a
    /// prune frees what the failed run uploaded. Runs at once: the failure
    /// already asked for it.
    case freeUpSpace(UUID)

    /// What the refused share holds: the repository's own folder, else the
    /// plan's.
    enum ShareOwner: Equatable {
        case repository(UUID)
        case plan(UUID)
    }

    var title: String {
        switch self {
        case .enterPassword: "Enter Password…"
        case .enterSharePassword: "Enter Share Password…"
        case .addRepository: "Add Backup Location…"
        case .locate: "Locate…"
        case .locateFolder: "Locate Folder…"
        case .freeUpSpace: "Free Up Space"
        }
    }

    /// The fact the failure message beside the button lacks; nil where the
    /// message already says it.
    var help: String? {
        switch self {
        case .enterPassword, .addRepository, .locate, .locateFolder, .freeUpSpace: nil
        case .enterSharePassword: "SwiftRestic uses this password to reconnect the network share"
        }
    }
}

struct UnreadableItemWords: Equatable {
    var name: String
    var location: String
    var reason: String
}

/// Runs at once from the drawer where the verdict is read: the failed run
/// already asked for it.
enum MaintenanceRetry: Equatable {
    case check(UUID)
    case prune(UUID)

    var title: String {
        switch self {
        case .check: "Verify Again"
        case .prune: "Free Up Space Again"
        }
    }

    var repositoryID: UUID {
        switch self {
        case let .check(id), let .prune(id): id
        }
    }
}

/// A run's words outside its log: the Activity Detail column, the drawer's
/// rows, the copied details, and the name every app-wide surface calls the
/// run by. Built on `PlanStatus.facts(for:)` so Activity and the plan row
/// cannot disagree.
enum RunRecordPresentation {
    static func maintenanceRetry(for run: RunRecord, repositoryExists: Bool) -> MaintenanceRetry? {
        guard repositoryExists, let id = run.repositoryID,
              run.outcome.isProblem
        else { return nil }
        switch run.kind {
        case .check: return .check(id)
        case .prune: return .prune(id)
        case .backup, .forget, .restore: return nil
        }
    }

    /// A check that found damage goes to the restic console: its verdict
    /// advises restic's repair commands, and the console is where the
    /// repository's password is supplied.
    static func repairRoute(for run: RunRecord, repositoryExists: Bool) -> UUID? {
        guard repositoryExists, run.kind == .check, run.outcome == .completedWithErrors else { return nil }
        return run.repositoryID
    }

    /// Only while the repository is still set up.
    static func fix(
        for run: RunRecord,
        repositoryExists: Bool,
        planExists: Bool = true,
        repositoryVolume: String? = nil,
        repositoryIsLocal: Bool = false
    ) -> RunFix? {
        guard run.outcome == .failed, let repositoryID = run.repositoryID, repositoryExists else { return nil }
        if run.missingSources != nil {
            guard let planID = run.planID, planExists else { return nil }
            return .locateFolder(planID: planID)
        }
        if let refusedShares = run.refusedShares {
            if let repositoryVolume, refusedShares.contains(repositoryVolume) {
                return .enterSharePassword(.repository(repositoryID))
            }
            guard let planID = run.planID, planExists else { return nil }
            return .enterSharePassword(.plan(planID))
        }
        if run.repositoryFull == true { return .freeUpSpace(repositoryID) }
        if run.exitCode == ResticError.wrongPasswordCode { return .enterPassword(repositoryID) }
        if run.exitCode == ResticError.repositoryMissingCode {
            return repositoryIsLocal ? .locate(repositoryID) : .addRepository(repositoryID)
        }
        return nil
    }

    /// The subject line the log and the copied details open with.
    static func subject(of run: RunRecord) -> String {
        guard !run.planName.isEmpty else { return run.kind.displayName }
        if run.kind == .forget { return "Removing old backups of “\(run.planName)”" }
        return "\(run.kind.displayName) of “\(run.planName)”"
    }

    /// The one way a plan and its repository are said in a single string.
    /// A repository named exactly like the plan is not said twice, the rule
    /// Activity's Subject and Repository columns also follow.
    static func planWithRepository(_ planName: String, repositoryName: String?) -> String {
        guard !planName.isEmpty else { return planName }
        guard let repositoryName, !repositoryName.isEmpty, repositoryName != planName else {
            return planName
        }
        return "\(planName) (\(repositoryName))"
    }

    static func planWithRepository(_ plan: BackupPlan, plans: [BackupPlan], repositories: [Repository]) -> String {
        planWithRepository(plan.label(among: plans), repositoryName: repositories.withID(plan.repositoryID).map { $0.label(among: repositories) })
    }

    /// The run's name where a surface has one string for it (notification
    /// title, tray problem line). Derived from IDs at
    /// render time because `planName` is overloaded storage: the plan for a
    /// backup, the repository for a check or prune, a step label for a
    /// restore. An ID that no longer resolves falls back to the stored name
    /// on purpose: the record outlives its plan, and the name it was
    /// recorded under is the truest one left.
    static func displayName(
        for run: RunRecord,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String {
        let repositoryName = repositories.withID(run.repositoryID).map { $0.label(among: repositories) }
        switch run.kind {
        case .backup, .forget, .restore:
            // A restore carries no planID, so its step label (the stored
            // name) is its subject.
            return planWithRepository(currentPlanName(of: run, plans: plans), repositoryName: repositoryName)
        case .check, .prune:
            // The stored planName holds the repository once it is gone.
            return repositoryName ?? run.planName
        }
    }

    private static func currentPlanName(of run: RunRecord, plans: [BackupPlan]) -> String {
        run.planID.flatMap { plans.withID($0)?.label(among: plans) } ?? run.planName
    }

    /// Settings' "Next backup" line, in the tray headline's words.
    static func nextRunLine(plan: BackupPlan, date: Date, plans: [BackupPlan], repositories: [Repository]) -> String {
        let name = planWithRepository(plan, plans: plans, repositories: repositories)
        return "\(name) — \(Format.tileTimestamp(date))"
    }

    /// Problems are counted as the plan page counts them: restic's count,
    /// never the stored lines.
    static func detail(for run: RunRecord) -> String {
        // The first sentence: the drawer, plan page and copied details show
        // the whole message.
        if let failure = run.failureMessage {
            let reason = Format.firstSentence(failure)
        // A standing failure for the same folders gone, as a skip.
            guard let count = run.skipCount, let since = run.skippedSince else { return reason }
            let sentence = Format.fullSentence(reason)
            return "\(sentence) Failed \(count) times since \(Format.timestamp(since))."
        }
        // Why there was nothing to back up, and how long it has stood.
        if run.kind == .backup, run.outcome == .skipped, let reason = run.detailText {
            guard let count = run.skipCount, let since = run.skippedSince else { return reason }
            return "\(reason) Skipped \(count) times since \(Format.timestamp(since))."
        }
        // An unnamed exit 3 is among the facts, so the plan row says it too.
        let facts = PlanStatus.facts(for: run)
        if !facts.isEmpty { return facts.joined(separator: " · ") }
        switch run.kind {
        case .backup:
            // A reporting gap, alone: the line explains itself.
            if run.outcome == .completedWithErrors, let line = run.trailingItemErrorsOnScreen.first {
                return line
            }
            return "\(Format.count(run.filesNew)) new · \(Format.count(run.filesChanged)) changed"
        case .restore:
            return restoreDetail(run) ?? run.outcomeName
        case .forget, .prune:
            // Freed space whose amount restic's output did not say has no
            // count.
            return run.detailText ?? run.outcomeName
        case .check:
            // The glyph already says the outcome; the count is what the
            // column adds. No final period: the column's other entries ("2
            // unreadable items", "0 new · 1 changed") carry none.
            guard let verdict = run.detailText else { return run.outcomeName }
            return Format.withoutFinalPeriod(Format.firstSentence(verdict))
        }
    }

    /// For a row that continues a line ("22 hours ago · 2 errors found"):
    /// the outcome lowercased when the detail is only the outcome.
    static func verdictClause(for run: RunRecord) -> String {
        let detail = detail(for: run)
        return detail == run.outcomeName ? detail.lowercased() : detail
    }

    /// The item's name, where it is (inside the plan folder that holds it,
    /// else on disk) and why. Nil for a line with no stored path, which stays
    /// restic's own.
    static func unreadableItemWords(line: String, path: String?, sources: [String]) -> UnreadableItemWords? {
        guard let path else { return nil }
        let parent = ResticPath.parent(of: path)
        // Not a whole-disk plan's "/": its name says nothing of where the
        // item is, so the item reads as on disk, tilde and all.
        let tops = sources.map { ResticPath.normalized(ResticService.expandTilde($0)) }.filter { $0 != "/" }
        let location = if let top = Format.containingRoot(of: parent, in: tops) {
            // `containingRoot` matched, so `top` is a byte prefix of `parent`.
            ResticPath.basename(of: top) + parent.removingBytePrefix(top)!
        } else {
            (parent as NSString).abbreviatingWithTildeInPath
        }
        return UnreadableItemWords(
            name: ResticPath.basename(of: path), location: location, reason: unreadableReason(line: line, path: path)
        )
    }

    static func unreadableReason(line: String, path: String) -> String {
        switch ItemErrorDiagnosis.kind(of: line) {
        case .deniedByFilePermissions: "permission denied"
        case .blockedByMacOS: "blocked by macOS"
        case .other:
            if line.hasByteSuffix(ResticService.missingSourceSuffix) {
                "not on this Mac"
            } else if line.hasByteSuffix(ResticService.inaccessibleSourceSuffix) {
                "can’t be accessed"
            } else {
                line.removingBytePrefix(path + ": ") ?? line
            }
        }
    }

    /// Nil for a restore that says nothing countable: the caller shows the
    /// outcome.
    private static func restoreDetail(_ run: RunRecord) -> String? {
        guard run.outcome == .succeeded else { return nil }
        if run.filesRestored == 0, run.filesSkipped > 0 {
            return "\(Format.plural(run.filesSkipped, "file")) \(kept(run.filesSkipped)) — nothing restored"
        }
        guard run.filesRestored > 0 else { return nil }
        let restored = "\(Format.plural(run.filesRestored, "file")), \(Format.bytes(run.bytesProcessed))"
        return run.filesSkipped > 0 ? "\(restored) · \(Format.count(run.filesSkipped)) \(kept(run.filesSkipped))" : restored
    }

    /// What Keep did with files already at the landing, in the restore
    /// banner's words.
    static func kept(_ count: Int) -> String {
        count == 1 ? "kept as it was" : "kept as they were"
    }

    /// Bare: the failure text above it already says what went wrong, and a
    /// gloss would be wrong for some commands (`forget`'s 3 is a refused
    /// deletion, `check`'s 1 a damaged-repository verdict). Nil for 0.
    static func exitCodeText(_ code: Int32) -> String? {
        code == 0 ? nil : String(code)
    }

    /// A run that failed or was stopped before restic summarised has only
    /// zeros, which would read as "nothing changed".
    static func hasBackupNumbers(_ run: RunRecord) -> Bool {
        guard run.outcome == .failed || run.outcome == .cancelled || run.outcome == .skipped else { return true }
        return run.filesNew + run.filesChanged + run.filesUnmodified > 0
            || run.bytesProcessed > 0 || run.dataAdded > 0
    }

    static func backupFiles(_ run: RunRecord) -> String {
        "\(Format.count(run.filesNew)) new · \(Format.count(run.filesChanged)) changed · \(Format.count(run.filesUnmodified)) unchanged"
    }

    static func backupSize(_ run: RunRecord) -> String {
        "Checked \(Format.bytes(run.bytesProcessed)) · \(Format.bytes(run.dataAdded)) of new data"
    }

    static func restoreFiles(_ run: RunRecord) -> String {
        var text = "\(Format.count(run.filesRestored)) restored"
        if run.filesSkipped > 0 { text += " · \(Format.count(run.filesSkipped)) \(kept(run.filesSkipped))" }
        return text + " · \(Format.bytes(run.bytesProcessed))"
    }

    /// Edit ▸ Copy on an Activity row: the run as plain text for a forum
    /// post or an issue.
    static func detailsText(for run: RunRecord, repositoryName: String?, versionsNow: RunLogVersions) -> String {
        var lines = [
            "\(subject(of: run)) — \(run.outcomeName)",
            "Started: \(Format.timestamp(run.startedAt)) (\(Format.duration(run.duration)))",
            "Location: \(repositoryName ?? "No longer set up in SwiftRestic")",
        ]
        if let failure = run.failureMessage, failure != run.outcomeName {
            lines.append("Error: \(failure)")
        }
        if let detail = run.resticDetail { lines.append("restic: \(detail)") }
        if let snapshotID = run.snapshotID {
            let made = run.kind == .restore ? run.snapshotTime.map { " (\(Format.timestamp($0)))" } ?? "" : ""
            lines.append("Backup: \(snapshotID)\(made)")
        }
        switch run.kind {
        case .backup:
            // Why it was skipped, before what the rest added when a snapshot
            // was written anyway.
            if run.outcome == .skipped, let reason = run.detailText { lines.append("Skipped: \(reason)") }
            if let since = run.skippedSince, let count = run.skipCount {
                let label = run.outcome == .failed ? "Failing since" : "Skipped since"
                lines.append("\(label): \(Format.timestamp(since)) (\(Format.plural(count, "time")))")
            }
            if hasBackupNumbers(run) {
                lines.append("Files: \(backupFiles(run))")
                lines.append("Size: \(backupSize(run))")
            }
        case .restore:
            // A record with no stored destination says nothing: "Entire
            // backup" would be a guess about it.
            if let destination = run.destinationPath {
                if let paths = run.sourcePaths {
                    lines.append("Items: \(paths.joined(separator: ", "))")
                } else {
                    lines.append("Item: \(run.sourcePath ?? "Entire backup")")
                }
                lines.append("\(run.outcome == .succeeded ? "Restored to" : "Destination"): \(destination)")
            }
            if run.outcome == .succeeded, run.filesRestored + run.filesSkipped > 0 {
                lines.append("Files: \(restoreFiles(run))")
            }
        case .check, .forget, .prune:
            if let result = run.detailText { lines.append("Result: \(result)") }
        }
        if let code = run.exitCode, let text = exitCodeText(code) {
            lines.append("restic exit: \(text)")
        }
        if run.itemErrorCount > 0 {
            lines.append("Unreadable items (\(Format.count(run.itemErrorCount))):")
            lines += run.unreadableItems.map { "  \($0)" }
            let unlisted = run.itemErrorCount - run.unreadableItems.count
            if unlisted > 0 { lines.append("  … and \(Format.count(unlisted)) more") }
        }
        // The decoding gap and the retention skip explain themselves.
        lines += run.trailingItemErrorsOnScreen
        if let version = run.resticVersion { lines.append(version) }
        lines.append("Copied from \(versionsNow.app) on \(versionsNow.macOS)")
        return lines.joined(separator: "\n")
    }
}
