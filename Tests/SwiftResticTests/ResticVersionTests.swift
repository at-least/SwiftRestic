import Foundation
import Testing

/// The version gate behind the restore commands' idle stall cap: restic
/// began streaming `restore --json` progress in 0.16, so an older binary's
/// healthy silence must read as work, not as a hang.
@Suite("restic version parsing")
struct ResticVersionTests {
    @Test("the version line parses to its triple")
    func parses() throws {
        let version = try #require(
            ResticVersion(parsing: "restic 0.19.1 compiled with go1.26.5 darwin/arm64\n")
        )
        #expect(version.major == 0)
        #expect(version.minor == 19)
        #expect(version.patch == 1)
    }

    @Test("restore progress streaming starts at 0.16")
    func restoreProgressGate() throws {
        let before = try #require(ResticVersion(parsing: "restic 0.15.2 compiled with go1.21.0"))
        let at = try #require(ResticVersion(parsing: "restic 0.16.0 compiled with go1.21.0"))
        let current = try #require(ResticVersion(parsing: "restic 0.19.1 compiled with go1.26.5"))
        #expect(!before.streamsRestoreProgress)
        #expect(at.streamsRestoreProgress)
        #expect(current.streamsRestoreProgress)
    }

    @Test("pre-release and build suffixes ride on the patch, never promote it")
    func suffixes() throws {
        // A dev build of 0.15 is still 0.15 — the restore stall cap's whole
        // reason to exist is that this one must not read as no-version.
        let dev = try #require(ResticVersion(parsing: "restic 0.15.0-dev compiled with go1.21.0"))
        #expect(dev.minor == 15)
        #expect(dev.patch == 0)
        #expect(!dev.streamsRestoreProgress)

        let releaseCandidate = try #require(ResticVersion(parsing: "restic 0.18.0-rc.1 compiled with go1.24.0"))
        #expect(releaseCandidate.minor == 18)
        #expect(releaseCandidate.patch == 0)
        #expect(releaseCandidate.streamsRestoreProgress)

        let buildStamped = try #require(ResticVersion(parsing: "restic 0.19.1+123 compiled with go1.26.5"))
        #expect(buildStamped.patch == 1)

        // The test stub's own version line: 0.0.0, firmly pre-0.16.
        let stub = try #require(ResticVersion(parsing: "restic 0.0.0-stub compiled with sh on darwin"))
        #expect(stub.major == 0 && stub.minor == 0 && stub.patch == 0)
        #expect(!stub.streamsRestoreProgress)
    }

    @Test("leading whitespace and multi-line output both parse")
    func tolerantLeading() throws {
        let padded = try #require(ResticVersion(parsing: "  restic 0.19.1 compiled\nsecond line"))
        #expect(padded.minor == 19)
    }

    @Test("unparseable output is not a version")
    func garbageIsNil() {
        #expect(ResticVersion(parsing: "") == nil)
        #expect(ResticVersion(parsing: "restic") == nil)
        #expect(ResticVersion(parsing: "restic 0.16") == nil)
        #expect(ResticVersion(parsing: "restic 0.16.x") == nil)
        #expect(ResticVersion(parsing: "sh: restic: command not found") == nil)
    }
}
