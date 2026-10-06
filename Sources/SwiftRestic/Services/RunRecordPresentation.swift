import Foundation

/// A run's words outside its log: the Activity Detail column, the drawer's
/// rows, Copy Details, and the name every app-wide surface calls the run by.
/// The one place a run's one-line summary is worded, built on the plan
/// page's facts (`PlanStatus.facts(for:)`) so Activity and the plan row
/// cannot disagree.
enum RunRecordPresentation {
    /// "Backup of “Documents”", "Restore of “Budget.numbers”", "Check of
    /// “Home NAS”" — the subject line the log and Copy Details open with.
    static func subject(of run: RunRecord) -> String {
        let kind = run.kind.displayName
        return run.planName.isEmpty ? kind : "\(kind) of “\(run.planName)”"
    }

    /// "Documents (Home Disk)" — the one way a plan and its repository are
    /// said in a single string, wherever a surface must name both (the run
    /// surfaces below, the tray's "Next:" headline, Settings' Next run
    /// line). A repository named exactly like the plan is not said twice —
    /// one fact, one hearing, the rule Activity's Subject and Repository
    /// columns also follow.
    static func planWithRepository(_ planName: String, repositoryName: String?) -> String {
        guard !planName.isEmpty else { return planName }
        guard let repositoryName, !repositoryName.isEmpty, repositoryName != planName else {
            return planName
        }
        return "\(planName) (\(repositoryName))"
    }

    /// `planWithRepository` for a plan, its repository looked up among
    /// `repositories`.
    static func planWithRepository(_ plan: BackupPlan, repositories: [Repository]) -> String {
        planWithRepository(plan.name, repositoryName: repositories.first { $0.id == plan.repositoryID }?.name)
    }

    /// What a run is called by the surfaces that have one string for it:
    /// the log sheet's header, the local notification's title, the tray's
    /// problem line. Derived from IDs at render time — the plan by its
    /// current name, check and prune by the repository `repositoryID` names
    /// — because `planName` is overloaded storage: the plan for a backup,
    /// the repository for a check or prune, a step label for a restore. An
    /// ID that no longer resolves falls back to the stored name, which is
    /// honest history rather than a silent fallback: the record outlives
    /// its plan, and the name it was recorded under is the truest one it
    /// has left.
    static func displayName(
        for run: RunRecord,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String {
        let repositoryName = repositories.first { $0.id == run.repositoryID }?.name
        switch run.kind {
        case .backup, .forget, .restore:
            // The plan's name as it is called now. A restore carries no
            // planID, so its step label is the stored name — the label is
            // its subject.
            let planName = run.planID.flatMap { id in plans.first { $0.id == id }?.name } ?? run.planName
            return planWithRepository(planName, repositoryName: repositoryName)
        case .check, .prune:
            // The repository is the subject; the stored planName already
            // holds it when the repository is gone.
            return repositoryName ?? run.planName
        }
    }

    /// The run log sheet's header: "Backup log — Documents (Home Disk)",
    /// "Check log — Home Disk". A derivation rather than view text so the
    /// header's words are pinned with the naming rule they follow.
    static func logSheetTitle(
        for run: RunRecord,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String {
        "\(run.kind.displayName) log — \(displayName(for: run, plans: plans, repositories: repositories))"
    }

    /// Settings ▸ General ▸ Scheduling's "Next run" line, in the tray
    /// headline's words: the plan with its repository, then when — the
    /// timestamp clock, as Settings has always said the date.
    static func nextRunLine(plan: BackupPlan, date: Date, repositories: [Repository]) -> String {
        let name = planWithRepository(plan, repositories: repositories)
        return "\(name) — \(Format.timestamp(date))"
    }

    /// The Activity Detail column: why a run failed, else its problems as
    /// the plan page counts them ("1 unreadable item · Retention skipped" —
    /// restic's count, never the stored lines), else what it did.
    static func detail(for run: RunRecord) -> String {
        if let failure = run.failureMessage { return failure }
        // An unnamed exit 3 is among the facts, so the plan row says it too.
        let facts = PlanStatus.facts(for: run)
        if !facts.isEmpty { return facts.joined(separator: " · ") }
        switch run.kind {
        case .backup:
            // A reporting gap, alone: the line explains itself.
            if run.outcome == .completedWithErrors, let line = run.itemErrors.dropFirst(run.unreadableItems.count).first {
                return line
            }
            return "\(Format.count(run.filesNew)) new, \(Format.count(run.filesChanged)) changed"
        case .restore:
            return restoreDetail(run) ?? run.outcome.displayName
        case .forget:
            // Apply Retention Now…'s count ("Removed 2 snapshots. Their data
            // stays until the next prune."), one short line.
            return run.detailText ?? run.outcome.displayName
        default:
            return run.outcome.displayName
        }
    }

    /// The in-app banner's message for a backup that finished with
    /// warnings: the first unreadable item and restic's count of them —
    /// never the stored lines. Without one, what the plan row explains the
    /// warning with (the line stored after the items — a skipped retention
    /// step, a decoding gap — else a hook's complaint), led by an unnamed
    /// exit 3 as the facts lead with it, so a retention line never passes
    /// for the whole story. The fix, when the app knows one, is the
    /// caller's to add.
    static func warningBannerMessage(for run: RunRecord) -> String {
        if let item = run.unreadableItems.first {
            return "\(item) — \(Format.plural(run.itemErrorCount, "unreadable item")) in total."
        }
        let explanation = run.itemErrors.first ?? run.hookMessages.first ?? run.failureMessage
        guard PlanStatus.facts(for: run).first == PlanStatus.unnamedUnreadFact else {
            return explanation ?? RunRecord.unexplainedWarningMessage
        }
        return ([PlanStatus.unnamedUnreadFact + "."] + [explanation].compactMap { $0 }).joined(separator: " ")
    }

    /// Nil for a restore that says nothing countable — the records from
    /// before restores kept their counts read "Succeeded", as they did.
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
    /// banner's number: "kept as it was" for one, "kept as they were" for
    /// the rest.
    static func kept(_ count: Int) -> String {
        count == 1 ? "kept as it was" : "kept as they were"
    }

    /// restic's exit code for the drawer and Copy Details, explained only
    /// where the meaning is the same for every command (`restic backup
    /// --help`). `check` exits 1 when it finds damage, so "restic reported a
    /// fatal error" would mislabel a damaged-repository verdict; 1 and the
    /// rest show bare. Nil for 0, which says nothing worth a row.
    static func exitCodeText(_ code: Int32) -> String? {
        guard code != 0 else { return nil }
        switch code {
        case ResticError.backupPartialSuccessCode, 10, 11, 12:
            return ResticError.knownExitCodeDescription(code).map { "\(code) — \($0)" } ?? String(code)
        default:
            return String(code)
        }
    }

    /// Whether a backup record's file and byte numbers mean anything: a run
    /// that failed or was stopped before restic summarised has only zeros,
    /// which would read as "nothing changed".
    static func hasBackupNumbers(_ run: RunRecord) -> Bool {
        guard run.outcome == .failed || run.outcome == .cancelled else { return true }
        return run.filesNew + run.filesChanged + run.filesUnmodified > 0
            || run.bytesProcessed > 0 || run.dataAdded > 0
    }

    /// A restore's counts: "1 restored · 2 kept as they were · 14 bytes".
    static func restoreFiles(_ run: RunRecord) -> String {
        var text = "\(Format.count(run.filesRestored)) restored"
        if run.filesSkipped > 0 { text += " · \(Format.count(run.filesSkipped)) \(kept(run.filesSkipped))" }
        return text + " · \(Format.bytes(run.bytesProcessed))"
    }

    /// Copy Details: the run as plain text for a forum post or an issue —
    /// what ran, how it ended, restic's exit code and the versions. Hooks
    /// appear as a count only: their output can carry secrets and stays on
    /// this Mac, in the drawer.
    static func detailsText(for run: RunRecord, repositoryName: String?, versionsNow: RunLogVersions) -> String {
        var lines = [
            "\(subject(of: run)) — \(run.outcome.displayName)",
            "Started: \(Format.timestamp(run.startedAt)) (\(Format.duration(run.duration)))",
            "Repository: \(repositoryName ?? "No longer set up in SwiftRestic")",
        ]
        if let failure = run.failureMessage, failure != run.outcome.displayName {
            lines.append("Error: \(failure)")
        }
        if let snapshotID = run.snapshotID {
            let made = run.kind == .restore ? run.snapshotTime.map { " (\(Format.timestamp($0)))" } ?? "" : ""
            lines.append("Snapshot: \(snapshotID)\(made)")
        }
        switch run.kind {
        case .backup where hasBackupNumbers(run):
            lines.append(
                "Files: \(Format.count(run.filesNew)) new, \(Format.count(run.filesChanged)) changed, "
                    + "\(Format.count(run.filesUnmodified)) unmodified · processed \(Format.bytes(run.bytesProcessed))"
                    + " · added \(Format.bytes(run.dataAdded))"
            )
        case .restore:
            // Records from before restores kept these have no destination;
            // "Entire snapshot" would be a guess about them. The drawer's
            // word, beside its Snapshot row — "backup" is the Restore pane's.
            if let destination = run.destinationPath {
                if let paths = run.sourcePaths {
                    lines.append("Items: \(paths.joined(separator: ", "))")
                } else {
                    lines.append("Item: \(run.sourcePath ?? "Entire snapshot")")
                }
                lines.append("\(run.outcome == .succeeded ? "Restored to" : "Destination"): \(destination)")
            }
            if run.outcome == .succeeded, run.filesRestored + run.filesSkipped > 0 {
                lines.append("Files: \(restoreFiles(run))")
            }
        case .check, .forget:
            // A check's verdict, or what Apply Retention Now… removed.
            if let result = run.detailText { lines.append("Result: \(result)") }
        default:
            break
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
        lines += run.itemErrors.dropFirst(run.unreadableItems.count)
        if !run.hookMessages.isEmpty {
            lines.append("Hooks: \(Format.count(run.hookMessages.count)) failed")
        }
        if let version = run.resticVersion { lines.append(version) }
        lines.append("Copied from \(versionsNow.app) on \(versionsNow.macOS)")
        return lines.joined(separator: "\n")
    }
}
