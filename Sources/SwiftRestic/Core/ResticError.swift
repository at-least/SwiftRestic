import Foundation

/// Everything that can go wrong between us and the restic binary.
enum ResticError: Error, LocalizedError, Equatable {
    /// No usable `restic` executable was found on disk.
    case binaryNotFound(searched: [String])
    /// The configured restic path exists but is not executable.
    case binaryNotExecutable(path: String)
    /// The process exited non-zero. `message` is restic's own text when it gave one.
    case commandFailed(exitCode: Int32, message: String)
    /// The run was cancelled by the user.
    case cancelled
    /// The repository asked for is no longer in the configuration.
    case repositoryMissing
    /// The plan asked for is no longer in the configuration.
    case planMissing
    /// The item a restore asked for by path is not in its backup's listing.
    case itemNotListed(name: String)
    /// No password is stored for the repository.
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
    /// A Keep restore onto something that is already there, with a restic
    /// older than 0.17: it has no `--overwrite` and would replace it.
    /// Refused before restic runs.
    case keepNeedsNewerRestic(path: String)
    /// A folder stands where a Replace restore of several items would put a
    /// file. restic fails on it — after taking away the folder's permissions —
    /// so it is refused before restic runs.
    case folderInTheWay(path: String)
    /// `forget` could not delete every snapshot retention chose: restic's
    /// exit 3, "failed to remove one or more snapshots", one "unable to
    /// remove snapshot/<id>" line per snapshot the repository kept (restic
    /// 0.19.1). An append-only server or a locked bucket refuses them all.
    /// `reason` is the end of restic's first "Remove(…) failed:" line —
    /// "403 Forbidden", "permission denied".
    case snapshotsNotRemoved(removed: Int, refused: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(searched):
            return "Could not find the restic executable. Looked in: \(searched.joined(separator: ", ")). "
                + "Install it with brew install restic, or set the path in Settings."
        case let .binaryNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .commandFailed(code, message):
            if code == 12 {
                // The trust-critical failure carries its fix: restic's own
                // diagnosis leaves Retry as the only next step, and Retry can
                // never succeed here. restic's words stay for the discriminating
                // detail (wrong password vs no matching key vs a damaged key
                // file), first sentence only — stderr can run multi-line.
                let base = "The password doesn’t open this repository — check it in the repository settings."
                let restic = Format.firstSentence(message)
                return restic.isEmpty ? base : "\(base) restic reported: \(restic)"
            }
            if code == 10 || code == 11 {
                // Exit 12's grammar: the fix leads, restic's first sentence
                // keeps the detail. Exit 10's are the Add Repository
                // button's own words, so the banner and the notification say
                // what the drawer's button does. Exit 11's leave out the
                // Unlock tooltip's "no run here holds it",
                // checked when the button is offered: the stored message
                // outlives that moment.
                let base = code == 10
                    ? Self.noRepositoryAtLocation + "."
                    : "The repository is locked — if no other Mac is using it, unlock it."
                let restic = Format.firstSentence(message)
                return restic.isEmpty ? base : "\(base) restic reported: \(restic)"
            }
            if let advice = Self.sshHostKeyAdvice(message) {
                return "\(advice) restic reported: \(Format.firstSentence(message))"
            }
            if let words = Self.rcloneWords(message) { return words }
            let known = ResticError.knownExitCodeDescription(code)
            if message.isEmpty { return known ?? "restic exited with code \(code)." }
            return known.map { "\($0) — \(message)" } ?? message
        case .cancelled:
            return "The operation was cancelled."
        case .repositoryMissing:
            return "This repository is no longer in SwiftRestic."
        case .planMissing:
            return "This plan is no longer in SwiftRestic."
        case let .itemNotListed(name):
            return "“\(name)” is no longer listed in the chosen backup — refresh and try again."
        case let .passwordMissing(name):
            return "No password is stored for the repository “\(name)”."
        case let .processLaunchFailed(reason):
            return "Could not start restic: \(reason)"
        case let .timedOut(seconds, cause):
            return cause.isEmpty
                ? "Timed out after \(Format.duration(seconds)) and was stopped."
                : "Timed out after \(Format.duration(seconds)) and was stopped — restic kept retrying: \(cause)."
        case let .idleStalled(seconds):
            return "Stopped reporting any progress for \(Format.duration(seconds)) and was stopped — check the repository’s connection and try again."
        case let .malformedOutput(detail):
            return "restic finished, but its answer could not be read (\(detail)). A restic update may have changed its output."
        case let .stagedFileMoveFailed(path, reason):
            return "The restored file could not be written at \(path): \(reason). Nothing at the destination was changed."
        case let .keepNeedsNewerRestic(path):
            return "Keeping the files already at \(path) needs restic 0.17 or later — this restic would replace them, so nothing was restored. Update restic, restore into an empty folder, or choose “Replace it with the backed-up version”."
        case let .snapshotsNotRemoved(removed, refused, reason):
            let cause = reason.isEmpty ? "" : " (\(reason))"
            let advice = "Thin it where deletions are allowed, or turn retention off."
            guard removed > 0 else {
                return "The repository refused to delete \(Format.plural(refused, "backup"))\(cause) — it may be append-only or locked. \(advice)"
            }
            let others = removed == 1 ? "the other one was removed" : "the other \(removed) were removed"
            return "The repository refused to delete \(refused) of the \(removed + refused) backups retention chose\(cause); \(others). "
                + "It may be append-only or locked — thin it where deletions are allowed, or turn retention off."
        case let .folderInTheWay(path):
            return "A folder is already at \(path), where a restored file would go, so nothing was restored. Move it aside, or restore somewhere else."
        }
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

    /// rclone's failures in its own verdict, or in plain words where it
    /// said none; nil for a failure that is not rclone's.
    static func rcloneWords(_ message: String) -> String? {
        if message.contains(#"exec: "rclone": executable file not found"#) { return rcloneMissing }
        // restic's line says only "error talking HTTP to rclone"; rclone's
        // own verdict (`ResticRunResult.rcloneComplaint`) leads, as exit
        // 12's fix does, restic's first sentence keeping the detail.
        let restic = Format.firstSentence(message)
        if let complaint = message.split(separator: "\n").last(where: { $0.hasPrefix("rclone: ") }) {
            let verdict = complaint.hasSuffix(".") ? String(complaint.dropLast()) : String(complaint)
            return "\(verdict). restic reported: \(restic)"
        }
        // restic waits a minute (its rclone.timeout) for rclone to answer,
        // and a remote that never answers gives rclone nothing to say yet.
        if message.contains("error talking HTTP to rclone"), message.contains("context deadline exceeded") {
            return "rclone did not answer within a minute — its remote may be unreachable. restic reported: \(restic)"
        }
        return nil
    }

    /// What a missing rclone is called everywhere: the repository editor's
    /// check before restic runs, and a run's failure after.
    static let rcloneMissing = "rclone is not installed. Install it with brew install rclone."

    /// Exit 10's cause and fix, the failure's message and its button's
    /// tooltip alike. A repository's location is fixed, so where it is now
    /// is a new repository, as a moved plan folder is a new plan.
    static let noRepositoryAtLocation = "No repository is at its location — put it back, or add it where it is now as a new repository"

    /// restic's documented exit codes.
    static func knownExitCodeDescription(_ code: Int32) -> String? {
        switch code {
        case 1: "restic reported a fatal error"
        case 2: "Go runtime error"
        case 3: "Finished, but some data could not be read"
        case 10: "The repository does not exist"
        case 11: "The repository is already locked by another process"
        case 12: "Wrong repository password or no matching key"
        case 130: "restic was interrupted"
        default: nil
        }
    }

    /// `backup` returns 3 when it finished but could not read some source
    /// data (an unreadable file, say). That is a warning, not a failure, and
    /// must not abort a scheduled run. `forget`'s 3 is another matter: it
    /// could not delete snapshots (`snapshotsNotRemoved`).
    static let backupPartialSuccessCode: Int32 = 3

    /// Whether an error is a stop — Swift's task cancellation or restic's
    /// own `cancelled` — rather than a failure. The reading the run records
    /// and the index backfill share (the backfill adds only its own task's
    /// cancellation). Call sites that stop on one of the two by name — a
    /// hook, a refresh, the diff view — still catch it themselves.
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? ResticError) == .cancelled
    }
}
