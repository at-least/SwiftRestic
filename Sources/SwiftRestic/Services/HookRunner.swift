import Foundation

/// Runs a plan's or a repository's shell hooks.
///
/// Commands go through `/bin/sh -c` with the surrounding run's facts exported as
/// `SWIFTRESTIC_*` variables. They run with the home directory as their working
/// directory — a GUI app's inherited cwd is `/`, and a hook's relative paths
/// should never depend on how the app was launched. They inherit the app's own
/// privileges, which are not sandboxed — the plan editor's hook field says so.
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
        /// The surrounding run was cancelled while this hook ran: not a
        /// verdict on the hook, which never finished, and never a reason to
        /// abort anything or fail a run.
        var cancelled: Bool = false

        var succeeded: Bool { exitCode == 0 && !timedOut }

        /// One line for the run record: the verdict plus the hook's first
        /// output line only — this string is persisted, and a script's later
        /// output is where a verbose HTTP client prints its headers.
        var summary: String { verdict(withDetail: true) }

        /// The hook's verdict for the run's log — the same sentence as
        /// `summary`, never any of its output: the log is what a user copies
        /// whole to ask for help.
        var logLine: String { verdict(withDetail: false) }

        /// The verdict both strings spell, `withDetail` adding the hook's
        /// first output line for the persisted summary.
        private func verdict(withDetail: Bool) -> String {
            let base = "Hook “\(hookName)”"
            if cancelled { return "\(base) was cancelled before it finished." }
            if timedOut { return "\(base) timed out and was stopped." }
            if exitCode == 0 { return "\(base) succeeded." }
            if !withDetail { return "\(base) exited \(exitCode)." }
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
    ///
    /// Shielded from the run's transcript, which would otherwise record the
    /// hook's command line and every line it printed into a log a user copies
    /// whole to ask for help; the engines note the verdict (`Outcome.logLine`)
    /// instead.
    func run(_ hook: BackupHook, context: Context) async -> Outcome {
        await RunTranscript.$current.withValue(nil) {
            await runUnrecorded(hook, context: context)
        }
    }

    private func runUnrecorded(_ hook: BackupHook, context: Context) async -> Outcome {
        do {
            let result = try await runner.run(
                binary: Self.shell,
                invocation: ResticInvocation(
                    arguments: ["-c", hook.command],
                    environment: context.environment,
                    workingDirectory: NSHomeDirectory(),
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
        } catch ResticError.cancelled {
            // The run was cancelled, not the hook failing: the caller stops
            // and records a cancellation instead of a hook verdict.
            return Outcome(
                hookName: hook.displayName,
                exitCode: -1,
                output: "",
                timedOut: false,
                cancelled: true
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

    /// Runs every enabled hook for an event, in the order the user arranged
    /// them. Stops at the first hook to ask for an abort — or at a
    /// cancellation of the surrounding run, which is nobody's verdict.
    ///
    /// - Returns: the outcomes, whether one of them asked to abort, and
    ///   whether the run was cancelled mid-hook.
    func runHooks(
        _ hooks: [BackupHook],
        event: BackupHook.Event,
        context: Context
    ) async -> (outcomes: [Outcome], shouldAbort: Bool, cancelled: Bool) {
        var outcomes: [Outcome] = []
        var shouldAbort = false
        var cancelled = false
        for hook in hooks where hook.event == event && hook.isRunnable {
            var hookContext = context
            hookContext.event = event
            let outcome = await run(hook, context: hookContext)
            outcomes.append(outcome)
            if outcome.cancelled {
                cancelled = true
                break
            }
            if !outcome.succeeded, hook.abortsRunOnFailure {
                shouldAbort = true
                break
            }
        }
        return (outcomes, shouldAbort, cancelled)
    }
}
