import Foundation

/// Everything that can go wrong between us and the restic binary.
enum ResticError: Error, LocalizedError, Equatable {
    /// No usable `restic` executable was found on disk.
    case binaryNotFound(searched: [String])
    /// The configured restic path exists but is not executable.
    case binaryNotExecutable(path: String)
    /// The process exited non-zero. `message` is restic's own text when it gave one.
    case commandFailed(exitCode: Int32, message: String, command: String)
    /// The run was cancelled by the user.
    case cancelled
    /// A repository referenced by a plan is missing from the config.
    case repositoryMissing
    /// No password is stored for the repository.
    case passwordMissing(repositoryName: String)
    case processLaunchFailed(String)
    /// The child outlived its timeout and was terminated.
    case timedOut(seconds: TimeInterval, command: String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(searched):
            return "Could not find the restic executable. Looked in: \(searched.joined(separator: ", ")). "
                + "Install it with `brew install restic`, or set the path in Settings."
        case let .binaryNotExecutable(path):
            return "The file at \(path) is not executable."
        case let .commandFailed(code, message, _):
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
        case let .timedOut(seconds, _):
            return "Timed out after \(Int(seconds))s and was stopped." 
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
}
