import Foundation
import Testing

@Suite("rclone remote listing")
struct RcloneRemotesTests {
    @Test("`listremotes --long` output parses into names and types, a remote's description aside")
    func longOutput() {
        // `-l` is rclone's global --links, not --long: listremotes -l printed
        // names alone on every rclone tried, 1.50.2 to 1.75.2 (2026-10-16).
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
}
