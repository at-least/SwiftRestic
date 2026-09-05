import Foundation
import Testing

@Suite("Backup hooks")
struct HookTests {
    private func context(event: BackupHook.Event = .afterSuccess) -> HookRunner.Context {
        HookRunner.Context(
            event: event,
            planName: "Documents",
            planID: "PLAN-1",
            repositoryName: "NAS",
            repositoryID: "REPO-1",
            snapshotID: "abc12345",
            outcome: "succeeded",
            filesNew: 4,
            filesChanged: 2,
            bytesProcessed: 1024,
            dataAdded: 512,
            durationSeconds: 1.5
        )
    }

    @Test("the run's facts reach the script as environment variables")
    func environment() {
        let env = context().environment
        #expect(env["SWIFTRESTIC_EVENT"] == "afterSuccess")
        #expect(env["SWIFTRESTIC_PLAN_NAME"] == "Documents")
        #expect(env["SWIFTRESTIC_REPO_NAME"] == "NAS")
        #expect(env["SWIFTRESTIC_SNAPSHOT_ID"] == "abc12345")
        #expect(env["SWIFTRESTIC_OUTCOME"] == "succeeded")
        #expect(env["SWIFTRESTIC_DATA_ADDED"] == "512")
        #expect(env["SWIFTRESTIC_DURATION_SECONDS"] == "1.500")
    }

    @Test("optional variables are absent rather than empty")
    func absentVariables() {
        // A script tests these with [ -n "$VAR" ]; an empty string would read as
        // "there was an error" on every successful run.
        var bare = context()
        bare.snapshotID = nil
        bare.errorMessage = nil
        let env = bare.environment
        #expect(env["SWIFTRESTIC_ERROR"] == nil)
        #expect(env["SWIFTRESTIC_SNAPSHOT_ID"] == nil)

        var failed = context()
        failed.errorMessage = "boom"
        #expect(failed.environment["SWIFTRESTIC_ERROR"] == "boom")
    }

    @Test("a script sees the variables and its output is captured")
    func runsCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticHook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = directory.appendingPathComponent("marker.txt")
        var hook = BackupHook()
        hook.name = "write marker"
        hook.command = #"printf '%s %s' "$SWIFTRESTIC_PLAN_NAME" "$SWIFTRESTIC_SNAPSHOT_ID" > "\#(marker.path)"; echo done"#

        let outcome = await HookRunner(runner: ResticRunner()).run(hook, context: context())
        #expect(outcome.succeeded)
        #expect(outcome.exitCode == 0)
        #expect(outcome.output.contains("done"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "Documents abc12345")
    }

    @Test("a non-zero exit is reported, not thrown")
    func failingCommand() async {
        var hook = BackupHook()
        hook.name = "fails"
        hook.command = "echo 'to stderr' >&2; exit 7"

        let outcome = await HookRunner(runner: ResticRunner()).run(hook, context: context())
        #expect(!outcome.succeeded)
        #expect(outcome.exitCode == 7)
        #expect(outcome.output.contains("to stderr"))
        #expect(outcome.summary.contains("exited 7"))
    }

    @Test("a hook that never returns is stopped rather than hanging the backup")
    func timeout() async {
        var hook = BackupHook()
        hook.name = "hangs"
        hook.command = "sleep 30"
        hook.timeoutSeconds = 1

        let started = Date.now
        let outcome = await HookRunner(runner: ResticRunner()).run(hook, context: context())
        #expect(outcome.timedOut)
        #expect(!outcome.succeeded)
        #expect(Date.now.timeIntervalSince(started) < 10)
        #expect(outcome.summary.contains("timed out"))
    }

    @Test("only a before hook can cancel the run")
    func onlyBeforeHooksCanAbort() {
        var hook = BackupHook()
        hook.failureBehaviour = .abortBackup

        hook.event = .beforeBackup
        #expect(hook.abortsRunOnFailure)
        hook.event = .beforeMaintenance
        #expect(hook.abortsRunOnFailure)

        // By the time these run the snapshot exists or the check has finished, so
        // "cancel" would be meaningless even if it were configured.
        for event in [
            BackupHook.Event.afterSuccess, .afterWarning, .afterFailure, .afterAny,
            .afterMaintenanceSuccess, .afterMaintenanceFailure, .afterAnyMaintenance,
        ] {
            hook.event = event
            #expect(!hook.abortsRunOnFailure, "\(event) must not be able to abort")
        }
    }

    @Test("a repository hook is told which maintenance task it surrounds")
    func maintenanceTaskVariable() {
        var context = context(event: .beforeMaintenance)
        #expect(context.environment["SWIFTRESTIC_TASK"] == nil)
        context.maintenanceTask = "prune"
        #expect(context.environment["SWIFTRESTIC_TASK"] == "prune")
    }

    @Test("hooks run in order and stop at one that aborts")
    func runsInOrderAndStops() async {
        func hook(_ name: String, command: String, aborts: Bool = false) -> BackupHook {
            var hook = BackupHook()
            hook.name = name
            hook.event = .beforeBackup
            hook.command = command
            hook.failureBehaviour = aborts ? .abortBackup : .ignore
            return hook
        }

        var disabled = hook("skipped", command: "exit 1")
        disabled.isEnabled = false
        var blank = hook("blank", command: "   ")

        let hooks = [
            hook("first", command: "exit 0"),
            disabled,
            blank,
            hook("blocker", command: "exit 3", aborts: true),
            hook("never runs", command: "exit 0"),
        ]

        let result = await HookRunner(runner: ResticRunner())
            .runHooks(hooks, event: .beforeBackup, context: context(event: .beforeBackup))
        #expect(result.shouldAbort)
        #expect(result.outcomes.map(\.hookName) == ["first", "blocker"])
    }
}
