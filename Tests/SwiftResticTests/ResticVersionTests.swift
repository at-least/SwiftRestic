import Foundation
import Testing

/// `restic version`'s line read as a version, and the minimum the app
/// takes at launch.
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

    @Test("the minimum is 0.19.1: it and anything newer are taken, anything older is not")
    func minimum() throws {
        #expect(ResticVersion.minimumSupported.dotted == "0.19.1")
        #expect(try #require(ResticVersion(parsing: "restic 0.19.1 compiled with go1.26.4 on darwin/arm64")).isSupported)
        #expect(try #require(ResticVersion(parsing: "restic 0.20.0 compiled with go1.27.0")).isSupported)
        #expect(try #require(ResticVersion(parsing: "restic 1.0.0 compiled with go1.27.0")).isSupported)
        #expect(try !#require(ResticVersion(parsing: "restic 0.19.0 compiled with go1.26.4 on darwin/arm64")).isSupported)
        // restic names a build from source after release X "X-dev": one
        // after the minimum is taken, one from before it is not.
        #expect(try #require(ResticVersion(parsing: "restic 0.19.1-dev (compiled manually) compiled with go1.27.1")).isSupported)
        #expect(try !#require(ResticVersion(parsing: "restic 0.19.0-dev (compiled manually) compiled with go1.26.4")).isSupported)
        #expect(try !#require(ResticVersion(parsing: "restic 0.18.1 compiled with go1.25.1 on darwin/arm64")).isSupported)
    }

    @Test("CI's oldest-supported job runs the minimum")
    func ciRunsTheMinimum() throws {
        let workflow = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/ci.yml")
        let text = try String(contentsOf: workflow, encoding: .utf8)
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let index = try #require(lines.firstIndex(of: "role: oldest supported"), "\(workflow.path)")
        #expect(lines[index - 1] == "- restic: \"\(ResticVersion.minimumSupported.dotted)\"")
    }

    @Test("pre-release and build suffixes ride on the patch, never promote it")
    func suffixes() throws {
        // A dev build of 0.15 is still 0.15 — the restore stall cap's whole
        // reason to exist is that this one must not read as no-version.
        let dev = try #require(ResticVersion(parsing: "restic 0.15.0-dev compiled with go1.21.0"))
        #expect(dev.minor == 15)
        #expect(dev.patch == 0)

        let releaseCandidate = try #require(ResticVersion(parsing: "restic 0.18.0-rc.1 compiled with go1.24.0"))
        #expect(releaseCandidate.minor == 18)
        #expect(releaseCandidate.patch == 0)

        let buildStamped = try #require(ResticVersion(parsing: "restic 0.19.1+123 compiled with go1.26.5"))
        #expect(buildStamped.patch == 1)

        // The test stub's own version line: the minimum, so the model takes it.
        let stub = try #require(ResticVersion(parsing: "restic 0.19.1-stub compiled with sh on darwin"))
        #expect(stub.isSupported)
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
