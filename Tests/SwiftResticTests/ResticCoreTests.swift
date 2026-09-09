import Foundation
import Testing

@Suite("restic error messages")
struct ResticErrorTests {
    /// The exit codes restic documents, per `man restic` — the mapping the error
    /// banners are built on.
    @Test("every documented exit code maps to an explanation")
    func knownExitCodes() {
        for code: Int32 in [1, 2, 3, 10, 11, 12, 130] {
            #expect(ResticError.knownExitCodeDescription(code) != nil, "code \(code) should be documented")
        }
        for code: Int32 in [0, 4, 42, 99, 127] {
            #expect(ResticError.knownExitCodeDescription(code) == nil, "code \(code) should stay unmapped")
        }
    }

    @Test("a known code prefixes restic's message; an unknown code gets the raw text")
    func commandFailedDescriptions() {
        // The wrong-password failure carries its fix, plus restic's words for
        // the discriminating detail — Retry can never succeed here.
        let wrongPassword = ResticError.commandFailed(
            exitCode: 12,
            message: "Fatal: wrong password",
            command: "restic snapshots"
        ).errorDescription ?? ""
        #expect(wrongPassword.contains("doesn't open this repository"))
        #expect(wrongPassword.contains("check it in the repository settings"))
        #expect(wrongPassword.contains("Fatal: wrong password"))
        #expect(
            ResticError.commandFailed(exitCode: 12, message: "", command: "x")
                .errorDescription?.contains("check it in the repository settings") == true
        )

        // Other known codes: explanation and restic's words, both there.
        let known = ResticError.commandFailed(
            exitCode: 11,
            message: "Fatal: repository is locked",
            command: "restic prune"
        ).errorDescription ?? ""
        #expect(known.contains("already locked"))
        #expect(known.contains("Fatal: repository is locked"))

        // Known code, no JSON message: the explanation is all there is.
        let bare = ResticError.commandFailed(
            exitCode: 10,
            message: "",
            command: "restic snapshots"
        ).errorDescription ?? ""
        #expect(bare.contains("does not exist"))

        // Unknown code: restic's words verbatim, no invented explanation.
        #expect(
            ResticError.commandFailed(exitCode: 99, message: "disk on fire", command: "x")
                .errorDescription == "disk on fire"
        )
        #expect(
            ResticError.commandFailed(exitCode: 99, message: "", command: "x")
                .errorDescription == "restic exited with code 99."
        )
    }

    @Test("the other failure shapes name what the user can do about them")
    func otherDescriptions() {
        #expect(
            ResticError.passwordMissing(repositoryName: "NAS").errorDescription?.contains("NAS") == true
        )
        #expect(
            ResticError.timedOut(seconds: 90, command: "restic backup").errorDescription?
                .contains("90") == true
        )
        let notFound = ResticError.binaryNotFound(searched: ["/opt/homebrew/bin", "/usr/bin"])
        #expect(notFound.errorDescription?.contains("/opt/homebrew/bin, /usr/bin") == true)
        #expect(notFound.errorDescription?.contains("brew install restic") == true)
        #expect(
            ResticError.binaryNotExecutable(path: "/opt/restic").errorDescription?
                .contains("/opt/restic") == true
        )
        #expect(ResticError.cancelled.errorDescription != nil)
        #expect(ResticError.repositoryMissing.errorDescription != nil)
    }

    @Test("exit code 3 is a partial success, not a failure")
    func partialSuccessCode() {
        // `backup` finishing with unreadable files must still count as having
        // backed the rest up.
        #expect(ResticError.backupPartialSuccessCode == 3)
    }
}

@Suite("restic binary location")
struct ResticBinaryTests {
    @Test("an explicit override wins over the search paths")
    func overrideWins() throws {
        // /bin/echo exists and is executable on every Mac; the point is that the
        // configured path is honoured verbatim, not that it is restic.
        let located = try ResticBinary.locate(userOverride: "/bin/echo")
        #expect(located.url.path == "/bin/echo")
    }

    @Test("an override that is not an executable file is refused")
    func brokenOverrideIsRefused() {
        do {
            _ = try ResticBinary.locate(userOverride: "/nonexistent-restic-binary")
            Issue.record("a missing override must not be accepted")
        } catch let ResticError.binaryNotExecutable(path) {
            #expect(path == "/nonexistent-restic-binary")
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // A directory has the execute bit (0755), so the permission check alone
        // would accept it — and the run would only fail later, at spawn time.
        do {
            _ = try ResticBinary.locate(userOverride: "/tmp")
            Issue.record("a directory must not be accepted as the restic binary")
        } catch let ResticError.binaryNotExecutable(path) {
            #expect(path == "/tmp")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a blank override means 'no override', not a broken path")
    func blankOverrideIsIgnored() {
        // Blank must behave exactly like nil: the same binary where one exists,
        // the same not-found error where none does. A blank override handled as
        // a path would fail with binaryNotExecutable instead of ever reaching
        // the search, so on a bare box both sides are concrete errors — this
        // cannot pass vacuously the way comparing two `try?` results would.
        let withoutOverride = Result { try ResticBinary.locate(userOverride: nil) }
        let withBlankOverride = Result { try ResticBinary.locate(userOverride: "   ") }
        switch (withoutOverride, withBlankOverride) {
        case (.success(let found), .success(let blank)):
            #expect(found.url == blank.url)
        case (.failure(let bare as ResticError), .failure(let blank as ResticError)):
            #expect(bare == blank, "blank override changed the failure: \(bare) vs \(blank)")
            guard case .binaryNotFound = blank else {
                Issue.record("blank override failed with \(blank), not binaryNotFound")
                return
            }
        default:
            Issue.record("a blank override changed the locate outcome: \(withoutOverride) vs \(withBlankOverride)")
        }
    }

    @Test("helper lookup falls back to the inherited PATH")
    func helperLookup() {
        // `sh` lives in /bin, which the hard-coded candidate list never covers:
        // only the PATH fallback can find it. Without the fallback, an rclone
        // repository would fail with an opaque "command not found" in restic's
        // stderr instead of a named missing binary.
        let sh = ResticBinary.locateHelper(named: "sh")
        #expect(sh?.path.hasSuffix("/sh") == true)
        #expect(ResticBinary.locateHelper(named: "definitely-not-a-real-helper") == nil)
    }
}

@Suite("Output tailing")
struct TailTests {
    @Test("short output is kept whole, minus surrounding whitespace")
    func shortText() {
        #expect(ResticRunner.tail(of: "  hello \n", limit: 100) == "hello")
        #expect(ResticRunner.tail(of: "", limit: 10) == "")
    }

    @Test("output past the limit keeps the tail, where the error lives")
    func longText() {
        // Go prints the fatal error last; keeping the head would drop exactly
        // the part that explains the failure.
        let text = "progress lines...\nprogress lines...\nFatal: repository is locked"
        let tailed = ResticRunner.tail(of: text, limit: 30)
        #expect(tailed.hasSuffix("Fatal: repository is locked"))
        #expect(!tailed.contains("progress"))
        #expect(tailed.count <= 30)
    }

    @Test("output exactly at the limit is not truncated")
    func exactLimit() {
        let text = "0123456789"
        #expect(ResticRunner.tail(of: text, limit: 10) == text)
    }
}

@Suite("Raw line streaming")
struct RawLineStreamingTests {
    /// onRawLine fires from two stream-reading queues, so the test's collector
    /// needs its own lock.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test("every raw line of stdout and stderr arrives, including non-JSON ones")
    func rawLinesArriveFromBothStreams() async throws {
        // /bin/sh with builtins only: no restic needed to exercise the pipes.
        // The JSON-looking line must pass through undecoded-decision intact —
        // raw delivery is independent of whether the line decodes.
        let runner = ResticRunner()
        let collector = LineCollector()
        let result = try await runner.run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: [
                "-c", "printf 'packing 12 packs\\n'; printf 'not json either\\n' >&2; echo '{\"message_type\":\"summary\"}'; printf 'done\\n' >&2",
            ]),
            onRawLine: { collector.append($0) }
        )

        #expect(result.exitCode == 0)
        // stdout and stderr interleave, so compare as a set.
        #expect(Set(collector.lines) == ["packing 12 packs", "not json either", "{\"message_type\":\"summary\"}", "done"])
        #expect(collector.lines.count == 4)
        // The decoded path is unaffected: the summary line still arrives as a message.
        #expect(result.summary != nil)
    }

    @Test("no onRawLine callback means the default streaming path is untouched")
    func nilCallbackIsFine() async throws {
        let runner = ResticRunner()
        let result = try await runner.run(
            binary: URL(fileURLWithPath: "/bin/echo"),
            invocation: ResticInvocation(arguments: ["hello"])
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }
}

@Suite("Password precedence")
struct PasswordPrecedenceTests {
    private func context(extra: [String: String]) -> RepositoryContext {
        var repository = Repository()
        repository.name = "Repo"
        repository.kind = .local
        repository.localPath = "/Volumes/Backup"
        repository.extraEnvironment = extra
        return RepositoryContext(repository: repository, password: "stored-password")
    }

    @Test("the stored repository and password win over extra environment entries")
    func storedValuesWin() {
        let env = context(extra: [
            "RESTIC_PASSWORD": "hostile-password",
            "RESTIC_REPOSITORY": "/somewhere/else",
            // restic ranks these above RESTIC_PASSWORD itself, so they must be
            // kept away from it too.
            "RESTIC_PASSWORD_COMMAND": "echo hostile",
            "RESTIC_PASSWORD_FILE": "/hostile/file",
            "TAG": "innocent",
        ]).environment
        #expect(env["RESTIC_PASSWORD"] == "stored-password")
        #expect(env["RESTIC_REPOSITORY"] == "/Volumes/Backup")
        #expect(env["RESTIC_PASSWORD_COMMAND"] == nil)
        #expect(env["RESTIC_PASSWORD_FILE"] == nil)
        // A non-reserved entry passes through untouched.
        #expect(env["TAG"] == "innocent")
    }

    @Test("an empty repository string leaves the extra environment's location standing")
    func incompleteRepositoryKeepsExtraLocation() {
        // The console can reach a repository the plan editor would call
        // incomplete; clobbering RESTIC_REPOSITORY with "" would break that.
        var repository = Repository()
        repository.name = "Repo"
        repository.kind = .local
        repository.localPath = ""
        repository.extraEnvironment = ["RESTIC_REPOSITORY": "sftp:nas.local:/volume1/restic"]
        let context = RepositoryContext(repository: repository, password: "stored-password")

        #expect(context.environment["RESTIC_REPOSITORY"] == "sftp:nas.local:/volume1/restic")

        // A repository with a real location still wins over the extra entry.
        repository.localPath = "/Volumes/Backup"
        #expect(
            RepositoryContext(repository: repository, password: "stored-password")
                .environment["RESTIC_REPOSITORY"] == "/Volumes/Backup"
        )
    }

    @Test("conflicting extra entries are named so the editor can warn about them")
    func conflictsAreReported() {
        let overridden = context(extra: [
            "RESTIC_PASSWORD": "x",
            "RESTIC_PASSWORD_COMMAND": "y",
            "AWS_ACCESS_KEY_ID": "z",
        ]).overriddenExtraEnvironmentKeys
        #expect(overridden == ["RESTIC_PASSWORD", "RESTIC_PASSWORD_COMMAND"])

        #expect(context(extra: ["AWS_ACCESS_KEY_ID": "y"]).overriddenExtraEnvironmentKeys.isEmpty)
    }
}
