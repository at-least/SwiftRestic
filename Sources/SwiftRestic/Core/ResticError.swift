import Foundation

enum ResticError: Error, LocalizedError, Equatable {
    /// The restic inside the app is missing or broken: nothing on the Mac stands in.
    case damagedInstall
    /// `message` is restic's own text when it gave one.
    case commandFailed(exitCode: Int32, message: String)
    case cancelled
    case repositoryMissing
    case itemNotListed(name: String)
    case passwordMissing(repositoryName: String)
    case processLaunchFailed(String)
    /// The child outlived its timeout and was terminated. `cause` is what
    /// restic was retrying when it was stopped — "connection refused" —
    /// or empty (`ResticRunResult.retryCause`).
    case timedOut(seconds: TimeInterval, cause: String = "")
    /// The child produced no output at all for `seconds` and was terminated
    /// as hung. The distinction from `timedOut` matters to the reader: a
    /// total-runtime cap kills work that was merely slow, an idle cap only
    /// kills work that had stopped reporting — so the message can promise
    /// more than "timed out".
    case idleStalled(seconds: TimeInterval)
    /// restic exited successfully but its output was not the JSON the command
    /// promises — a schema change, not a command failure. Reported rather
    /// than papered over: a backup app's numbers must be right or absent,
    /// never silently zero.
    case malformedOutput(detail: String)
    /// A single file's restore ran to completion but the file restic wrote
    /// beside the landing could not be moved into place. The staged copy is
    /// gone; whatever the destination held before is untouched.
    case stagedFileMoveFailed(path: String, reason: String)
    /// A folder stands where a Replace restore would put a file — one item
    /// or several. Left to restic, several items fail on it ("directory not
    /// empty") after restic puts the file's mode on the folder, taking its
    /// execute bits away; its contents stay. A single file is transferred
    /// whole and only then cannot replace the folder. So the restore is
    /// refused before restic runs.
    case folderInTheWay(path: String)
    /// Something other than a folder stands where a restored folder goes.
    /// restic would delete it, under Keep too, so the restore is refused
    /// before restic runs.
    case fileInTheWay(path: String)
    /// Items of a several-item restore that restic did not write. It exits 0
    /// when an --include matches nothing.
    case notRestored(paths: [String])
    /// `forget` could not delete every snapshot retention chose: restic's
    /// exit 3, "failed to remove one or more snapshots", one "unable to
    /// remove snapshot/<id>" line per snapshot the repository kept (restic
    /// 0.19.1). An append-only server or a locked bucket refuses them all.
    /// `reason` is the end of restic's first "Remove(…) failed:" line —
    /// "403 Forbidden", "permission denied".
    case snapshotsNotRemoved(removed: Int, refused: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .damagedInstall:
            return "SwiftRestic is damaged. Install it again."
        case let .commandFailed(code, message):
            let base: String?
            switch code {
            case Self.wrongPasswordCode:
                // The fix, not restic's diagnosis, which leaves Retry as the
                // only next step: Retry can never succeed here.
                base = "The password doesn’t open this backup location. Check it in Edit Backup Location."
            case Self.repositoryMissingCode, Self.repositoryLockedCode:
                // Exit 10's are the Add Backup Location button's own words, so
                // the banner and the notification say what the drawer's button
                // does. Exit 11's leave out the Unlock tooltip's "no run here
                // holds it", checked when the button is offered: the stored
                // message outlives that moment.
                base = code == Self.repositoryMissingCode
                    ? Self.noRepositoryAtLocation + "."
                    : "The backup location is locked. If no other Mac is using it, unlock it."
            default:
                base = nil
            }
            if let base { return base }
            if let advice = Self.sshHostKeyAdvice(message) { return advice }
            if let words = Self.rcloneWords(message) { return words }
            let known = ResticError.knownExitCodeDescription(code)
            if message.isEmpty { return known ?? "It stopped unexpectedly. Show Log has the details." }
            let reason = message.hasPrefix(Self.fatalWord) ? String(message.dropFirst(Self.fatalWord.count)) : message
            // Exit 1 is restic's every fatal error: the reason alone, as a
            // sentence. Copy Details keeps restic's line (`resticDetail`).
            if code == 1 { return reason.prefix(1).uppercased() + reason.dropFirst() }
            return known.map { "\($0) — \(reason)" } ?? reason
        case .cancelled:
            return "The operation was stopped."
        case .repositoryMissing:
            return "This backup location is no longer set up in SwiftRestic."
        case let .itemNotListed(name):
            return "“\(name)” is no longer listed in the chosen backup — refresh and try again."
        case let .passwordMissing(name):
            return "No password is stored for “\(name)”."
        case let .processLaunchFailed(reason):
            return "Couldn’t start restic: \(reason)"
        case let .timedOut(seconds, cause):
            return cause.isEmpty
                ? "Timed out after \(Format.duration(seconds)) and was stopped."
                : "Timed out after \(Format.duration(seconds)) and was stopped — restic kept retrying: \(cause)."
        case let .idleStalled(seconds):
            return "Nothing moved for \(Format.duration(seconds)), so it was stopped. Check the location’s connection and try again."
        case let .malformedOutput(detail):
            return "restic finished, but its answer couldn’t be read (\(detail))."
        case let .stagedFileMoveFailed(path, reason):
            return "The restored file couldn’t be written at \(path): \(reason). Nothing at the destination was changed."
        case let .snapshotsNotRemoved(removed, refused, reason):
            let cause = reason.isEmpty ? "" : " (\(reason))"
            let advice = "Turn off removing old backups, or allow deletions on this storage."
            guard removed > 0 else {
                return "The location refused to delete \(Format.plural(refused, "backup"))\(cause) — it may be append-only or locked. \(advice)"
            }
            let others = removed == 1 ? "the other one was removed" : "the other \(removed) were removed"
            return "The location refused to delete \(refused) of the \(removed + refused) old backups\(cause); \(others). "
                + "It may be append-only or locked. Turn off removing old backups, or allow deletions on this storage."
        case let .folderInTheWay(path):
            return "A folder is already at \(path), where a restored file would go, so nothing was restored. Move it aside, or restore somewhere else."
        case let .fileInTheWay(path):
            return "A file or alias is already at \(path), where a restored folder would go, so nothing was restored. Move it aside, or restore somewhere else."
        case let .notRestored(paths):
            return "\(Format.list(paths)) \(paths.count == 1 ? "wasn’t" : "weren’t") restored: restic found nothing by that name in the backup. A name written on another kind of computer can do this."
        }
    }

    private static let fatalWord = "Fatal: "

    /// restic's own first sentence behind a failure whose `errorDescription`
    /// says the fix instead: kept on the run for Copy Details
    /// (`RunRecord.resticDetail`). The log has the whole of it.
    var resticDetail: String? {
        guard case let .commandFailed(_, message) = self else { return nil }
        let first = Format.firstSentence(message)
        return first.isEmpty ? nil : first
    }

    /// What to do when ssh refused the server's host key — the line ssh
    /// prints both for a server it has never seen, which it cannot ask
    /// about without a terminal, and for one whose key changed (checked
    /// against restic 0.19.1 over sftp, run as the app runs it).
    static func sshHostKeyAdvice(_ message: String) -> String? {
        guard message.contains("Host key verification failed") else { return nil }
        if message.contains("has changed") {
            return "This server’s SSH key has changed since this Mac last connected, and SSH refuses it: "
                + "the server was reinstalled, or another computer is answering. If you expect the change, "
                + "remove the old key with ssh-keygen -R and the server’s name in Terminal, then connect once with ssh."
        }
        return "SSH does not know this server’s key yet, and restic runs SSH without a terminal to confirm it. "
            + "Connect to it once in Terminal with ssh and accept the key, then try again."
    }

    static func rcloneWords(_ message: String) -> String? {
        if message.contains(#"exec: "rclone": executable file not found"#) { return rcloneMissing }
        // restic's line says only "error talking HTTP to rclone"; rclone's
        // own verdict (`ResticRunResult.rcloneComplaint`) is the news.
        if let complaint = message.split(separator: "\n").last(where: { $0.hasPrefix("rclone: ") }) {
            return "\(Format.withoutFinalPeriod(String(complaint)))."
        }
        // restic waits a minute (its rclone.timeout) for rclone to answer,
        // and a remote that never answers gives rclone nothing to say yet.
        if message.contains("error talking HTTP to rclone"), message.contains("context deadline exceeded") {
            return "rclone did not answer within a minute — its remote may be unreachable."
        }
        return nil
    }

    /// What a missing rclone is called everywhere: the repository editor's
    /// check before restic runs, and a run's failure after.
    static let rcloneMissing = "rclone is not installed. Install it with brew install rclone."

    /// Exit 10's cause and fix, for every kind of location; a disk's also
    /// gets Locate beside it (`RunFix.locate`).
    static let noRepositoryAtLocation = "The backups aren’t at this location. Put them back, or add them where they are now as a new backup location"

    static func knownExitCodeDescription(_ code: Int32) -> String? {
        switch code {
        case 1: "restic stopped with an error"
        case 2: "restic stopped unexpectedly"
        case 3: "Finished, but some data couldn’t be read"
        case repositoryMissingCode: "The backup location does not exist"
        case repositoryLockedCode: "The backup location is locked by another process"
        case wrongPasswordCode: "Wrong password"
        case 130: "restic was interrupted"
        default: nil
        }
    }

    /// `backup` returns 3 when it finished but could not read some source
    /// data (an unreadable file, say). That is a warning, not a failure, and
    /// must not abort a scheduled run. `forget`'s 3 is another matter: it
    /// could not delete snapshots (`snapshotsNotRemoved`).
    static let backupPartialSuccessCode: Int32 = 3
    static let repositoryMissingCode: Int32 = 10
    static let repositoryLockedCode: Int32 = 11
    static let wrongPasswordCode: Int32 = 12

    /// Whether an error is a stop — Swift's task cancellation or restic's
    /// own `cancelled` — rather than a failure. The reading the run records
    /// and the index backfill share (the backfill adds only its own task's
    /// cancellation). Call sites that stop on one of the two by name — a
    /// hook, a refresh, the diff view — still catch it themselves.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ResticError) == .cancelled
    }
}
