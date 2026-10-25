import Foundation
import Testing

@Suite("rclone remote listing")
struct RcloneRemotesTests {
    @Test("`listremotes --long` output parses into names and types, a remote's description aside")
    func longOutput() {
        // `-l` is rclone's global --links, not --long: listremotes -l printed
        // names alone on every rclone tried, 1.50.2 to 1.75.2.
        #expect(RcloneRemoteLister.arguments == ["listremotes", "--long"])
        // rclone 1.50.2 prints "name: type"; 1.75.2 pads the type and adds
        // the remote's description after it.
        let remotes = RcloneRemoteLister.parse("mydrive: drive\nnas-box: sftp  Home box\ns3:      s3\n")
        #expect(remotes == [
            RcloneRemote(name: "mydrive", type: "drive"),
            RcloneRemote(name: "nas-box", type: "sftp"),
            RcloneRemote(name: "s3", type: "s3"),
        ])
    }

    @Test("plain `listremotes` output parses with empty types")
    func shortOutput() {
        let remotes = RcloneRemoteLister.parse("a:\nb:\n")
        #expect(remotes == [
            RcloneRemote(name: "a", type: ""),
            RcloneRemote(name: "b", type: ""),
        ])
        #expect(remotes[0].menuTitle == "a")
    }

    @Test("blank lines, stray text, and whitespace are tolerated")
    func messyOutput() {
        let remotes = RcloneRemoteLister.parse(
            "\nmydrive: drive\r\n  my drive:  b2  \nnot a remote\n:noname\ntrailing:"
        )
        #expect(remotes == [
            RcloneRemote(name: "mydrive", type: "drive"),
            // A remote name may contain a space, though not at either end
            // (rclone.org/docs, "Valid remote names"); the first colon splits it.
            RcloneRemote(name: "my drive", type: "b2"),
            // Colonless lines and nameless colons drop out.
            RcloneRemote(name: "trailing", type: ""),
        ])
    }

    @Test("the menu names the type only when there is one")
    func menuTitles() {
        #expect(RcloneRemote(name: "mydrive", type: "drive").menuTitle == "mydrive — drive")
        #expect(RcloneRemote(name: "a", type: "").menuTitle == "a")
    }

    private func stubRclone(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticRclone-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("rclone")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    @Test("rclone's remotes, none yet, or why it could not list them")
    func setup() async throws {
        let lister = RcloneRemoteLister(runner: ResticRunner())
        let listed = try stubRclone(#"printf 'gd:  drive \nnas: sftp  Home box\n'"#)
        #expect(await lister.list(binary: listed)
            == .remotes([RcloneRemote(name: "gd", type: "drive"), RcloneRemote(name: "nas", type: "sftp")]))
        // No config file yet: rclone 1.75.2 says so as a NOTICE and exits 0.
        let empty = try stubRclone(#"echo '2026/10/25 18:07:29 NOTICE: Config file "/x/rclone.conf" not found - using defaults' >&2"#)
        #expect(await lister.list(binary: empty) == .remotes([]))
        // rclone 1.75.2's words for a config it cannot parse.
        let broken = try stubRclone(#"echo '2026/10/25 18:07:23 CRITICAL: Failed to load config file "/x/rclone.conf": could not parse line: [bad' >&2; exit 1"#)
        #expect(await lister.list(binary: broken)
            == .unreadable(#"rclone could not list its remotes: Failed to load config file "/x/rclone.conf": could not parse line: [bad"#))
        // An encrypted config, as rclone 1.75.2 answers it with no stdin.
        let encrypted = try stubRclone(#"printf 'Enter configuration password:\npassword:' >&2; echo '2026/10/25 18:07:29 CRITICAL: Failed to read line: EOF' >&2; exit 1"#)
        #expect(await lister.list(binary: encrypted) == .unreadable(RcloneSetup.passwordProtected))
    }
}
