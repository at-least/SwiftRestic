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
    /// A repository referenced by a plan is missing from the config.
    case repositoryMissing
    /// No password is stored for the repository.
    case passwordMissing(repositoryName: String)
    case processLaunchFailed(String)
    /// The child outlived its timeout and was terminated.
    case timedOut(seconds: TimeInterval)
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
    /// A `restic dump` ran to completion but its output could not be moved
    /// into place at the destination. The staged copy is gone; whatever the
    /// destination held before is untouched.
    case dumpMoveFailed(path: String, reason: String)
    /// A Keep restore onto something that is already there, with a restic
    /// older than 0.17: it has no `--overwrite` and would replace it.
    /// Refused before restic runs.
    case keepNeedsNewerRestic(path: String)
    /// A folder stands where a Replace restore of several items would put a
    /// file. restic fails on it — after taking away the folder's permissions
    /// (0.19.1, probed) — so it is refused before restic runs.
    case folderInTheWay(path: String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(searched):
            return "Could not find the restic executable. Looked in: \(searched.joined(separator: ", ")). "
                + "Install it with `brew install restic`, or set the path in Settings."
        case let .binaryNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .commandFailed(code, message):
            if code == 12 {
                // The trust-critical failure carries its fix: restic's own
                // diagnosis leaves Retry as the only next step, and Retry can
                // never succeed here. restic's words stay for the discriminating
                // detail (wrong password vs no matching key vs a damaged key
                // file), first sentence only — stderr can run multi-line.
                let base = "The password doesn't open this repository — check it in the repository settings."
                let restic = Format.firstSentence(message)
                return restic.isEmpty ? base : "\(base) restic reported: \(restic)"
            }
            let known = ResticError.knownExitCodeDescription(code)
            if message.isEmpty { return known ?? "restic exited with code \(code)." }
            return known.map { "\($0) — \(message)" } ?? message
        case .cancelled:
            return "The operation was cancelled."
        case .repositoryMissing:
            return "This plan points at a repository that no longer exists."
        case let .passwordMissing(name):
            return "No password is stored for the repository “\(name)”."
        case let .processLaunchFailed(reason):
            return "Could not start restic: \(reason)"
        case let .timedOut(seconds):
            return "Timed out after \(Int(seconds))s and was stopped."
        case let .idleStalled(seconds):
            return "Stopped reporting any progress for \(Int(seconds))s and was stopped as hung — check the repository's connection and try again."
        case let .malformedOutput(detail):
            return "restic finished, but its answer could not be read (\(detail)). A restic update may have changed its output — none of its numbers were guessed at."
        case let .dumpMoveFailed(path, reason):
            return "The restored file could not be written at \(path): \(reason). Nothing at the destination was changed."
        case let .keepNeedsNewerRestic(path):
            return "Keeping the files already at \(path) needs restic 0.17 or later — this restic would replace them, so nothing was restored. Update restic, restore into an empty folder, or choose “Replace it with the backed-up version”."
        case let .folderInTheWay(path):
            return "A folder is already at \(path), where a restored file would go, so nothing was restored. Move it aside, or restore somewhere else."
        }
    }

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

    /// `backup` and `forget` return 3 when they finished but hit data access
    /// issues (an unreadable source file, say). That is a warning, not a failure,
    /// and must not abort a scheduled run.
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
