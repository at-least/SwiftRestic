import Foundation
import Testing

/// A fake `restic` executable for the fault-path tests.
///
/// The script is installed per-fixture and picks its behaviour from the
/// `SWIFTRESTIC_STUB` environment variable, which tests set through the
/// repository's extra environment. That makes the failure modes a CLI wrapper
/// actually owns — a child that hangs, dribbles progress, dies mid-line, or
/// refuses to launch — reachable in milliseconds, without gigabytes of bulk
/// data existing only to keep a run alive until a cancel lands.
struct StubRestic: Sendable {
    let url: URL
    /// The argument the hung stub sleeps on. Unique per install, so a
    /// process-table check finds *this* stub and never another test's.
    let sleepMarker: String

    static func install(in directory: URL) throws -> StubRestic {
        // Nine digits: macOS sleep rejects arguments of 2^31 and up, and the
        // hang mode must be able to outlast any test.
        let marker = Int.random(in: 100_000_000 ... 999_999_999)
        let url = directory.appendingPathComponent("stub-restic")
        try script(sleepMarker: String(marker)).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return StubRestic(url: url, sleepMarker: "sleep \(marker)")
    }

    private static func script(sleepMarker: String) -> String {
        """
        #!/bin/sh
        # Fake restic for SwiftRestic's tests; behaviour picked by $SWIFTRESTIC_STUB.
        # $SWIFTRESTIC_TRACE, when set, collects which lines actually ran.
        trace() { [ -n "$SWIFTRESTIC_TRACE" ] && echo "$1" >> "$SWIFTRESTIC_TRACE" || true; }
        trace "start args=[$*] stub=$SWIFTRESTIC_STUB"

        case " $* " in
            *" version "*)
                trace "version-arm"
                echo "restic 0.0.0-stub compiled with sh on darwin"
                exit 0
                ;;
        esac

        case "$SWIFTRESTIC_STUB" in
            hang | hang-backup)
                trace "$SWIFTRESTIC_STUB-arm"
                # hang-backup hangs only a backup: AppModel fires follow-up
                # snapshot/stats refreshes once a run ends, and those must
                # answer instead of burning their 300 s refresh timeout.
                if [ "$SWIFTRESTIC_STUB" = "hang-backup" ]; then
                    case " $* " in
                        *" backup "*) ;;
                        *)
                            trace "answer-empty"
                            echo "[]"
                            exit 0
                            ;;
                    esac
                fi
                # Forked form, deliberately not `exec`: under the xctest host
                # exec'ing into sleep behaved unreliably — the trace reached
                # the hang arm but the shell was never replaced — while plain
                # fork+exec works everywhere. The trap forwards the runner's
                # SIGTERM to the sleep child, so nothing outlives the
                # cancellation and the process table still shows the marker.
                trap 'kill -TERM "$sleepChild" 2>/dev/null' TERM
                sleep \(sleepMarker) &
                sleepChild=$!
                wait "$sleepChild"
                exit 0
                ;;
            dribble)
                # A status line first, the rest of the run over a second later:
                # progress callbacks must arrive in between, not at exit.
                trace "dribble-arm"
                echo '{"message_type":"status","percent_done":0.25,"total_files":4,"files_done":1,"total_bytes":400,"bytes_done":100,"current_files":["a.txt"],"seconds_elapsed":1}'
                sleep 1.2
                echo '{"message_type":"status","percent_done":1,"total_files":4,"files_done":4,"total_bytes":400,"bytes_done":400,"current_files":[],"seconds_elapsed":2}'
                echo '{"message_type":"summary","files_new":4,"total_files_processed":4,"total_bytes_processed":400,"snapshot_id":"deadbeef00000000"}'
                exit 0
                ;;
            torn)
                # Binary noise mid-stream, then a well-formed fatal error, then a
                # final line cut off mid-JSON with no trailing newline: what the
                # pipe looks like when the writer dies mid-write.
                trace "torn-arm"
                printf '\\377\\376 not utf8\\n'
                echo '{"message_type":"exit_error","code":1,"message":"boom"}'
                printf '{"message_type":"summary","snapsh'
                exit 1
                ;;
            plainfail)
                trace "plainfail-arm"
                echo "Fatal: unable to open config file" >&2
                exit 17
                ;;
            *)
                # Everything the fault tests do not care about gets an empty answer.
                trace "default-arm"
                echo "[]"
                exit 0
                ;;
        esac
        """
    }
}

/// The runner's failure paths, driven by the stub binary: no real restic and no
/// large fixtures, so these run everywhere and run fast.
@Suite("restic runner fault paths", .serialized)
struct StubResticTests {
    private struct Fixture {
        var root: URL
        var stub: StubRestic
        var context: RepositoryContext
        var service: ResticService
        var plan: BackupPlan
    }

    private func makeFixture(mode: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticStub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stub = try StubRestic.install(in: root)

        var repository = Repository()
        repository.kind = .local
        repository.localPath = root.appendingPathComponent("repo").path
        repository.extraEnvironment = [
            "SWIFTRESTIC_STUB": mode,
            // Where the stub logs which lines of itself actually ran.
            "SWIFTRESTIC_TRACE": root.appendingPathComponent("stub-trace.log").path,
        ]

        var plan = BackupPlan()
        plan.name = "Stub plan"
        plan.repositoryID = repository.id
        plan.sources = [root.path]
        plan.excludePatterns = []

        return Fixture(
            root: root,
            stub: stub,
            context: RepositoryContext(repository: repository, password: "stub"),
            service: ResticService(runner: ResticRunner(), binary: stub.url),
            plan: plan
        )
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Polls the process table until nothing matches `pattern`, or time runs out.
    private static func processVanishes(matching pattern: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if findProcesses(matching: pattern).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return findProcesses(matching: pattern).isEmpty
    }

    /// `/usr/bin/pgrep -f`: exit 1 means no match, output is one pid per line.
    private static func findProcesses(matching pattern: String) -> [String] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch { return ["pgrep-unavailable"] }
        pgrep.waitUntilExit()
        guard pgrep.terminationStatus == 0 else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Process-table snapshot for failure diagnostics, narrowed to stub-related lines.
    private static func processSnapshot() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,stat=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return "ps unavailable" }
        // Read to EOF before waiting: draining the pipe is what lets ps exit,
        // so waiting first could deadlock on a full buffer.
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        return text.split(separator: "\n")
            .filter { $0.contains("stub-restic") || $0.contains("sleep ") }
            .joined(separator: "\n")
    }

    @Test("cancelling a backup ends the run and the child process is really gone")
    func cancellationKillsTheChild() async throws {
        let fixture = try makeFixture(mode: "hang")
        defer { cleanUp(fixture.root) }

        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        let task = Task { try await service.backup(context, plan: plan) }
        // Wait until the stub's sleep child is actually in the process table:
        // that hang is what guarantees the cancel lands mid-run, so the test
        // must not assume a fixed delay — a cold first spawn can take a moment.
        // If the hang never establishes, this fails with the stub's own trace.
        let hangDeadline = Date.now.addingTimeInterval(10)
        while Date.now < hangDeadline,
              Self.findProcesses(matching: fixture.stub.sleepMarker).isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let hangEstablished = !Self.findProcesses(matching: fixture.stub.sleepMarker).isEmpty
        if !hangEstablished {
            let trace = (try? String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)) ?? "no trace"
            Issue.record("the stub never established its hang within 10 s; trace: [\(trace)]; ps saw: [\(Self.processSnapshot())]")
        }
        task.cancel()

        // The run must finish promptly; a bounded wait so a regression fails
        // the test instead of hanging CI.
        let finished = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { _ = try? await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return false }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        #expect(finished, "the backup task did not finish within 15 s of cancellation")

        // Throwing .cancelled is the Swift side; the child itself must not
        // outlive the cancellation as an orphan holding the repository.
        #expect(
            await Self.processVanishes(matching: fixture.stub.sleepMarker, within: 10),
            "the stub restic process outlived the cancellation"
        )

        // And the Swift side must have seen it as a cancellation, not a crash.
        await #expect(throws: ResticError.self) {
            try await task.value
        }
    }

    @Test("status lines are decoded and delivered while the run is still going")
    func progressArrivesMidRun() async throws {
        let fixture = try makeFixture(mode: "dribble")
        defer { cleanUp(fixture.root) }

        let firstProgress = ProgressTimestamp()
        let startedAt = Date.now
        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan) { progress in
            if progress.bytesDone == 100 { firstProgress.mark() }
        }
        let elapsed = Date.now.timeIntervalSince(startedAt)

        // The status line's numbers must have survived the decode.
        let at = try #require(firstProgress.value, "no progress with bytes_done == 100 was ever reported")
        // The stub emits that line first and only exits ~1.2 s later, so a
        // healthy pipe delivers it near 0% of the run. If the reader buffers
        // until EOF the ratio jumps to 100% — the regression this guards.
        let arrival = at.timeIntervalSince(startedAt)
        #expect(arrival < 0.7 * elapsed, "progress first arrived at \(Int(arrival / elapsed * 100))% of the run — the pipe reader is buffering again")

        // The closing summary is parsed into the outcome.
        #expect(outcome.exitCode == 0)
        #expect(outcome.summary?.snapshotID == "deadbeef00000000")
        #expect(outcome.summary?.filesNew == 4)
    }

    @Test("a command that outlives its timeout is killed and reported as timed out")
    func watchdogKillsHungCommand() async throws {
        let fixture = try makeFixture(mode: "hang")
        defer { cleanUp(fixture.root) }

        do {
            _ = try await fixture.service.snapshots(fixture.context, timeout: 1)
            Issue.record("snapshots against a hung stub should have timed out")
        } catch let ResticError.timedOut(seconds, command) {
            #expect(seconds == 1)
            #expect(command.contains("snapshots"))
        }
        #expect(
            await Self.processVanishes(matching: fixture.stub.sleepMarker, within: 10),
            "the watchdog left the stub process alive"
        )
    }

    @Test("a run that dies mid-line still surfaces its real error message")
    func tornFinalLineCannotHideTheError() async throws {
        let fixture = try makeFixture(mode: "torn")
        defer { cleanUp(fixture.root) }

        do {
            _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)
            Issue.record("expected the torn run to fail")
        } catch let ResticError.commandFailed(code, message, _) {
            #expect(code == 1)
            // The well-formed exit_error must win; the torn tail line and the
            // invalid-UTF-8 line must have been dropped without breaking it.
            #expect(message == "boom", "error message was \(message.debugDescription)")
        }
    }

    @Test("an unexpected exit code fails with restic's own stderr as the message")
    func plainFailureCarriesStderrTail() async throws {
        let fixture = try makeFixture(mode: "plainfail")
        defer { cleanUp(fixture.root) }

        do {
            _ = try await fixture.service.backup(fixture.context, plan: fixture.plan)
            Issue.record("expected the exit-17 run to fail")
        } catch let ResticError.commandFailed(code, message, _) {
            #expect(code == 17)
            #expect(message.contains("unable to open config file"))
        }
    }

    @Test("a binary that cannot be spawned reports a launch failure")
    func missingBinarySurfacesLaunchError() async throws {
        let fixture = try makeFixture(mode: "hang")
        defer { cleanUp(fixture.root) }

        let service = ResticService(
            runner: ResticRunner(),
            binary: fixture.root.appendingPathComponent("no-such-restic")
        )
        do {
            _ = try await service.version()
            Issue.record("expected the missing binary to fail")
        } catch {
            // The exact failure, not a generic command failure.
            guard case ResticError.processLaunchFailed(_) = error else {
                Issue.record("expected a launch failure, got \(error)")
                return
            }
        }
    }
}

/// First-observation timestamp for `@Sendable` progress callbacks.
final class ProgressTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date?

    func mark() {
        lock.lock()
        if date == nil { date = Date.now }
        lock.unlock()
    }

    var value: Date? {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
}
