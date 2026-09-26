import Foundation

/// A run's words outside its log: the Activity Detail column, the drawer's
/// rows, and Copy Details. The one place a run's one-line summary is worded,
/// built on the plan page's facts (`PlanStatus.facts(for:)`) so Activity and
/// the plan row cannot disagree.
enum RunRecordPresentation {
    /// "Backup of “Documents”", "Restore of “Budget.numbers”", "Check of
    /// “Home NAS”" — the subject line the log and Copy Details open with.
    static func subject(of run: RunRecord) -> String {
        let kind = run.kind.rawValue.capitalized
        return run.planName.isEmpty ? kind : "\(kind) of “\(run.planName)”"
    }

    /// The Activity Detail column: why a run failed, else its problems as
    /// the plan page counts them ("1 unreadable item · Retention skipped" —
    /// restic's count, never the stored lines), else what it did.
    static func detail(for run: RunRecord) -> String {
        if let failure = run.failureMessage { return failure }
        var facts = PlanStatus.facts(for: run)
        // restic exited 3 and named nothing — a file count would pass for a
        // clean run, and a skipped retention step or a failing hook beside it
        // would pass for the whole story. The log keeps restic's own words.
        if run.kind == .backup, run.exitCode == ResticError.backupPartialSuccessCode, run.itemErrorCount == 0 {
            facts.insert("Some source data could not be read", at: 0)
        }
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
        default:
            return run.outcome.displayName
        }
    }

    /// Nil for a restore that says nothing countable — the records from
    /// before restores kept their counts read "Succeeded", as they did.
    private static func restoreDetail(_ run: RunRecord) -> String? {
        guard run.outcome == .succeeded else { return nil }
        if run.filesRestored == 0, run.filesSkipped > 0 {
            return "\(Format.plural(run.filesSkipped, "file")) kept as they were — nothing restored"
        }
        guard run.filesRestored > 0 else { return nil }
        let restored = "\(Format.plural(run.filesRestored, "file")), \(Format.bytes(run.bytesProcessed))"
        return run.filesSkipped > 0 ? "\(restored) · \(Format.count(run.filesSkipped)) kept as they were" : restored
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
        if run.filesSkipped > 0 { text += " · \(Format.count(run.filesSkipped)) kept as they were" }
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
                lines.append("Item: \(run.sourcePath ?? "Entire snapshot")")
                lines.append("\(run.outcome == .succeeded ? "Restored to" : "Destination"): \(destination)")
            }
            if run.outcome == .succeeded, run.filesRestored + run.filesSkipped > 0 {
                lines.append("Files: \(restoreFiles(run))")
            }
        case .check:
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
