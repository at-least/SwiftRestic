import Foundation
import Testing

@Suite("restic error messages")
struct ResticErrorTests {
    /// The exit codes restic documents, per `man restic` — the mapping the error
    /// banners are built on.
    @Test("restic's \"Fatal:\" stays out of what a person reads; the reason after it stays, and Copy Details keeps the line whole")
    func fatalPrefixOffScreen() {
        let line = "Fatal: config cannot be loaded: open /Volumes/A/config: permission denied"
        let error = ResticError.commandFailed(exitCode: 1, message: line)
        #expect(error.errorDescription == "Config cannot be loaded: open /Volumes/A/config: permission denied")
        #expect(error.resticDetail == line)
    }

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
        // Retry can never succeed here, so the failure carries its fix, and
        // restic's own words go to Copy Details.
        let wrongPassword = ResticError.commandFailed(
            exitCode: 12,
            message: "Fatal: wrong password"
        ).errorDescription ?? ""
        #expect(wrongPassword == "The password doesn’t open this backup location.")
        #expect(ResticError.commandFailed(exitCode: 12, message: "Fatal: wrong password").resticDetail == "Fatal: wrong password")
        #expect(ResticError.commandFailed(exitCode: 12, message: "").resticDetail == nil)
        // A run knows its location: the refused password names it, and a
        // disk's missing backups ask after the disk.
        #expect(ResticError.words(for: ResticError.commandFailed(exitCode: 12, message: ""), location: ("NAS", .sftp))
            == "The password doesn’t open “NAS”.")
        #expect(ResticError.words(for: ResticError.commandFailed(exitCode: 10, message: ""), location: ("Backup", .local))
            == "Backups not found. Is the disk connected? If it moved, locate it.")
        #expect(ResticError.words(for: ResticError.commandFailed(exitCode: 10, message: ""), location: ("NAS", .sftp))
            == "The backups aren’t at this location. Put them back, or add them where they are now as a new backup location.")

        // A missing repository and a lock carry their fix the same way: the
        // banner and the notification repeat this message.
        #expect(ResticError.commandFailed(
            exitCode: 10,
            message: "Fatal: repository does not exist: unable to open config file: stat /Volumes/A/config: no such file or directory"
        ).errorDescription == "The backups aren’t at this location. Put them back, or add them where they are now as a new backup location.")
        #expect(ResticError.commandFailed(exitCode: 10, message: "").errorDescription
            == "The backups aren’t at this location. Put them back, or add them where they are now as a new backup location.")
        #expect(ResticError.commandFailed(
            exitCode: 11,
            message: "Fatal: repository is locked"
        ).errorDescription == "The backup location is in use by another Mac or app.")

        let known = ResticError.commandFailed(
            exitCode: 3,
            message: "warning: at least one source file could not be read"
        ).errorDescription ?? ""
        #expect(known.contains("some data couldn’t be read"))
        #expect(known.contains("warning: at least one source file could not be read"))

        let bare = ResticError.commandFailed(
            exitCode: 130,
            message: ""
        ).errorDescription ?? ""
        #expect(bare == "It was interrupted. Show Log has the details.")
        #expect(ResticError.commandFailed(exitCode: 1, message: "").errorDescription
            == "It stopped with an error. Show Log has the details.")
        #expect(ResticError.commandFailed(exitCode: 2, message: "").errorDescription
            == "It stopped unexpectedly. Show Log has the details.")

        #expect(
            ResticError.commandFailed(exitCode: 99, message: "disk on fire")
                .errorDescription == "disk on fire"
        )
        #expect(
            ResticError.commandFailed(exitCode: 99, message: "")
                .errorDescription == "It stopped unexpectedly. Show Log has the details."
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
        #expect(unknownText == "SSH refused this server’s key. Show Log has what SSH said.")
        let changedText = ResticError.commandFailed(exitCode: 1, message: changed.failureMessage).errorDescription ?? ""
        #expect(changedText.hasPrefix("This server’s SSH key has changed since this Mac last connected"))
        #expect(changedText.contains("~/.ssh/known_hosts"))
        #expect(!changedText.contains("restic") && !changedText.contains("Terminal"))
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
            == "The location refused to delete 1 backup (403 Forbidden) — it may be append-only or locked. "
            + "Turn off removing old backups, or allow deletions on this storage.")
        #expect(ResticError.snapshotsNotRemoved(removed: 2, refused: 1, reason: "operation not permitted").errorDescription
            == "The location refused to delete 1 of the 3 old backups (operation not permitted); the other 2 were removed. "
            + "It may be append-only or locked. Turn off removing old backups, or allow deletions on this storage.")
        #expect(ResticError.snapshotsNotRemoved(removed: 1, refused: 2, reason: "").errorDescription
            == "The location refused to delete 2 of the 3 old backups; the other one was removed. "
            + "It may be append-only or locked. Turn off removing old backups, or allow deletions on this storage.")
    }

    @Test("a missing password names the location it is missing for")
    func passwordMissingNamesTheLocation() {
        #expect(ResticError.passwordMissing(repositoryName: "NAS").errorDescription == "No password is stored for “NAS”.")
    }

    @Test("a launch failure, an unreadable answer and an unrestored item say what to do next, without naming restic")
    func appFailuresInTheReadersWords() {
        #expect(ResticError.processLaunchFailed("The file “restic” doesn’t exist").errorDescription
            == "The backup engine couldn’t start: The file “restic” doesn’t exist. Install SwiftRestic again if this keeps happening.")
        #expect(ResticError.malformedOutput(detail: "1 change line did not decode").errorDescription
            == "It finished, but its result couldn’t be read (1 change line did not decode). Show Log has the details.")
        #expect(ResticError.notRestored(paths: ["/Restored/a.txt"]).errorDescription
            == "/Restored/a.txt wasn’t restored: nothing by that name is in the backup. A name written on another kind of computer can do this.")
        #expect(ResticError.notRestored(paths: ["/Restored/a.txt", "/Restored/b.txt"]).errorDescription
            == "/Restored/a.txt and /Restored/b.txt weren’t restored: nothing by that name is in the backup. "
            + "A name written on another kind of computer can do this.")
    }

    @Test("only exit 11 reads as a locked location")
    func lockedIsExitElevenOnly() {
        #expect(ResticError.isRepositoryLocked(ResticError.commandFailed(exitCode: 11, message: "Fatal: repository is locked")))
        #expect(!ResticError.isRepositoryLocked(ResticError.commandFailed(exitCode: 1, message: "Fatal: repository is locked")))
        #expect(!ResticError.isRepositoryLocked(ResticError.timedOut(seconds: 11)))
    }

    @Test("a stop is Swift's cancellation or restic's own; a failure is neither")
    func cancellationReading() {
        #expect(ResticError.isCancellation(CancellationError()))
        #expect(ResticError.isCancellation(ResticError.cancelled))
        #expect(!ResticError.isCancellation(ResticError.commandFailed(exitCode: 130, message: "")))
    }
}

@Suite("restic binary location")
struct ResticBinaryTests {
    @Test("restic's PATH reaches a Homebrew or MacPorts ssh")
    func helperFoldersAreOnResticsPath() throws {
        let path = try #require(ResticRunner.baseEnvironment()["PATH"]).split(separator: ":").map(String.init)
        // An sftp location needs ssh, which a GUI app's near-empty PATH
        // would not find where Homebrew or MacPorts put it.
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            #expect(path.contains(directory), "\(directory) missing from \(path)")
        }
    }

    @Test("the app runs restic from where the build phase puts it")
    func bundledHelpersMatchTheBuildPhase() {
        // build.sh checks that the built app carries the pinned restic there.
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        #expect(ResticBinary.bundled.url == helpers.appendingPathComponent("restic"))
    }

    @Test("a folder is not an executable file, though its mode has the execute bit")
    func folderIsNotAnExecutableFile() throws {
        let script = try writeExecutableScript("exit 0", label: "ExecutableFile")
        let folder = script.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(FileManager.default.isExecutableFile(atPath: folder.path), "the premise: the folder's mode has the execute bit")
        #expect(!ResticBinary.isExecutableFile(atPath: folder.path))
        #expect(ResticBinary.isExecutableFile(atPath: script.path))
    }
}

@Suite("Child environment")
struct ChildEnvironmentTests {
    @Test("what a run passes wins over what the app inherited")
    func invocationEnvironmentWins() async throws {
        // Every app inherits HOME; a run that names it must reach the child
        // as written.
        let inherited = try #require(ProcessInfo.processInfo.environment["HOME"])
        let result = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: ["-c", #"printf '%s\n' "$HOME""#], environment: ["HOME": inherited + "/elsewhere"])
        )
        #expect(result.stdout == inherited + "/elsewhere\n", "the child saw HOME as \(result.stdout.debugDescription)")
    }

    @Test("a child reads end-of-file at once on stdin, so a backend that prompts fails instead of hanging")
    func stdinIsNull() async throws {
        let result = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: ["-c", "stat -L -f %r /dev/stdin; stat -f %r /dev/null"], timeout: 10)
        )
        let devices = result.stdout.split(separator: "\n")
        #expect(devices.count == 2 && devices[0] == devices[1], "stdin is not /dev/null: \(result.stdout.debugDescription)")
    }

    @Test("restic's own progress printer runs at one frame a second")
    func progressPrinterIsQuiet() async throws {
        let result = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: ["-c", #"printf '%s\n' "$RESTIC_PROGRESS_FPS""#])
        )
        #expect(result.stdout == "1\n")
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

    @Test("a last line without a newline still counts")
    func unterminatedLastLineCounts() async throws {
        let line = #"{"message_type":"summary","files_new":2}"#
        let result = try await ResticRunner().run(
            binary: URL(fileURLWithPath: "/bin/sh"),
            invocation: ResticInvocation(arguments: ["-c", "printf '%s' '\(line)'"])
        )
        #expect(result.summary?.filesNew == 2, "the unterminated summary line was dropped")
        #expect(result.stdout == line + "\n")
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

@Suite("Global arguments")
struct GlobalArgumentTests {
    @Test("an SFTP location accepts a new server's key and nothing else adds a flag")
    func sftpAcceptsNewHostKey() {
        var repository = Repository()
        for kind in Repository.Kind.allCases where kind != .sftp {
            repository.kind = kind
            #expect(RepositoryContext(repository: repository, password: "p").globalArguments.isEmpty, "\(kind)")
        }
        repository.kind = .sftp
        #expect(
            RepositoryContext(repository: repository, password: "p").globalArguments
                == ["-o", "sftp.args=-o StrictHostKeyChecking=accept-new"]
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
