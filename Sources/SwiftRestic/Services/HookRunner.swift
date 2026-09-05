import Foundation

/// Runs a plan's or a repository's shell hooks.
///
/// Commands go through `/bin/sh -c` with the surrounding run's facts exported as
/// `SWIFTRESTIC_*` variables. They inherit the app's own privileges, which are
/// not sandboxed — the plan editor says so next to the command field.
struct HookRunner: Sendable {
    /// What a hook is told about the run that triggered it.
    struct Context: Sendable {
        var event: BackupHook.Event
        var planName: String = ""
        var planID: String = ""
        var repositoryName: String = ""
        var repositoryID: String = ""
        /// `check` or `prune` for a repository hook; `nil` around a backup.
        var maintenanceTask: String?
        var snapshotID: String?
        var outcome: String = ""
        var errorMessage: String?
        var filesNew: Int = 0
        var filesChanged: Int = 0
        var bytesProcessed: Int64 = 0
        var dataAdded: Int64 = 0
        var durationSeconds: Double = 0

        var environment: [String: String] {
            var env: [String: String] = [
                "SWIFTRESTIC_EVENT": event.rawValue,
                "SWIFTRESTIC_PLAN_NAME": planName,
                "SWIFTRESTIC_PLAN_ID": planID,
                "SWIFTRESTIC_REPO_NAME": repositoryName,
                "SWIFTRESTIC_REPO_ID": repositoryID,
                "SWIFTRESTIC_OUTCOME": outcome,
                "SWIFTRESTIC_FILES_NEW": String(filesNew),
                "SWIFTRESTIC_FILES_CHANGED": String(filesChanged),
                "SWIFTRESTIC_BYTES_PROCESSED": String(bytesProcessed),
                "SWIFTRESTIC_DATA_ADDED": String(dataAdded),
                "SWIFTRESTIC_DURATION_SECONDS": String(format: "%.3f", durationSeconds),
            ]
            // Absent rather than empty, so `[ -n "$SWIFTRESTIC_ERROR" ]` works.
            if let snapshotID { env["SWIFTRESTIC_SNAPSHOT_ID"] = snapshotID }
            if let maintenanceTask { env["SWIFTRESTIC_TASK"] = maintenanceTask }
            if let errorMessage { env["SWIFTRESTIC_ERROR"] = errorMessage }
            return env
        }
    }

    struct Outcome: Sendable {
        var hookName: String
        var exitCode: Int32
        var output: String
        var timedOut: Bool

        var succeeded: Bool { exitCode == 0 && !timedOut }

        /// One line for the run record.
        ///
        /// Only the first line of output is kept, and only briefly: a script's
        /// later output is where a verbose HTTP client prints its headers, and
        /// this string is persisted to disk.
        var summary: String {
            if timedOut { return "Hook “\(hookName)” timed out and was stopped." }
            if exitCode == 0 { return "Hook “\(hookName)” succeeded." }
            let firstLine = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { String($0.prefix(160)) } ?? ""
            let detail = firstLine.isEmpty ? "" : " — \(firstLine)"
            return "Hook “\(hookName)” exited \(exitCode)\(detail)"
        }
    }

    static let shell = URL(fileURLWithPath: "/bin/sh")

    let runner: ResticRunner

    /// Runs one hook to completion. Never throws for a non-zero exit: the caller
    /// decides what a failing hook means.
    func run(_ hook: BackupHook, context: Context) async -> Outcome {
        do {
            let result = try await runner.run(
                binary: Self.shell,
                invocation: ResticInvocation(
                    arguments: ["-c", hook.command],
                    environment: context.environment,
                    // The exit code is the hook's answer, not an error to raise.
                    allowedExitCodes: nil,
                    timeout: TimeInterval(max(1, hook.timeoutSeconds)),
                    retainFullOutput: false
                )
            )
            let combined = (result.stdout + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(
                hookName: hook.displayName,
                exitCode: result.exitCode,
                output: ResticRunner.tail(of: combined, limit: 2000),
                timedOut: false
            )
        } catch ResticError.timedOut {
            return Outcome(hookName: hook.displayName, exitCode: -1, output: "", timedOut: true)
        } catch {
            return Outcome(
                hookName: hook.displayName,
                exitCode: -1,
                output: error.localizedDescription,
                timedOut: false
            )
        }
    }

    /// Runs every enabled hook for an event, in the order the user arranged them.
    ///
    /// - Returns: the outcomes, and whether one of them asked to abort.
    func runHooks(
        _ hooks: [BackupHook],
        event: BackupHook.Event,
        context: Context
    ) async -> (outcomes: [Outcome], shouldAbort: Bool) {
        var outcomes: [Outcome] = []
        var shouldAbort = false
        for hook in hooks where hook.event == event && hook.isRunnable {
            var hookContext = context
            hookContext.event = event
            let outcome = await run(hook, context: hookContext)
            outcomes.append(outcome)
            if !outcome.succeeded, hook.abortsRunOnFailure {
                shouldAbort = true
                break
            }
        }
        return (outcomes, shouldAbort)
    }
}
