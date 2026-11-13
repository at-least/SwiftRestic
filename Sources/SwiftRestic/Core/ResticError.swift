import Foundation

enum ResticError: Error, LocalizedError, Equatable {
    /// The bundled restic is missing or broken; no restic on the Mac stands in.
    case damagedInstall
    /// `message` is restic's own text when it gave one.
    case commandFailed(exitCode: Int32, message: String)
    case cancelled
    case repositoryRemoved
    case itemNotListed(name: String)
    case passwordMissing(repositoryName: String)
    case processLaunchFailed(String)
    /// `cause`: what restic was retrying ("connection refused"), or empty.
    case timedOut(seconds: TimeInterval, cause: String)
    /// Separate from `timedOut` so the message can say nothing moved, which
    /// a total-runtime cap cannot claim.
    case idleStalled(seconds: TimeInterval)
    /// restic exited 0 but its output was not the promised JSON. Reported,
    /// never read as zero: a backup app's numbers are right or absent.
    case malformedOutput(detail: String)
    /// A single file's restore: the file restic wrote beside the landing
    /// could not be moved into place. The staged copy is gone; the
    /// destination is untouched.
    case stagedFileMoveFailed(path: String, reason: String)
    /// A folder stands where a Replace restore would put a file, so the
    /// restore is refused before restic runs. Left to restic, several items
    /// fail on it ("directory not empty") after restic puts the file's mode
    /// on the folder, taking its execute bits; a single file is transferred
    /// whole and only then fails.
    case folderInTheWay(path: String)
    /// restic would delete it, under Keep too, so the restore is refused
    /// before restic runs.
    case fileInTheWay(path: String)
    /// restic exits 0 when an --include matches nothing.
    case notRestored(paths: [String])
    /// `forget`'s exit 3, "failed to remove one or more snapshots", with one
    /// "unable to remove snapshot/<id>" line per snapshot kept (restic
    /// 0.19.1). An append-only server or a locked bucket refuses them all.
    /// `reason`: the end of restic's first "Remove(…) failed:" line, such as
    /// "403 Forbidden".
    case snapshotsNotRemoved(removed: Int, refused: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .damagedInstall:
            return "SwiftRestic is damaged. Install it again."
        case let .commandFailed(code, message):
            let base: String?
            switch code {
            case Self.wrongPasswordCode:
                // Not restic's words, which leave Retry, which cannot
                // succeed, as the next step. A run names the location
                // (`words(for:location:)`).
                base = "The password doesn’t open this backup location."
            case Self.repositoryMissingCode, Self.repositoryLockedCode:
                // Exit 10 uses the Add Backup Location button's words. Exit
                // 11's words show only where nothing unlocked first: a run
                // unlocks and retries (`unlockingStaleLocks`).
                base = code == Self.repositoryMissingCode
                    ? Self.noRepositoryAtLocation + "."
                    : "The backup location is in use by another Mac or app."
            default:
                base = nil
            }
            if let base { return base }
            if let advice = Self.sshHostKeyAdvice(message) { return advice }
            let known = Self.exitCodeWords(code)
            if message.isEmpty { return "\(known ?? "It stopped unexpectedly"). Show Log has the details." }
            let reason = message.hasPrefix(Self.fatalWord) ? String(message.dropFirst(Self.fatalWord.count)) : message
            // Exit 1 is every restic fatal error: the reason alone, as a
            // sentence.
            if code == 1 { return reason.prefix(1).uppercased() + reason.dropFirst() }
            return known.map { "\($0) — \(reason)" } ?? reason
        case .cancelled:
            return "The operation was stopped."
        case .repositoryRemoved:
            return "This backup location is no longer set up in SwiftRestic."
        case let .itemNotListed(name):
            return "“\(name)” is no longer listed in the chosen backup — refresh and try again."
        case let .passwordMissing(name):
            return "No password is stored for “\(name)”."
        case let .processLaunchFailed(reason):
            return "The backup engine couldn’t start: \(reason). Install SwiftRestic again if this keeps happening."
        case let .timedOut(seconds, cause):
            return cause.isEmpty
                ? "Timed out after \(Format.duration(seconds)) and was stopped."
                : "Timed out after \(Format.duration(seconds)) and was stopped — it kept retrying: \(cause). Check the location’s connection and try again."
        case let .idleStalled(seconds):
            return "Nothing moved for \(Format.duration(seconds)), so it was stopped. Check the location’s connection and try again."
        case let .malformedOutput(detail):
            return "It finished, but its result couldn’t be read (\(detail)). Show Log has the details."
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
            return "\(Format.list(paths)) \(paths.count == 1 ? "wasn’t" : "weren’t") restored: nothing by that name is in the backup. A name written on another kind of computer can do this."
        }
    }

    private static let fatalWord = "Fatal: "

    /// restic's first sentence behind an `errorDescription` that says the fix
    /// instead, for the run's details text.
    var resticDetail: String? {
        guard case let .commandFailed(_, message) = self else { return nil }
        let first = Format.firstSentence(message)
        return first.isEmpty ? nil : first
    }

    /// A server never seen is accepted (`RepositoryContext.globalArguments`),
    /// so a refusal means a changed key (restic 0.19.1 over sftp, run as the
    /// app runs it); once its old known_hosts line is gone, the next run
    /// accepts the new key.
    private static func sshHostKeyAdvice(_ message: String) -> String? {
        guard message.contains("Host key verification failed") else { return nil }
        if message.contains("has changed") {
            return "This server’s SSH key has changed since this Mac last connected: "
                + "the server was reinstalled, or another computer is answering. If you expect the change, "
                + "remove the server’s line from ~/.ssh/known_hosts, then try again."
        }
        return "SSH refused this server’s key. Show Log has what SSH said."
    }

    /// A run record's words: a refused password names the location, and a
    /// disk's missing backups ask after the disk, beside `RunFix.locate`.
    static func words(for error: any Error, location: (name: String, kind: Repository.Kind)?) -> String {
        if let location, case let .commandFailed(code, _)? = error as? ResticError {
            if code == wrongPasswordCode { return wrongPassword(location: location.name) }
            if code == repositoryMissingCode, location.kind == .local { return diskBackupsMissing }
        }
        return error.localizedDescription
    }

    static func wrongPassword(location: String) -> String {
        "The password doesn’t open “\(location)”."
    }

    /// Exit 10 on a disk; `AppModel.missingRepositoryReason` shares it.
    static let diskBackupsMissing = "Backups not found. Is the disk connected? If it moved, locate it."

    /// Exit 10 on a server or in the cloud, or where the location is unknown.
    private static let noRepositoryAtLocation = "The backups aren’t at this location. Put them back, or add them where they are now as a new backup location"

    /// Replaces the console's words where they name restic as the actor.
    private static func exitCodeWords(_ code: Int32) -> String? {
        switch code {
        case 1: "It stopped with an error"
        case 2: "It stopped unexpectedly"
        case 130: "It was interrupted"
        default: knownExitCodeDescription(code)
        }
    }

    /// The restic Console's "[exit N: …]" line.
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

    /// A warning for `backup` (some source unreadable), not a failure.
    /// `forget`'s 3 is a failure (`snapshotsNotRemoved`).
    static let backupPartialSuccessCode: Int32 = 3
    static let repositoryMissingCode: Int32 = 10
    private static let repositoryLockedCode: Int32 = 11
    static let wrongPasswordCode: Int32 = 12

    static func isRepositoryLocked(_ error: Error) -> Bool {
        guard case let .commandFailed(code, _) = error as? ResticError else { return false }
        return code == repositoryLockedCode
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ResticError) == .cancelled
    }
}
