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
        // Known code with restic's own words: explanation and words, both there.
        let known = ResticError.commandFailed(
            exitCode: 12,
            message: "Fatal: wrong password",
            command: "restic snapshots"
        ).errorDescription ?? ""
        #expect(known.contains("password"))
        #expect(known.contains("Fatal: wrong password"))

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
        // Whatever the machine would find without an override, it must find with
        // a whitespace-only one — including both failing together on a bare box.
        let withoutOverride = (try? ResticBinary.locate(userOverride: nil))?.url
        let withBlankOverride = (try? ResticBinary.locate(userOverride: "   "))?.url
        #expect(withoutOverride == withBlankOverride)
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
