import Foundation
import Testing

/// `ResticDiffChange` reading restic's spelling of a directory whose name
/// ends in a Prepend character. restic 0.19.1 wrote such a directory as
/// `…/new\u{0600}/` (`restic diff --json`, bytes `6e 65 77 d8 80 2f`); the
/// prefix is shortened here.
@Suite("restic diff change spelling")
struct ResticDiffChangeSpellingTests {
    @Test("a directory whose name ends in a Prepend character is a directory, named without its slash")
    func prependDirectory() {
        let change = ResticDiffChange(path: "/src/new\u{0600}/", modifier: "+")
        // The premise: the slash is inside the last Character.
        #expect(!change.path.hasSuffix("/"))
        #expect(change.path.utf8.last == UInt8(ascii: "/"))
        #expect(change.isDirectory)
        #expect(Array(change.name.utf8) == Array("new\u{0600}".utf8))
    }

    @Test("ordinary spellings: the marker, the name, the root")
    func ordinarySpellings() {
        #expect(ResticDiffChange(path: "/src/sub/", modifier: "+").isDirectory)
        #expect(ResticDiffChange(path: "/src/sub/", modifier: "+").name == "sub")
        #expect(!ResticDiffChange(path: "/src/a.txt", modifier: "M").isDirectory)
        #expect(ResticDiffChange(path: "/src/a.txt", modifier: "M").name == "a.txt")
        #expect(ResticDiffChange(path: "/", modifier: "U").isDirectory)
        #expect(ResticDiffChange(path: "/", modifier: "U").name == "/")
    }
}

/// `ResticPath`, the one owner of restic's path spelling.
@Suite("restic path spelling")
struct ResticPathTests {
    /// Scalars that join a following "/" into their own grapheme cluster on
    /// the OS the probe ran on (Grapheme_Cluster_Break=Prepend). The byte
    /// rules below do not depend on that; only `premise` names U+0600's.
    static let prepends: [Unicode.Scalar] = ["\u{0600}", "\u{0605}", "\u{06DD}", "\u{070F}", "\u{110BD}", "\u{11A84}"]

    @Test("the premise: U+0600 swallows the slash after it, so a Character test misses it")
    func premise() {
        let spelled = "/d/new\u{0600}/"
        #expect(spelled.last != "/")
        #expect(!spelled.hasSuffix("/"))
        #expect(spelled.utf8.last == UInt8(ascii: "/"))
    }

    @Test("normalized strips every trailing slash bytewise; the root and the empty path stay")
    func normalized() {
        let cases: [(String, String)] = [
            ("", ""), ("/", "/"), ("//", "/"), ("///", "/"),
            ("/a", "/a"), ("/a/", "/a"), ("/a//", "/a"), ("a/", "a"),
            ("/Users/alice/Documents/", "/Users/alice/Documents"),
            ("/caf\u{E9}/", "/caf\u{E9}"), ("/cafe\u{301}/", "/cafe\u{301}"),
        ]
        for (spelled, expected) in cases {
            #expect(Array(ResticPath.normalized(spelled).utf8) == Array(expected.utf8), "\(spelled.debugDescription)")
            #expect(ResticPath.normalizedBytes(spelled) == Array(expected.utf8), "\(spelled.debugDescription)")
        }
        for scalar in Self.prepends {
            let bare = "/d/new" + String(scalar)
            #expect(Array(ResticPath.normalized(bare + "/").utf8) == Array(bare.utf8), "U+\(String(scalar.value, radix: 16))")
            #expect(Array(ResticPath.normalized(bare + "//").utf8) == Array(bare.utf8), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("a trailing slash marks a directory, read bytewise; the root is a directory")
    func directorySpelling() {
        #expect(ResticPath.isDirectorySpelling("/d/sub/"))
        #expect(!ResticPath.isDirectorySpelling("/d/file"))
        #expect(ResticPath.isDirectorySpelling("/"))
        #expect(!ResticPath.isDirectorySpelling(""))
        // A combining mark after the separator begins a name: not a directory.
        #expect(!ResticPath.isDirectorySpelling("/d/\u{301}"))
        for scalar in Self.prepends {
            #expect(ResticPath.isDirectorySpelling("/d/new" + String(scalar) + "/"), "U+\(String(scalar.value, radix: 16))")
        }
    }

    @Test("basename cuts at the last separator scalar, whatever cluster holds it")
    func basename() {
        #expect(ResticPath.basename(of: "/src/notes.txt") == "notes.txt")
        #expect(ResticPath.basename(of: "/") == "")
        #expect(ResticPath.basename(of: "name") == "name")
        // A name beginning with a combining mark: "/\u{301}" is one Character.
        #expect(Array(ResticPath.basename(of: "/a/\u{301}x").utf8) == Array("\u{301}x".utf8))
        // A Prepend character before the separator: "\u{0600}/" is one Character.
        #expect(ResticPath.basename(of: "/a\u{0600}/b") == "b")
    }
}
