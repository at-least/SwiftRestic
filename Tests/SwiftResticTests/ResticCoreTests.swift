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
