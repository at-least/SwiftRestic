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
            message: "Fatal: wrong password"
        ).errorDescription ?? ""
        #expect(wrongPassword.contains("doesn’t open this repository"))
        #expect(wrongPassword.contains("check it in the repository editor"))
        #expect(wrongPassword.contains("Fatal: wrong password"))
        #expect(
            ResticError.commandFailed(exitCode: 12, message: "")
                .errorDescription?.contains("check it in the repository editor") == true
        )

        // A missing repository and a lock carry their fix the same way: the
        // banner and the notification repeat this message.
        #expect(ResticError.commandFailed(
            exitCode: 10,
            message: "Fatal: repository does not exist: unable to open config file: stat /Volumes/A/config: no such file or directory"
        ).errorDescription == "No repository is at its location — put it back, or add it where it is now as a new repository. restic reported: Fatal: repository does not exist: unable to open config file: stat /Volumes/A/config: no such file or directory")
        #expect(ResticError.commandFailed(exitCode: 10, message: "").errorDescription
            == "No repository is at its location — put it back, or add it where it is now as a new repository.")
        #expect(ResticError.commandFailed(
            exitCode: 11,
            message: "Fatal: repository is locked"
        ).errorDescription == "The repository is locked — if no other Mac is using it, unlock it. restic reported: Fatal: repository is locked")

        let known = ResticError.commandFailed(
            exitCode: 3,
            message: "warning: at least one source file could not be read"
        ).errorDescription ?? ""
        #expect(known.contains("some data could not be read"))
        #expect(known.contains("warning: at least one source file could not be read"))

        let bare = ResticError.commandFailed(
            exitCode: 130,
            message: ""
        ).errorDescription ?? ""
        #expect(bare == "restic was interrupted")

        #expect(
            ResticError.commandFailed(exitCode: 99, message: "disk on fire")
                .errorDescription == "disk on fire"
        )
        #expect(
            ResticError.commandFailed(exitCode: 99, message: "")
                .errorDescription == "restic exited with code 99."
        )
    }

    @Test("an SFTP host-key refusal names its fix, from the line ssh printed beside restic's fatal one")
    func sshHostKey() {
        // restic 0.19.1, `cat config --json` over sftp with no terminal, as
        // the app runs it: ssh's verdict arrives as plain stderr lines
        // restic prefixes "subprocess ssh: ", and the exit_error JSON does
        // not carry it.
        let fatal = "Fatal: unable to open repository at sftp:nas:/srv/restic: unable to start the sftp session, "
            + "error: error receiving version packet from server: server unexpectedly closed connection: unexpected EOF"
        func result(_ sshLines: [String]) -> ResticRunResult {
            let json = #"{"message_type":"exit_error","code":1,"message":"\#(fatal)"}"#
            return ResticRunResult(
                exitCode: 1,
                messages: [.exitError(ResticExitError(code: 1, message: fatal))],
                stdout: "",
                stderr: (sshLines.map { "subprocess ssh: \($0)" } + [json]).joined(separator: "\n") + "\n"
            )
        }

        let unknown = result(["Host key verification failed."])
        #expect(unknown.failureMessage == fatal + "\nsubprocess ssh: Host key verification failed.")
        // A server whose key changed: ssh's banner runs to a dozen lines;
        // its verdict is the last ones.
        let changed = result([
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@",
            "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @",
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@",
            "IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!",
            "Offending ED25519 key in /Users/me/.ssh/known_hosts:1",
            "Host key for nas has changed and you have requested strict checking.",
            "Host key verification failed.",
        ])
        #expect(changed.failureMessage == fatal
            + "\nsubprocess ssh: Offending ED25519 key in /Users/me/.ssh/known_hosts:1"
            + "\nsubprocess ssh: Host key for nas has changed and you have requested strict checking."
            + "\nsubprocess ssh: Host key verification failed.")
        #expect(result([]).failureMessage == fatal)

        let unknownText = ResticError.commandFailed(exitCode: 1, message: unknown.failureMessage).errorDescription ?? ""
        #expect(unknownText.hasPrefix("SSH does not know this server’s key yet"))
        #expect(unknownText.contains("Connect to it once in Terminal with ssh"))
        #expect(unknownText.hasSuffix("restic reported: \(fatal)"))
        let changedText = ResticError.commandFailed(exitCode: 1, message: changed.failureMessage).errorDescription ?? ""
        #expect(changedText.hasPrefix("This server’s SSH key has changed since this Mac last connected"))
        #expect(changedText.contains("ssh-keygen -R"))
        #expect(ResticError.commandFailed(exitCode: 1, message: fatal).errorDescription == fatal)
    }

    @Test("an rclone repository's failure leads with what rclone said, or says plainly what restic could not get from it")
    func rcloneWords() {
        // restic 0.19.1 with rclone 1.75.2: rclone's own
        // verdict reaches stderr as "rclone: <date> <time> CRITICAL: …", and
        // the exit_error JSON carries only "error talking HTTP to rclone".
        let fatal = "Fatal: unable to open repository at rclone:sftp:backups/restic: error talking HTTP to rclone: exit status 1"
        func result(_ rcloneLines: [String]) -> ResticRunResult {
            let json = #"{"message_type":"exit_error","code":1,"message":"\#(fatal)"}"#
            return ResticRunResult(
                exitCode: 1,
                messages: [.exitError(ResticExitError(code: 1, message: fatal))],
                stdout: "",
                stderr: (rcloneLines.map { "rclone: \($0)" } + [json]).joined(separator: "\n") + "\n"
            )
        }
        let refused = result([
            "2026/10/16 02:54:34 NOTICE: sftp: No host key validation is being performed. Set known_hosts_file (to \"none\" to silence this notice)",
            "2026/10/16 02:54:34 CRITICAL: Failed to create file system for \"sftp:backups/restic\": NewFs: couldn't connect SSH: ssh: handshake failed: ssh: unexpected message type 51 (expected 60)",
        ])
        // Its errors only, without the date and the level; a NOTICE is no verdict.
        #expect(refused.failureMessage == fatal
            + "\nrclone: Failed to create file system for \"sftp:backups/restic\": NewFs: couldn't connect SSH: ssh: handshake failed: ssh: unexpected message type 51 (expected 60)")
        #expect(result(["2026/10/16 02:55:12 ERROR : sftp: can't stat: permission denied"]).failureMessage
            == fatal + "\nrclone: sftp: can't stat: permission denied")
        #expect(result(["2026/10/16 02:54:34 NOTICE: sftp: No host key validation is being performed."]).failureMessage == fatal)

        // rclone's verdict leads — the first sentence, which captions show
        // — and restic's keeps the detail.
        #expect(ResticError.commandFailed(exitCode: 1, message: refused.failureMessage).errorDescription
            == "rclone: Failed to create file system for \"sftp:backups/restic\": NewFs: couldn't connect SSH: ssh: handshake failed: "
            + "ssh: unexpected message type 51 (expected 60). restic reported: \(fatal)")
        let typo = result(["2026/10/16 02:55:12 CRITICAL: Failed to create file system for \"sftpx:backups/restic\": didn't find section in config file (\"sftpx\")"])
        let typoText = ResticError.commandFailed(exitCode: 1, message: typo.failureMessage).errorDescription ?? ""
        #expect(Format.firstSentence(typoText)
            == "rclone: Failed to create file system for \"sftpx:backups/restic\": didn't find section in config file (\"sftpx\")")

        // A remote that never answered: restic gave up waiting on rclone
        // after a minute, before rclone said anything.
        let waited = "Fatal: unable to open repository at rclone:sftp:backups/restic: error talking HTTP to rclone: "
            + "Get \"http://localhost/file-6043080322775398060\": context deadline exceeded (Client.Timeout exceeded while awaiting headers)"
        #expect(ResticError.commandFailed(exitCode: 1, message: waited).errorDescription
            == "rclone did not answer within a minute — its remote may be unreachable. restic reported: \(waited)")

        let missing = "Fatal: unable to open repository at rclone:sftp:backups/restic: exec: \"rclone\": executable file not found in $PATH"
        #expect(ResticError.commandFailed(exitCode: 1, message: missing).errorDescription == ResticError.rcloneMissing)
        #expect(ResticError.rcloneMissing == "rclone is not installed. Install it with brew install rclone.")

        #expect(ResticError.commandFailed(exitCode: 1, message: fatal).errorDescription == fatal)
    }

    @Test("restic's Go stack trace never reaches a message; a second line of restic's own stays")
    func goStackTraceIsCut() {
        // restic 0.19.1's forget on an append-only server, as its exit_error
        // carried it: an error with no message of its own is
        // formatted with %+v, which appends the stack it was made on.
        let traced = "failed to remove one or more snapshots\nmain.init\n\tgithub.com/restic/restic/cmd/restic/cmd_forget.go:67\n"
            + "runtime.doInit1\n\truntime/proc.go:8103\nruntime.doInit\n\truntime/proc.go:8070\nruntime.main\n\truntime/proc.go:258\n"
            + "runtime.goexit\n\truntime/asm_arm64.s:1447"
        func result(_ message: String) -> ResticRunResult {
            ResticRunResult(exitCode: 3, messages: [.exitError(ResticExitError(code: 3, message: message))], stdout: "", stderr: "")
        }
        #expect(result(traced).failureMessage == "failed to remove one or more snapshots")
        // A server that refused connections, the same day: the line after
        // restic's sentence names the repository, and stays.
        let located = "Fatal: unable to open config file: Head \"http://:***@127.0.0.1:18000/app/config\": dial tcp 127.0.0.1:18000: "
            + "connect: connection refused\nrest:http://127.0.0.1:18000/app/"
        #expect(result(located).failureMessage == located)
    }

    @Test("a forget the repository refused says so, and how many went")
    func refusedSnapshotsWords() {
        #expect(ResticError.snapshotsNotRemoved(removed: 0, refused: 1, reason: "403 Forbidden").errorDescription
            == "The repository refused to delete 1 backup (403 Forbidden) — it may be append-only or locked. "
            + "Thin it where deletions are allowed, or turn retention off.")
        #expect(ResticError.snapshotsNotRemoved(removed: 2, refused: 1, reason: "operation not permitted").errorDescription
            == "The repository refused to delete 1 of the 3 backups retention chose (operation not permitted); the other 2 were removed. "
            + "It may be append-only or locked — thin it where deletions are allowed, or turn retention off.")
    }

    @Test("the other failure shapes name what the user can do about them")
    func otherDescriptions() {
        #expect(
            ResticError.passwordMissing(repositoryName: "NAS").errorDescription?.contains("NAS") == true
        )
        #expect(
            ResticError.timedOut(seconds: 90).errorDescription?
                .contains("1m 30s") == true
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

    @Test("an override typed with a tilde is read under the home folder, as every other typed path is")
    func overrideExpandsTilde() {
        // URL(fileURLWithPath:) expands the tilde itself; pinned, since the
        // override is the one typed path that does not go through
        // ResticService.expandTilde.
        do {
            _ = try ResticBinary.locate(userOverride: "~/nonexistent-restic-binary")
            Issue.record("a missing override must not be accepted")
        } catch let ResticError.binaryNotFound(searched) {
            #expect(searched == [NSHomeDirectory() + "/nonexistent-restic-binary"])
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an override that is not an executable file is refused")
    func brokenOverrideIsRefused() {
        // A missing file is a different sentence than an unexecutable one:
        // "not executable" would send someone hunting through permissions
        // for what is really a typo.
        do {
            _ = try ResticBinary.locate(userOverride: "/nonexistent-restic-binary")
            Issue.record("a missing override must not be accepted")
        } catch let ResticError.binaryNotFound(searched) {
            #expect(searched == ["/nonexistent-restic-binary"])
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

    @Test("a tilde in the override is expanded, not taken literally")
    func tildeOverrideIsExpanded() {
        // Pinning, not fixing: URL(fileURLWithPath:) itself expands "~" on
        // this Foundation, so a home-relative override resolves. If a
        // Foundation update ever stops expanding, this fails before anyone
        // files the bug.
        do {
            _ = try ResticBinary.locate(userOverride: "~/definitely-not-here")
            Issue.record("a missing override must not be accepted")
        } catch let ResticError.binaryNotFound(searched) {
            #expect(searched.count == 1)
            #expect(!searched[0].hasPrefix("~"), "searched literally: \(searched)")
            #expect(searched[0].hasPrefix(NSHomeDirectory()), "not home-relative: \(searched)")
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

    @Test("every folder a helper is looked for in is on restic's PATH")
    func helperFoldersAreOnResticsPath() throws {
        // The editor accepts rclone where locateHelper finds it; restic runs
        // it from its PATH, so a folder only the lookup knows would pass the
        // editor and fail every run with "rclone is not installed".
        let path = try #require(ResticRunner.baseEnvironment()["PATH"]).split(separator: ":").map(String.init)
        for directory in ResticBinary.helperDirectories {
            #expect(path.contains(directory), "\(directory) missing from \(path)")
        }
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
        // The JSON-looking line must pass through intact — raw delivery is
        // independent of whether the line decodes.
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

/// The stdout text the runner keeps on the result: capped when
/// `retainFullOutput` is not set — the unbounded streams (backup, restore,
/// the walks) ride the message callbacks instead — whole when it is. stderr
/// keeps its first 64 KB either way.
@Suite("Retained output cap")
struct RetainedOutputCapTests {
    /// 80 lines of 2048 bytes: about 164 KB printed, well past the runner's
    /// 64 KB cap, with no restic and no bulk fixture.
    private static let filler = "awk 'BEGIN{for(i=0;i<80;i++)printf \"%2048s\\n\", \"\"}' | tr ' ' 'x'"

    @Test("an unbounded stream is retained capped, and retainFullOutput keeps it whole")
    func retainedTextIsCapped() async throws {
        let arguments = ["-c", Self.filler]
        let capped = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: arguments)
        )
        let cappedBytes = capped.stdout.utf8.count
        #expect(cappedBytes > 60_000 && cappedBytes < 100_000, "retained \(cappedBytes) bytes")

        let whole = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: arguments, retainFullOutput: true)
        )
        #expect(whole.stdout.utf8.count > 160_000, "retained \(whole.stdout.utf8.count) bytes")
    }
}

@Suite("Password precedence")
struct PasswordPrecedenceTests {
    private func context(extra: [String: String]) -> RepositoryContext {
        var repository = Repository()
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
            // -r and --repository-file are mutually exclusive to restic, so
            // this one fails every command; RESTIC_HOST would record another
            // Mac's name on every backup.
            "RESTIC_REPOSITORY_FILE": "/hostile/repository-file",
            "RESTIC_HOST": "elsewhere",
            "TAG": "innocent",
        ]).environment
        #expect(env["RESTIC_PASSWORD"] == "stored-password")
        #expect(env["RESTIC_REPOSITORY"] == "/Volumes/Backup")
        #expect(env["RESTIC_PASSWORD_COMMAND"] == nil)
        #expect(env["RESTIC_PASSWORD_FILE"] == nil)
        #expect(env["RESTIC_REPOSITORY_FILE"] == nil)
        #expect(env["RESTIC_HOST"] == nil)
        #expect(env["TAG"] == "innocent")
    }

    @Test("an empty repository string leaves the extra environment's location standing")
    func incompleteRepositoryKeepsExtraLocation() {
        // The console can reach a repository the plan editor would call
        // incomplete; clobbering RESTIC_REPOSITORY with "" would break that.
        var repository = Repository()
        repository.kind = .local
        repository.localPath = ""
        repository.extraEnvironment = ["RESTIC_REPOSITORY": "sftp:nas.local:/volume1/restic"]
        let context = RepositoryContext(repository: repository, password: "stored-password")

        #expect(context.environment["RESTIC_REPOSITORY"] == "sftp:nas.local:/volume1/restic")

        repository.localPath = "/Volumes/Backup"
        #expect(
            RepositoryContext(repository: repository, password: "stored-password")
                .environment["RESTIC_REPOSITORY"] == "/Volumes/Backup"
        )
    }

}

@Suite("Rate limits")
struct RateLimitTests {
    @Test("a repository's own rate limits go on every command against it; none add no flag")
    func repositoryLimits() {
        var repository = Repository()
        repository.kind = .b2
        #expect(RepositoryContext(repository: repository, password: "p").globalArguments.isEmpty)

        repository.uploadLimitKiBps = 512
        repository.downloadLimitKiBps = 2048
        #expect(
            RepositoryContext(repository: repository, password: "p").globalArguments
                == ["--limit-upload", "512", "--limit-download", "2048"]
        )
    }
}

/// The commit a single file's restore ends with: restic restores the file
/// into a hidden folder beside its landing, and this moves it into place.
@Suite("Staged file commit")
struct StagedFileCommitTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticStagedFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("a volume that refuses RENAME_EXCL still gets its file, and still keeps a taken name")
    func noReplaceCommitWithoutExclusiveRename() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // exFAT answers ENOTSUP to RENAME_EXCL even for a free name; the
        // injected rename returns just that.
        let refusesFlag: (String, String) -> Int32 = { _, _ in ENOTSUP }

        let free = directory.appendingPathComponent("a.txt")
        let freeStaging = directory.appendingPathComponent(".a.txt.1.partial")
        try Data("new".utf8).write(to: freeStaging)
        let landed = try ResticService.commitStagedFile(
            freeStaging, to: free, replacingExisting: false, renameExclusive: refusesFlag
        )
        #expect(landed == .committed)
        #expect(try String(contentsOf: free, encoding: .utf8) == "new")

        let taken = directory.appendingPathComponent("b.txt")
        try Data("mine".utf8).write(to: taken)
        let takenStaging = directory.appendingPathComponent(".b.txt.1.partial")
        try Data("new".utf8).write(to: takenStaging)
        let kept = try ResticService.commitStagedFile(
            takenStaging, to: taken, replacingExisting: false, renameExclusive: refusesFlag
        )
        #expect(kept == .keptExisting)
        #expect(try String(contentsOf: taken, encoding: .utf8) == "mine", "the fallback replaced a taken name")
    }

    @Test("a replacing commit over a standing folder is refused, leaving the folder and the staged file untouched")
    func replaceCommitOverAFolderIsRefused() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // What a folder standing at the landing makes of rename(2): the
        // single-file restore's wasted-transfer failure.
        let target = directory.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: target.appendingPathComponent("inside.txt"))
        let staging = directory.appendingPathComponent(".a.txt.1.partial")
        try Data("new".utf8).write(to: staging)

        do {
            _ = try ResticService.commitStagedFile(staging, to: target, replacingExisting: true)
            Issue.record("expected the rename over a folder to fail")
        } catch let ResticError.stagedFileMoveFailed(path, reason) {
            #expect(path == target.path)
            #expect(!reason.isEmpty)
        }
        #expect(try String(contentsOf: target.appendingPathComponent("inside.txt"), encoding: .utf8) == "kept")
        #expect(try String(contentsOf: staging, encoding: .utf8) == "new", "the staged file did not survive for the caller's cleanup")
    }

    @Test("a replacing commit renames the staged file over the target file")
    func replaceCommitReplacesTheTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("a.txt")
        try Data("mine".utf8).write(to: target)
        let staging = directory.appendingPathComponent(".a.txt.1.partial")
        try Data("new".utf8).write(to: staging)

        let landed = try ResticService.commitStagedFile(staging, to: target, replacingExisting: true)

        #expect(landed == .committed)
        #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    }
}

/// What a backup's unreadable-item lines are built from: restic's error
/// events plus its plain-text skipped-source warnings, one line per item.
/// The input lines follow restic 0.19.1's own output.
@Suite("Unreadable items")
struct UnreadableItemsTests {
    private func errors(_ lines: [String]) throws -> [ResticErrorMessage] {
        try lines.map { line in
            guard case let .error(error) = try #require(ResticMessageDecoder.decode(line: line)) else {
                throw ResticError.malformedOutput(detail: "not an error event: \(line)")
            }
            return error
        }
    }

    @Test("a folder reported during scan and again during archival is one item")
    func unreadableItemsDedupeScanAndArchival() throws {
        // An unreadable file and two unreadable folders under an absolute
        // source: five events, three items. restic names each folder once
        // `during: scan` and once `during: archival`, with the same item.
        let events = try errors([
            #"{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /src/deep: permission denied"},"during":"scan","item":"/src/deep"}"#,
            #"{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /src/lockeddir: permission denied"},"during":"scan","item":"/src/lockeddir"}"#,
            #"{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /src/deep: permission denied"},"during":"archival","item":"/src/deep"}"#,
            #"{"message_type":"error","error":{"message":"open /src/locked.pdf: permission denied"},"during":"archival","item":"/src/locked.pdf"}"#,
            #"{"message_type":"error","error":{"message":"openfile for readdirnames failed: open /src/lockeddir: permission denied"},"during":"archival","item":"/src/lockeddir"}"#,
        ])
        #expect(ResticService.unreadableItems(errors: events, stderr: "") == [
            "/src/deep: openfile for readdirnames failed: open /src/deep: permission denied",
            "/src/lockeddir: openfile for readdirnames failed: open /src/lockeddir: permission denied",
            "/src/locked.pdf: open /src/locked.pdf: permission denied",
        ])

        // An event without an item is keyed by its message: the same words
        // twice are one line, different words stay apart.
        let itemless = try errors([
            #"{"message_type":"error","error":{"message":"walk failed"}}"#,
            #"{"message_type":"error","error":{"message":"walk failed"}}"#,
            #"{"message_type":"error","error":{"message":"another failure"}}"#,
        ])
        #expect(ResticService.unreadableItems(errors: itemless, stderr: "") == ["walk failed", "another failure"])
    }

    @Test("a source restic skipped is named from its plain-text warning, ahead of the error events")
    func unreadableItemsNameSkippedSources() throws {
        // restic reports a missing or inaccessible source only as text on
        // stderr, never as an error event; the exclude warning shares the
        // ", skipping" tail but is not about an unread item.
        let stderr = """
        /x/does-not-exist does not exist, skipping
        /y cannot be accessed, skipping
        pattern "*.tmp" does not match any files, skipping
        {"message_type":"error","error":{"message":"open /src/a.pdf: permission denied"},"during":"archival","item":"/src/a.pdf"}
        {"message_type":"exit_error","code":3,"message":"Warning: at least one source file could not be read"}

        """
        let events = try errors([
            #"{"message_type":"error","error":{"message":"open /src/a.pdf: permission denied"},"during":"archival","item":"/src/a.pdf"}"#,
        ])
        #expect(ResticService.unreadableItems(errors: events, stderr: stderr) == [
            "/x/does-not-exist does not exist, skipping",
            "/y cannot be accessed, skipping",
            "/src/a.pdf: open /src/a.pdf: permission denied",
        ])
        // A source ending in a Prepend character joins the space after it
        // into one Character, so a Character suffix test misses the skip
        // line: matched by bytes, and the path cut by bytes.
        let prepend = "/Volumes/Data/new\u{0600}"
        #expect(ResticService.unreadableItems(errors: [], stderr: "\(prepend) does not exist, skipping\n")
            == ["\(prepend) does not exist, skipping"])
        #expect(ResticService.unreadableItemPaths(errors: [], stderr: "\(prepend) does not exist, skipping\n")
            .values.map { Array($0.utf8) } == [Array(prepend.utf8)])
        #expect(ResticService.unreadableItems(errors: [], stderr: stderr) == [
            "/x/does-not-exist does not exist, skipping",
            "/y cannot be accessed, skipping",
        ])
        // Each line's path, as restic named it — the item of an event, the
        // source a skip line names — so a fix never parses free text.
        #expect(ResticService.unreadableItemPaths(errors: events, stderr: stderr) == [
            "/x/does-not-exist does not exist, skipping": "/x/does-not-exist",
            "/y cannot be accessed, skipping": "/y",
            "/src/a.pdf: open /src/a.pdf: permission denied": "/src/a.pdf",
        ])
        let itemless = try errors([#"{"message_type":"error","error":{"message":"walk failed"}}"#])
        #expect(ResticService.unreadableItemPaths(errors: itemless, stderr: "") == [:])

        // Two names that differ only in Unicode normalization are two items
        // to restic: both listed, each with its path.
        let nfc = "/src/caf\u{E9}.pdf", nfd = "/src/cafe\u{301}.pdf"
        let twins = try errors([nfc, nfd].map { path in
            #"{"message_type":"error","error":{"message":"open: permission denied"},"during":"archival","item":"\#(path)"}"#
        })
        #expect(ResticService.unreadableItems(errors: twins, stderr: "").count == 2)
        #expect(Set(ResticService.unreadableItemPaths(errors: twins, stderr: "").values.map { PathKey($0) }) == [PathKey(nfc), PathKey(nfd)])
    }

    @Test("restic's trailing newline stays out of the stored line, and a copy without it is still the same item")
    func unreadableItemsDropTrailingWhitespace() throws {
        // restic 0.19.1 ends its extended-attribute errors with a newline,
        // and the stored line lands in the banner, the plan row, the drawer
        // and Copy Details, where a newline breaks the sentence.
        let events = try errors([
            #"{"message_type":"error","error":{"message":"can not obtain extended attribute com.apple.macl for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.macl: operation not permitted\n"},"during":"archival","item":"/Users/u/Library/Safari"}"#,
            #"{"message_type":"error","error":{"message":"can not obtain extended attribute com.apple.quarantine for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.quarantine: operation not permitted\n"},"during":"archival","item":"/Users/u/Library/Safari"}"#,
            #"{"message_type":"error","error":{"message":"open /src/a.pdf: permission denied\r\n"},"during":"archival","item":"/src/a.pdf"}"#,
            #"{"message_type":"error","error":{"message":"open /src/a.pdf: permission denied"},"during":"archival","item":"/src/a.pdf"}"#,
            #"{"message_type":"error","error":{"message":"open /src/b.pdf: permission denied \t"},"during":"archival","item":"/src/b.pdf"}"#,
            #"{"message_type":"error","error":{"message":"walk failed\n"}}"#,
            #"{"message_type":"error","error":{"message":"walk failed"}}"#,
        ])
        let lines = ResticService.unreadableItems(errors: events, stderr: "")
        #expect(lines == [
            "/Users/u/Library/Safari: can not obtain extended attribute com.apple.macl for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.macl: operation not permitted",
            "/src/a.pdf: open /src/a.pdf: permission denied",
            "/src/b.pdf: open /src/b.pdf: permission denied",
            "walk failed",
        ])
        #expect(!lines.contains { $0.last?.isWhitespace == true })
    }
}
