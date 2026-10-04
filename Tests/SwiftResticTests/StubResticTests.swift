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

    /// `/usr/bin/pgrep -f`: exit 1 means no match, output is one pid per line.
    static func findProcesses(matching pattern: String) -> [String] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run() } catch {
            // A broken pgrep must not read as "processes found": report the
            // real cause against the running test and nothing, so hang checks
            // fail loudly with evidence instead of passing on a phantom list.
            Issue.record("pgrep could not run: \(error)")
            return []
        }
        pgrep.waitUntilExit()
        guard pgrep.terminationStatus == 0 else { return [] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Polls the process table until nothing matches `pattern`, or time runs out.
    static func processVanishes(matching pattern: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if findProcesses(matching: pattern).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return findProcesses(matching: pattern).isEmpty
    }

    /// Polls the process table until the stub's sleep child shows up in it.
    ///
    /// Tests that cancel or quit mid-run need the hang actually established:
    /// a fixed delay bets on spawn speed, which is exactly what a cold runner
    /// loses. The sleep marker is what the hung stub is sleeping on.
    static func waitForHang(matching marker: String, within seconds: TimeInterval) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            if !findProcesses(matching: marker).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !findProcesses(matching: marker).isEmpty
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
            hang-once)
                # Hangs the very first invocation only, answers every later
                # one: drives the "a request arrived while the first read
                # hung" paths deterministically — the flag lives beside the
                # trace log, so no extra environment is needed.
                trace "hang-once-arm"
                flag="$(dirname "$SWIFTRESTIC_TRACE")/hang-once.flag"
                if [ ! -f "$flag" ]; then
                    touch "$flag"
                    trap 'kill -TERM "$sleepChild" 2>/dev/null' TERM
                    sleep \(sleepMarker) &
                    sleepChild=$!
                    wait "$sleepChild"
                    exit 0
                fi
                trace "hang-once-answered"
                echo "[]"
                exit 0
                ;;
            hang | hang-backup | hang-restore | hang-check | hang-stats | hang-listing | hang-forget)
                trace "$SWIFTRESTIC_STUB-arm"
                # The selective modes hang one subcommand only: AppModel fires
                # follow-up snapshot/stats refreshes once a run ends, and those
                # must answer instead of burning their 300 s refresh timeout.
                hang_this=1
                if [ "$SWIFTRESTIC_STUB" = "hang-backup" ]; then
                    case " $* " in
                        *" backup "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$SWIFTRESTIC_STUB" = "hang-restore" ]; then
                    case " $* " in
                        *" restore "* | *" dump "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$SWIFTRESTIC_STUB" = "hang-check" ]; then
                    case " $* " in
                        *" check "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$SWIFTRESTIC_STUB" = "hang-stats" ]; then
                    case " $* " in
                        *" stats "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$SWIFTRESTIC_STUB" = "hang-listing" ]; then
                    case " $* " in
                        *" snapshots "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$SWIFTRESTIC_STUB" = "hang-forget" ]; then
                    case " $* " in
                        *" forget "*) ;;
                        *) hang_this=0 ;;
                    esac
                fi
                if [ "$hang_this" = "0" ]; then
                    trace "answer-empty"
                    echo "[]"
                    exit 0
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
            warn)
                # A backup that finished but could not read one item — restic's
                # exit 3, the "partial success" the app must not call a failure.
                trace "warn-arm"
                echo '{"message_type":"error","error":{"message":"permission denied"},"during":"archival","item":"/etc/secret-target"}'
                echo '{"message_type":"summary","files_new":0,"total_files_processed":1,"total_bytes_processed":10,"snapshot_id":"feedface00000000"}'
                exit 3
                ;;
            malformed)
                # A known message_type whose payload does not decode: a restic
                # newer than the schema the app pins. The run exits clean —
                # the decoder's downgrade must not let it read as clean too.
                trace "malformed-arm"
                echo '{"message_type":"status","percent_done":"not-a-number"}'
                echo '{"message_type":"summary","files_new":1,"total_files_processed":1,"total_bytes_processed":10,"snapshot_id":"feedface00000000"}'
                exit 0
                ;;
            missing)
                # restic's exit 10: the repository is not there or not initialised.
                trace "missing-arm"
                echo "Fatal: repository does not exist" >&2
                echo '{"message_type":"exit_error","code":10,"message":"Fatal: repository does not exist"}'
                exit 10
                ;;
            wrongpassword)
                # restic's exit 12: the stored password doesn't open the
                # repository — the trust-critical failure whose copy must name
                # the fix instead of offering a Retry that cannot succeed.
                trace "wrongpassword-arm"
                echo "Fatal: wrong password or no matching key" >&2
                exit 12
                ;;
            checkdamage)
                # restic's exit 1 when a check finds damage: the check did its
                # job, and its summary — the error count the run record names —
                # still has to arrive, not be read as a command failure.
                trace "checkdamage-arm"
                case " $* " in
                    *" check "*)
                        echo '{"message_type":"summary","num_errors":2,"broken_packs":null,"suggest_repair_index":false,"suggest_prune":true}'
                        ;;
                    *)
                        echo "[]"
                        exit 0
                        ;;
                esac
                exit 1
                ;;
            checkbroken)
                # Exit 1 with no summary at all: an answer the app cannot read
                # a verdict from must fail the check, never pass for healthy.
                trace "checkbroken-arm"
                echo "Fatal: repository contains errors" >&2
                exit 1
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
            dribble-wait)
                # The dribble shape with a handoff instead of a fixed pause:
                # after the first status line the run stays open until the
                # test's progress callback plants the flag beside the trace,
                # so "delivered while the run is still going" holds whatever
                # load does to the clocks. The patience — 600 sleeps of
                # 0.05 s, 30 s and more with their spawns — only bounds a
                # reader that buffers to EOF; the runner's 15-minute idle cap
                # cannot cut it short.
                trace "dribble-wait-arm"
                echo '{"message_type":"status","percent_done":0.25,"total_files":4,"files_done":1,"total_bytes":400,"bytes_done":100,"current_files":["a.txt"],"seconds_elapsed":1}'
                flag="$(dirname "$SWIFTRESTIC_TRACE")/progress-seen.flag"
                waited=0
                while [ ! -f "$flag" ] && [ "$waited" -lt 600 ]; do
                    sleep 0.05
                    waited=$((waited + 1))
                done
                if [ -f "$flag" ]; then trace "progress-flag-seen"; else trace "progress-flag-timeout"; fi
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
            snaprows)
                # One well-formed snapshot for `snapshots`, a decodable size
                # for `stats`, empty answers for everything else: drives the
                # "a listing that succeeded once, then a refresh failed"
                # scenarios at the model level — with a size the UI can keep
                # holding onto when a later read is stopped.
                trace "snaprows-arm"
                case " $* " in
                    *" snapshots "*)
                        echo '[{"id":"feedface00000000","short_id":"feedface","time":"2026-01-02T03:04:05Z","hostname":"stub","paths":["/src"],"tags":["stub"]}]'
                        ;;
                    *" stats "*)
                        echo '{"total_size":4096,"total_file_count":1}'
                        ;;
                    *)
                        echo "{}"
                        ;;
                esac
                exit 0
                ;;
            browserows)
                # The browse surface: real node rows for `ls`, change rows
                # for `diff` — one of them a directory whose name ends in
                # U+0600 (raw UTF-8, as restic writes it), whose trailing
                # slash a Character test cannot see. The trace's
                # per-invocation start lines are what lets a test prove a
                # repeat browse reads the cache instead of spawning restic
                # again.
                trace "browserows-arm"
                case " $* " in
                    *" snapshots "*)
                        echo "[]"
                        ;;
                    *" ls "*)
                        echo '{"message_type":"node","name":"src","type":"dir","path":"/src","size":0,"mtime":"2026-01-02T03:04:05Z"}'
                        echo '{"message_type":"node","name":"notes.txt","type":"file","path":"/src/notes.txt","size":42,"mtime":"2026-01-02T03:04:05Z"}'
                        ;;
                    *" diff "*)
                        echo '{"message_type":"change","path":"/src/new.txt","modifier":"+"}'
                        echo '{"message_type":"change","path":"/src/gone.txt","modifier":"-"}'
                        printf '{"message_type":"change","path":"/src/new\\330\\200/","modifier":"+"}\\n'
                        ;;
                    *)
                        echo "{}"
                        ;;
                esac
                exit 0
                ;;
            diffmalformed)
                # A diff that exits cleanly but whose second change line does
                # not decode (a path that is not a string, as a restic newer
                # than the pinned schema might write): a change the decoder
                # dropped is one the Change column would show as unchanged.
                trace "diffmalformed-arm"
                case " $* " in
                    *" snapshots "*)
                        echo "[]"
                        ;;
                    *" diff "*)
                        echo '{"message_type":"change","path":"/src/new.txt","modifier":"+"}'
                        echo '{"message_type":"change","path":1,"modifier":"-"}'
                        ;;
                    *)
                        echo "{}"
                        ;;
                esac
                exit 0
                ;;
            lsmalformed)
                # A full `ls` that exits cleanly but whose third node line does
                # not decode (a path that is not a string, as a restic newer
                # than the pinned schema might write), with a good node after
                # it: a node the decoder dropped is one the index would read
                # as absent from the snapshot. restic's snapshot header line
                # comes first, as `ls --json` writes it, and must not count.
                trace "lsmalformed-arm"
                case " $* " in
                    *" snapshots "*)
                        echo "[]"
                        ;;
                    *" ls "*)
                        echo '{"time":"2026-01-02T03:04:05Z","tree":"0000","paths":["/src"],"hostname":"stub","id":"feedface00000000","short_id":"feedface","struct_type":"snapshot","message_type":"snapshot"}'
                        echo '{"name":"src","type":"dir","path":"/src","mtime":"2026-01-02T03:04:05Z","struct_type":"node","message_type":"node"}'
                        echo '{"name":"notes.txt","type":"file","path":"/src/notes.txt","size":42,"mtime":"2026-01-02T03:04:05Z","struct_type":"node","message_type":"node"}'
                        echo '{"name":"lost.txt","type":"file","path":1,"size":7,"struct_type":"node","message_type":"node"}'
                        echo '{"name":"after.txt","type":"file","path":"/src/after.txt","size":3,"mtime":"2026-01-02T03:04:05Z","struct_type":"node","message_type":"node"}'
                        ;;
                    *)
                        echo "{}"
                        ;;
                esac
                exit 0
                ;;
            difffail)
                # A diff that dies partway: one change streams, then restic's
                # fatal error on stderr (where real restic writes it) and exit
                # 1. The Change column must say the comparison stopped short
                # rather than pass the partial map off as the whole answer.
                trace "difffail-arm"
                case " $* " in
                    *" snapshots "*)
                        echo "[]"
                        ;;
                    *" diff "*)
                        echo '{"message_type":"change","path":"/src/new.txt","modifier":"+"}'
                        echo '{"message_type":"exit_error","code":1,"message":"Fatal: no matching ID found for prefix \\"feedface\\""}' >&2
                        exit 1
                        ;;
                    *)
                        echo "{}"
                        ;;
                esac
                exit 0
                ;;
            missingsource)
                # One source folder gone (an unmounted volume, a renamed
                # folder): restic 0.19.1 names it only in plain text on
                # stderr, writes the snapshot of the rest and exits 3 — no
                # message_type:error event at all. Everything else answers
                # empty.
                trace "missingsource-arm"
                case " $* " in
                    *" backup "*)
                        echo "/src/gone does not exist, skipping" >&2
                        echo '{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":2,"total_files_processed":3,"total_bytes_processed":5000,"data_added":5300,"snapshot_id":"61b0f11423fd96e36f2fb2ddefdb4d41a4331adf2041828fcef2f679eaf97bfe"}'
                        echo '{"message_type":"exit_error","code":3,"message":"Warning: at least one source file could not be read"}' >&2
                        exit 3
                        ;;
                esac
                echo "[]"
                exit 0
                ;;
            restoreskip)
                # A restore into a folder that already holds most of the
                # backup's files: restic keeps them and says so in its
                # summary. The arguments land in the trace's start line.
                trace "restoreskip-arm"
                case " $* " in
                    *" restore "*)
                        echo '{"message_type":"summary","total_files":3,"files_restored":1,"files_skipped":3,"bytes_skipped":30}'
                        exit 0
                        ;;
                esac
                echo "[]"
                exit 0
                ;;
            tccblocked)
                # A backup macOS's privacy protection partly refused, in the
                # shapes restic 0.19.1 printed on 2026-09-26: a folder it may
                # not list arrives twice (scan, then archival) with EPERM's
                # words, a mode-000 file once with EACCES's. The home folder
                # is spelled out so the test never depends on $HOME reaching
                # the child. Everything else answers empty.
                trace "tccblocked-arm"
                case " $* " in
                    *" backup "*)
                        echo '{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /Users/stub/Library/Mail: operation not permitted"},"during":"scan","item":"/Users/stub/Library/Mail"}' >&2
                        echo '{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /Users/stub/Library/Mail: operation not permitted"},"during":"archival","item":"/Users/stub/Library/Mail"}' >&2
                        echo '{"message_type":"error","error":{"message":"open /Users/stub/locked.txt: permission denied"},"during":"archival","item":"/Users/stub/locked.txt"}' >&2
                        echo '{"message_type":"summary","files_new":1,"files_changed":0,"files_unmodified":0,"total_files_processed":1,"total_bytes_processed":10,"data_added":10,"snapshot_id":"7cc0b10c00000000"}'
                        echo '{"message_type":"exit_error","code":3,"message":"Warning: at least one source file could not be read"}' >&2
                        exit 3
                        ;;
                esac
                echo "[]"
                exit 0
                ;;
            dumpappears)
                # A single-file restore whose landing is taken while the dump
                # runs — a user's copy, an iCloud re-download: `dump` writes
                # "mine" at <trace dir>/restored/<the file's name>, where the
                # test restores to, and only then prints the backed-up bytes.
                trace "dumpappears-arm"
                case " $* " in
                    *" dump "*)
                        for last in "$@"; do :; done
                        printf mine > "$(dirname "$SWIFTRESTIC_TRACE")/restored/$(basename "$last")"
                        printf new
                        exit 0
                        ;;
                esac
                echo "[]"
                exit 0
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
        let createdAt = Date.now
        let taskStarted = ProgressTimestamp()
        let task = Task {
            taskStarted.mark()
            return try await service.backup(context, plan: plan)
        }
        // The hang is what guarantees the cancel lands mid-run, so the test
        // must not assume a fixed delay — a cold first spawn can take a moment,
        // and under load more than 10 s: 3 of 13 runs on 2026-10-04 found no
        // stub and no trace by then. The wait ends the moment the hang shows,
        // so its length costs a healthy run nothing.
        // If the hang never establishes, this fails with the stub's own trace
        // and when the backup's task got a thread, if it ever did.
        let hangEstablished = await StubRestic.waitForHang(matching: fixture.stub.sleepMarker, within: 60)
        if !hangEstablished {
            let trace = (try? String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)) ?? "no trace"
            let started = taskStarted.value.map {
                "the backup's task started \(String(format: "%.2f", $0.timeIntervalSince(createdAt))) s after it was made"
            } ?? "the backup's task never started"
            Issue.record("the stub never established its hang within 60 s; \(started); trace: [\(trace)]; ps saw: [\(Self.processSnapshot())]")
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
            await StubRestic.processVanishes(matching: fixture.stub.sleepMarker, within: 10),
            "the stub restic process outlived the cancellation"
        )

        // And the Swift side must have seen it as a cancellation, not a crash.
        await #expect(throws: ResticError.self) {
            try await task.value
        }
    }

    @Test("status lines are decoded and delivered while the run is still going", .timeLimit(.minutes(1)))
    func progressArrivesMidRun() async throws {
        let fixture = try makeFixture(mode: "dribble-wait")
        defer { cleanUp(fixture.root) }
        let flag = fixture.root.appendingPathComponent("progress-seen.flag")

        let firstProgress = ProgressTimestamp()
        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan) { progress in
            guard progress.bytesDone == 100 else { return }
            firstProgress.mark()
            // The handoff: the stub ends only after it sees this flag, so the
            // run is provably still going when the line is delivered. A
            // wall-clock ratio stood here before — first line before 70% of
            // a run held open 1.2 s — and load stretched the time before the
            // first line past it in 4 of 13 runs on 2026-10-04.
            FileManager.default.createFile(atPath: flag.path, contents: nil)
        }

        // The status line's numbers must have survived the decode.
        try #require(firstProgress.value != nil, "no progress with bytes_done == 100 was ever reported")
        // A reader that buffers until EOF delivers the line only after the
        // stub gave up waiting — the regression this guards.
        let trace = try String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
        #expect(
            trace.contains("progress-flag-seen"),
            "the stub never saw the first status line delivered mid-run — the pipe reader is buffering again; trace: [\(trace)]"
        )

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
            await StubRestic.processVanishes(matching: fixture.stub.sleepMarker, within: 10),
            "the watchdog left the stub process alive"
        )
    }

    @Test("a child that ignores SIGTERM is killed after the grace and still reported")
    func ignoredSigtermEscalatesToKill() async throws {
        let runner = ResticRunner()
        let startedAt = Date.now
        do {
            // `trap "" TERM` makes the shell decline the polite request; the
            // busy loop never ends on its own. Without the escalation this
            // run would hang forever.
            _ = try await runner.run(
                binary: URL(fileURLWithPath: "/bin/sh"),
                invocation: ResticInvocation(
                    arguments: ["-c", #"trap "" TERM; while :; do :; done"#],
                    timeout: 1
                )
            )
            Issue.record("a command that ignores SIGTERM must be stopped as timed out")
        } catch let ResticError.timedOut(seconds, _) {
            #expect(seconds == 1)
            // The kill grace is measured from the SIGTERM, not the start, so
            // the whole stop takes at least the grace — and its arrival at
            // all is the point: a stuck child would hang here forever.
            let elapsed = Date.now.timeIntervalSince(startedAt)
            #expect(elapsed >= ResticRunner.killGrace, "SIGKILL escalation never fired (stopped after \(elapsed)s)")
            #expect(elapsed < 15, "escalation took too long: \(elapsed)s")
        }
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

    @Test("a backup with undecodable messages is a warning, never a clean run")
    func malformedMessagesSurfaceInTheOutcome() async throws {
        let fixture = try makeFixture(mode: "malformed")
        defer { cleanUp(fixture.root) }

        let outcome = try await fixture.service.backup(fixture.context, plan: fixture.plan)

        // The run finished and the snapshot is real; what must not happen is
        // the clean report a silently-downgraded line used to produce.
        #expect(outcome.exitCode == 0)
        #expect(outcome.summary?.snapshotID == "feedface00000000")
        #expect(outcome.completedWithErrors)
        // The gap is reported beside the unreadable items, not among them:
        // nothing restic read was lost, so nothing is counted as unreadable.
        // That the line still reaches the run record is pinned in
        // BackupRunEngineTests.completeSnapshotsStayCompleteThroughWarnings.
        #expect(
            outcome.decodingWarning?.contains("could not be decoded") == true && outcome.itemErrors.isEmpty,
            "the outcome's warning was \(outcome.decodingWarning ?? "nil"), its items \(outcome.itemErrors)"
        )
    }

    @Test("the runner writes the command, restic's non-progress lines and the exit code into a bound transcript")
    func runnerFillsABoundTranscript() async throws {
        let fixture = try makeFixture(mode: "dribble")
        defer { cleanUp(fixture.root) }

        let transcript = RunTranscript()
        let bound = try await RunTranscript.$current.withValue(transcript) {
            try await fixture.service.backup(fixture.context, plan: fixture.plan)
        }
        let entries = transcript.contents.entries

        let commands = entries.filter { $0.kind == .command }
        #expect(commands.count == 1)
        #expect(commands.first?.text.hasPrefix("restic ") == true, "command was \(commands.first?.text ?? "none")")
        #expect(commands.first?.text.contains("backup --json") == true)
        // The two progress ticks are dropped; the summary is restic's answer.
        #expect(!entries.contains { $0.text.contains(#""message_type":"status""#) }, "entries were \(entries.map(\.text))")
        #expect(entries.contains { $0.kind == .output(.stdout) && $0.text.contains(#""message_type":"summary""#) })
        #expect(entries.last?.kind == .exit(0))
        #expect(transcript.contents.firstExitCode == 0)

        // Unbound, the same run behaves as before and writes nowhere.
        let before = transcript.contents.entries.count
        let unbound = try await fixture.service.backup(fixture.context, plan: fixture.plan)
        #expect(transcript.contents.entries.count == before)
        #expect(unbound.summary == bound.summary)
        #expect(unbound.exitCode == bound.exitCode)
    }

    @Test("a failing command still leaves its words and exit code in the transcript")
    func failingCommandLeavesItsWords() async throws {
        let fixture = try makeFixture(mode: "plainfail")
        defer { cleanUp(fixture.root) }

        let transcript = RunTranscript()
        do {
            _ = try await RunTranscript.$current.withValue(transcript) {
                try await fixture.service.backup(fixture.context, plan: fixture.plan)
            }
            Issue.record("expected the exit-17 run to fail")
        } catch let ResticError.commandFailed(code, _, _) {
            #expect(code == 17)
        }
        let entries = transcript.contents.entries
        #expect(entries.contains { $0.kind == .output(.stderr) && $0.text == "Fatal: unable to open config file" },
                "entries were \(entries.map(\.text))")
        #expect(entries.last?.kind == .exit(17))
        #expect(transcript.contents.firstExitCode == 17)
    }

    @Test("a cancelled command notes the stop instead of an exit code")
    func cancelledCommandNotesTheStop() async throws {
        let fixture = try makeFixture(mode: "hang")
        defer { cleanUp(fixture.root) }

        let transcript = RunTranscript()
        let service = fixture.service
        let context = fixture.context
        let plan = fixture.plan
        let task = Task {
            try await RunTranscript.$current.withValue(transcript) {
                try await service.backup(context, plan: plan)
            }
        }
        #expect(
            await StubRestic.waitForHang(matching: fixture.stub.sleepMarker, within: 10),
            "the stub never established its hang"
        )
        task.cancel()
        _ = try? await task.value

        let entries = transcript.contents.entries
        #expect(entries.contains { $0.kind == .note && $0.text.contains("Stopped") }, "entries were \(entries.map(\.text))")
        #expect(!entries.contains { if case .exit = $0.kind { true } else { false } })
        // A signal's termination status is not an exit code.
        #expect(transcript.contents.firstExitCode == nil)
    }

    @Test("Keep keeps a file that appeared while its dump ran, and says so in the log")
    func keepSurvivesAFileAppearingMidDump() async throws {
        let fixture = try makeFixture(mode: "dumpappears")
        defer { cleanUp(fixture.root) }
        let destination = fixture.root.appendingPathComponent("restored")
        let landing = destination.appendingPathComponent("a.txt")
        let node = SnapshotNode(name: "a.txt", type: .file, path: "/src/a.txt", size: 3)

        // The landing is free when the restore starts, so the pre-check lets
        // the dump run; only the commit can see the file the stub plants.
        let transcript = RunTranscript()
        let summary = try await RunTranscript.$current.withValue(transcript) {
            try await fixture.service.restore(
                fixture.context,
                snapshotID: "latest",
                node: node,
                destinationDirectory: destination,
                overwrite: .keepExisting
            )
        }

        #expect(try String(contentsOf: landing, encoding: .utf8) == "mine", "Keep replaced a file that appeared mid-dump")
        #expect(summary?.filesSkipped == 1)
        #expect(summary?.filesRestored == 0)
        let notes = transcript.contents.entries.filter { $0.kind == .note }.map(\.text)
        #expect(notes.contains { $0.contains("appeared at \(landing.path) during the dump") }, "notes were \(notes)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    @Test("below restic 0.17 no --overwrite is passed, and Keep refuses what it cannot keep")
    func restoreWithoutOverwriteFlag() async throws {
        let fixture = try makeFixture(mode: "restoreskip")
        defer { cleanUp(fixture.root) }
        // restic 0.16 answers "unknown flag: --overwrite" and always replaces.
        let old = ResticService(runner: ResticRunner(), binary: fixture.stub.url, supportsRestoreOverwrite: false)
        let project = SnapshotNode(name: "Project", type: .dir, path: "/src/Project")
        let occupied = fixture.root.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied.appendingPathComponent("Project"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: occupied.appendingPathComponent("Project/a.txt"))

        func restoreStarts() throws -> [String] {
            let trace = try String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
            // The repository travels in the environment, so `restore` can be
            // the first argument, right after the bracket.
            return trace.split(separator: "\n").map(String.init).filter { line in
                line.hasPrefix("start args=[") && line.replacingOccurrences(of: "[", with: " ").contains(" restore ")
            }
        }

        // Replace needs no flag: restic's own default is `always`.
        try await old.restore(fixture.context, snapshotID: "latest", node: project, destinationDirectory: occupied, overwrite: .replaceExisting)
        // Keep into a landing that holds nothing has nothing to keep — a
        // fresh folder, or a drag's UUID directory.
        try await old.restore(fixture.context, snapshotID: "latest", node: project, destinationDirectory: fixture.root.appendingPathComponent("fresh"), overwrite: .keepExisting)
        try await old.restoreWholeSnapshot(fixture.context, snapshotID: "latest", destinationDirectory: fixture.root.appendingPathComponent("fresh-whole"), overwrite: .keepExisting)
        let ran = try restoreStarts()
        #expect(ran.count == 3, "restores started: \(ran)")
        #expect(!ran.contains { $0.contains("--overwrite") }, "restores started: \(ran)")

        // Keep onto files that are there is refused before restic runs.
        let landing = occupied.appendingPathComponent("Project")
        await #expect(throws: ResticError.keepNeedsNewerRestic(path: landing.path)) {
            try await old.restore(fixture.context, snapshotID: "latest", node: project, destinationDirectory: occupied, overwrite: .keepExisting)
        }
        await #expect(throws: ResticError.keepNeedsNewerRestic(path: occupied.path)) {
            try await old.restoreWholeSnapshot(fixture.context, snapshotID: "latest", destinationDirectory: occupied, overwrite: .keepExisting)
        }
        #expect(try restoreStarts().count == 3)
        #expect(try String(contentsOf: landing.appendingPathComponent("a.txt"), encoding: .utf8) == "mine")

        // A current restic gets the flag, whatever the destination holds.
        try await fixture.service.restore(fixture.context, snapshotID: "latest", node: project, destinationDirectory: occupied, overwrite: .keepExisting)
        #expect(try restoreStarts().last?.contains("--overwrite never") == true)
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

    @Test("a check that finds damage returns its summary instead of failing the command")
    func checkDamageCarriesItsSummary() async throws {
        let fixture = try makeFixture(mode: "checkdamage")
        defer { cleanUp(fixture.root) }

        // restic exits 1 on damage; the summary naming the errors is the whole
        // point of the run. The engine turns this into completed-with-errors;
        // here the contract under test is that the service hands the summary
        // up rather than throwing over it.
        let summary = try await fixture.service.check(fixture.context, readDataSubsetPercent: nil)
        #expect(summary?.numErrors == 2)
        #expect(summary?.suggestPrune == true)
    }

    @Test("the retention preview is a lock-free dry run that never prunes")
    func forgetPreviewRunsALockFreeDryRun() async throws {
        let fixture = try makeFixture(mode: "default")
        defer { cleanUp(fixture.root) }
        var plan = fixture.plan
        // Also prune is on: the real forget would prune, the preview must not.
        plan.retention.runPrune = true

        let preview = try await fixture.service.forgetPreview(fixture.context, plan: plan)
        // The default arm answers "[]": nothing kept, nothing removed.
        #expect(preview == RetentionPreview(kept: [], removed: []))

        let trace = try String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
        let start = try #require(
            trace.split(separator: "\n").map(String.init).first { $0.hasPrefix("start args=[") && $0.contains("forget") },
            "trace: \(trace)"
        )
        // Without --no-lock the dry run takes the exclusive lock: it exits
        // 11 during a backup and would fail a backup that started meanwhile.
        for flag in ["forget", "--dry-run", "--no-lock", "--json", "--tag \(ResticService.planTag(plan.id))"] {
            #expect(start.contains(flag), "start line: \(start)")
        }
        #expect(!start.contains("--prune"), "start line: \(start)")
    }

    @Test("the reads a click or a refresh runs take no repository lock")
    func clickAndRefreshReadsRunLockFree() async throws {
        let fixture = try makeFixture(mode: "default")
        defer { cleanUp(fixture.root) }

        _ = try await fixture.service.find(fixture.context, pattern: "/src/a.txt", ignoreCase: false, snapshotIDs: ["feedface"])
        _ = try await fixture.service.listDirectory(fixture.context, snapshotID: "feedface", path: "/src")
        _ = try await fixture.service.snapshots(fixture.context, planID: nil, timeout: nil)

        let trace = try String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
        let starts = trace.split(separator: "\n").map(String.init).filter { $0.hasPrefix("start args=[") }
        // Locked, each paid restic's 200 ms wait after writing its lock, failed
        // with exit 11 under retention's exclusive lock, and made a forget
        // starting meanwhile fail the same way (all probed on restic 0.19.1).
        for command in ["find", "ls", "snapshots"] {
            let start = try #require(starts.first { $0.hasPrefix("start args=[\(command) ") }, "trace: \(trace)")
            #expect(start.contains("--no-lock"), "start line: \(start)")
        }
    }

    @Test("a check exit 1 without an error count is still a failure, not a clean bill")
    func checkExitOneWithoutErrorsFailsTheCommand() async throws {
        let fixture = try makeFixture(mode: "checkbroken")
        defer { cleanUp(fixture.root) }

        // An exit 1 the app cannot read a verdict from must not pass for
        // "checked, nothing found": the run record would lie about the one
        // thing a check exists to report.
        do {
            _ = try await fixture.service.check(fixture.context, readDataSubsetPercent: nil)
            Issue.record("expected exit 1 without a summary to fail the check")
        } catch let error as ResticError {
            guard case let .commandFailed(code, _, _) = error, code == 1 else {
                Issue.record("expected commandFailed(1), got \(error)")
                return
            }
        }
    }

    // MARK: - Index streams

    @Test("a full ls with a node line that did not decode delivers every node that did, then throws malformedOutput")
    func walkSnapshotThrowsAfterAShortStream() async throws {
        let fixture = try makeFixture(mode: "lsmalformed")
        defer { cleanUp(fixture.root) }

        let collector = NodeCollector()
        await #expect(throws: ResticError.malformedOutput(command: "ls", detail: "1 node line did not decode")) {
            try await fixture.service.walkSnapshot(fixture.context, snapshotID: "feedface00000000") { node in
                collector.append(node)
            }
        }
        // Delivered before the verdict, after.txt included: a lost line does
        // not end the stream, and the verdict comes once it has — the caller
        // decides what a short stream is worth. restic's header line is its
        // snapshot, not a node, and does not count as lost.
        #expect(collector.content == ["/src": true, "/src/notes.txt": false, "/src/after.txt": false])
    }

    /// Time-limited like the coordinator suites: a full read that failed
    /// and stopped landing in the pass's skip set would make the pass spawn
    /// the stub's `ls` forever.
    @Test(
        "a full read whose ls lost a node line indexes nothing of it: the snapshot stays pending, and read whole it lands",
        .timeLimit(.minutes(1))
    )
    func backfillLeavesAShortListingPending() async throws {
        let fixture = try makeFixture(mode: "lsmalformed")
        defer { cleanUp(fixture.root) }
        let coordinator = IndexCoordinator(directory: fixture.root.appendingPathComponent("config"))
        let repositoryID = fixture.context.repository.id
        let snapshotID = "feedface00000000"
        let listing = [try IndexTestData.snapshot(snapshotID, micros: 1_000_000, tags: [IndexTestData.planA], paths: ["/src"])]
        await coordinator.reconcile(repositoryID: repositoryID, snapshots: listing, generation: 1)

        await coordinator.runBackfill(repositoryID: repositoryID, service: fixture.service, context: fixture.context)
        // The full route ran once and was turned down. /src and notes.txt
        // streamed before the lost line and after.txt after it, and none of
        // them is claimed: a stream known to be short never reaches its
        // final, which would close the runs of every path it failed to name.
        let trace = try String(contentsOf: fixture.root.appendingPathComponent("stub-trace.log"), encoding: .utf8)
        #expect(trace.components(separatedBy: "\n").filter { $0.contains("args=[ls ") }.count == 1)
        let report = await coordinator.lastBackfillReport(repositoryID: repositoryID)
        #expect(report?.fullFailed == 1)
        #expect(report?.fulls == 0)
        #expect(report?.markedUnreadable == 0)
        #expect(try await coordinator.versions(ofPath: "/src/notes.txt", repositoryID: repositoryID).isEmpty)
        #expect(try await !coordinator.isComplete(repositoryID: repositoryID))
        // Pending, not set aside: the next pass reads it again, in full.
        let next = try await coordinator.read(repositoryID) { try $0.nextStep() }
        #expect(next == .full(snapshotID: snapshotID))

        // The same snapshot, its listing whole, lands on the next pass: what
        // turned the first read down was the lost line — not the stub, the
        // paths or the store.
        var whole = fixture.context
        whole.repository.extraEnvironment["SWIFTRESTIC_STUB"] = "browserows"
        await coordinator.runBackfill(repositoryID: repositoryID, service: fixture.service, context: whole)
        #expect(await coordinator.lastBackfillReport(repositoryID: repositoryID)?.fulls == 1)
        #expect(try await coordinator.versions(ofPath: "/src/notes.txt", repositoryID: repositoryID).map(\.id) == [snapshotID])
        #expect(try await coordinator.isComplete(repositoryID: repositoryID))
        let violations = try await coordinator.read(repositoryID) { try $0.invariantViolations() }
        #expect(violations.isEmpty)
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
