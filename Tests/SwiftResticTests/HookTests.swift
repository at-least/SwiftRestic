import Foundation
import Testing

@Suite("Backup hooks")
struct HookTests {
    private func context(event: BackupHook.Event = .afterBackup) -> HookRunner.Context {
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
        #expect(env["SWIFTRESTIC_EVENT"] == "afterBackup")
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
        hook.command = #"printf '%s %s' "$SWIFTRESTIC_PLAN_NAME" "$SWIFTRESTIC_SNAPSHOT_ID" > "\#(marker.path)"; echo done"#

        let outcome = await HookRunner(runner: ResticRunner()).run(hook, context: context())
        #expect(outcome.succeeded)
        #expect(outcome.exitCode == 0)
        #expect(outcome.output.contains("done"))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "Documents abc12345")
    }

    @Test("a hook runs from the home directory, not the app's inherited cwd")
    func runsFromHomeDirectory() async throws {
        var hook = BackupHook()
        hook.command = "pwd"

        let outcome = await HookRunner(runner: ResticRunner()).run(hook, context: context())

        #expect(outcome.succeeded)
        // A Finder-launched GUI app inherits `/`; a hook's relative paths
        // must not depend on that accident.
        #expect(outcome.output.contains(NSHomeDirectory()))
    }

    @Test("a non-zero exit is reported, not thrown")
    func failingCommand() async {
        var hook = BackupHook()
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
        hook.command = "sleep 30"

        let started = Date.now
        let outcome = await HookRunner(runner: ResticRunner(), timeout: 1).run(hook, context: context())
        #expect(outcome.timedOut)
        #expect(!outcome.succeeded)
        #expect(Date.now.timeIntervalSince(started) < 10)
        #expect(outcome.summary.contains("timed out"))
    }

    @Test("a failing before hook always cancels the run, an after hook never")
    func onlyBeforeHooksCanAbort() {
        var hook = BackupHook()
        hook.event = .beforeBackup
        #expect(hook.abortsRunOnFailure)
        // By the time it runs the snapshot exists: "cancel" would be meaningless.
        hook.event = .afterBackup
        #expect(!hook.abortsRunOnFailure)
    }

    @Test("a hook is named by its program, never its arguments or leading variables, which hold its tokens")
    func displayNameIsTheProgram() {
        func name(_ command: String) -> String {
            var hook = BackupHook()
            hook.command = command
            return hook.displayName
        }
        #expect(name("/usr/local/bin/notify.sh --token abc") == "notify.sh")
        #expect(name("TOKEN=abc curl https://example.com") == "curl")
        #expect(name("   ") == "Untitled Hook")
        #expect(name("A=1 B=2") == "Untitled Hook")
    }

    @Test("an older build's hooks: every end reads as after a backup, a switched-off or repository one never starts running")
    func storedHooks() throws {
        func read(_ fields: String) throws -> BackupHook? {
            try JSONDecoder().decode(StoredHook.self, from: Data("{\(fields)}".utf8)).hook
        }
        for old in ["afterSuccess", "afterWarning", "afterFailure", "afterAny", "afterBackup"] {
            #expect(try read(#""event":"\#(old)","command":"true""#)?.event == .afterBackup, "\(old)")
        }
        #expect(try read(#""event":"beforeBackup","command":"true","failureBehaviour":"ignore""#)?.abortsRunOnFailure == true)
        #expect(try read(#""event":"afterSuccess","command":"true","isEnabled":false"#) == nil)
        #expect(try read(#""event":"beforeMaintenance","command":"true""#) == nil)
        #expect(try read(#""event":"invented","command":"true""#) == nil)
        #expect(try read(#""command":"true""#) == nil)
        // Left out, and said: a stored event this build can't place.
        let notes = DecodeNoteBox()
        let unplaced = try DecodeNotes.$current.withValue(notes) { try read(#""event":"invented","command":"true""#) }
        #expect(unplaced == nil)
        #expect(notes.notes.count == 1 && notes.notes[0].contains("invented"))
        // Written by this build, the fields it dropped are gone.
        var hook = BackupHook()
        hook.command = "true"
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(hook)) as? [String: Any])
        #expect(object["event"] as? String == "afterBackup")
        #expect(object["isEnabled"] == nil && object["name"] == nil && object["timeoutSeconds"] == nil)
    }

    @Test("hooks run in order and stop at one that aborts")
    func runsInOrderAndStops() async {
        func hook(command: String) -> BackupHook {
            var hook = BackupHook()
            hook.event = .beforeBackup
            hook.command = command
            return hook
        }

        let hooks = [
            hook(command: "true"),
            hook(command: "   "),
            hook(command: "false"),
            hook(command: "pwd"),
        ]

        let result = await HookRunner(runner: ResticRunner())
            .runHooks(hooks, event: .beforeBackup, context: context(event: .beforeBackup))
        #expect(result.shouldAbort)
        #expect(result.outcomes.map(\.hookName) == ["true", "false"])
    }

    @Test("a hook never writes into the run's transcript, not even its command line")
    func hookStaysOutOfTheTranscript() async {
        var hook = BackupHook()
        hook.command = "echo token=abc123"

        let transcript = RunTranscript()
        let outcome = await RunTranscript.$current.withValue(transcript) {
            await HookRunner(runner: ResticRunner()).run(hook, context: context())
        }
        #expect(outcome.succeeded)
        // A script's command and output can carry secrets; the run's log is
        // copied to the clipboard on request, so neither may reach it.
        #expect(transcript.contents.entries.isEmpty, "entries were \(transcript.contents.entries.map(\.text))")
    }

    @Test("a hook's log line carries its verdict, never its output")
    func hookLogLine() {
        let failed = HookRunner.Outcome(hookName: "n", exitCode: 1, output: "Authorization: Bearer x", timedOut: false)
        #expect(failed.logLine == "Hook “n” exited 1.")
        #expect(!failed.logLine.contains("Bearer"))
        let succeeded = HookRunner.Outcome(hookName: "n", exitCode: 0, output: "secret", timedOut: false)
        #expect(succeeded.logLine == "Hook “n” succeeded.")
        let timedOut = HookRunner.Outcome(hookName: "n", exitCode: -1, output: "secret", timedOut: true)
        #expect(timedOut.logLine == "Hook “n” timed out and was stopped.")
        let cancelled = HookRunner.Outcome(hookName: "n", exitCode: -1, output: "", timedOut: false, cancelled: true)
        #expect(cancelled.logLine == "Hook “n” was stopped before it finished.")
    }

    @Test("a cancelled run is not recorded as a failed hook")
    func cancelledHookIsNotAFailure() async throws {
        let started = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticHookStarted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: started) }
        var hook = BackupHook()
        hook.event = .beforeBackup
        hook.command = "touch '\(started.path)'; sleep 30"

        let task = Task {
            await HookRunner(runner: ResticRunner())
                .runHooks([hook], event: .beforeBackup, context: context(event: .beforeBackup))
        }
        // Cancelled while the hook runs, not before it starts.
        try #require(
            await eventually(within: 60) { FileManager.default.fileExists(atPath: started.path) },
            "the hook never started"
        )
        task.cancel()
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.outcomes.count == 1)

        // The user's cancel must not masquerade as the hook failing: no
        // "exited -1" line reading as a hook error, and no abort decision
        // made on the cancel's behalf.
        #expect(!result.shouldAbort, "a cancelled hook must not abort the run")
        #expect(
            !result.outcomes.contains { $0.summary.contains("exited") },
            "summaries were: \(result.outcomes.map(\.summary))"
        )
    }
}
