import Foundation
import Testing

@Suite("rclone remote listing")
struct RcloneRemotesTests {
    @Test("`listremotes -l` output parses into names and types")
    func longOutput() {
        let remotes = RcloneRemoteLister.parse("mydrive: drive\nnas-box: sftp\n")
        #expect(remotes == [
            RcloneRemote(name: "mydrive", type: "drive"),
            RcloneRemote(name: "nas-box", type: "sftp"),
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
            "\nmydrive: drive\r\n  spaced:  b2  \nnot a remote\n:noname\ntrailing:"
        )
        #expect(remotes == [
            RcloneRemote(name: "mydrive", type: "drive"),
            // A remote name may contain spaces; the first colon splits it.
            RcloneRemote(name: "spaced", type: "b2"),
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
