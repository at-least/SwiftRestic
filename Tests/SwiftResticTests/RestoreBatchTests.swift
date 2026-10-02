import Foundation
import Testing

/// Several items of one backup restored together: which items a selection
/// restores, which names it refuses, and the restic calls it becomes.
@Suite("Restore batch")
struct RestoreBatchTests {
    private func file(_ path: String) -> SnapshotNode {
        SnapshotNode(name: (path as NSString).lastPathComponent, type: .file, path: path)
    }

    private func folder(_ path: String) -> SnapshotNode {
        SnapshotNode(name: (path as NSString).lastPathComponent, type: .dir, path: path)
    }

    @Test("an item inside a selected folder is dropped — the folder brings it — and a repeat counts once")
    func covering() {
        let project = folder("/Data/Project")
        let inside = file("/Data/Project/notes.txt")
        let deeper = file("/Data/Project/src/main.swift")
        // A sibling whose name only starts with the folder's is not inside it.
        let sibling = file("/Data/Project 2.txt")
        let other = file("/Data/todo.txt")
        #expect(RestoreBatch.covering([inside, project, sibling, deeper, other, project]).map(\.path)
            == ["/Data/Project", "/Data/Project 2.txt", "/Data/todo.txt"])
        // A file is no folder: nothing is inside it.
        #expect(RestoreBatch.covering([file("/Data/a"), file("/Data/a/b")]).count == 2)
    }

    @Test("two names differing only in normalization are two items, not one")
    func coveringIsByteExact() {
        // "é" precomposed and decomposed: equal as Swift strings.
        let composed = file("/Data/caf\u{00E9}.txt")
        let decomposed = file("/Data/cafe\u{0301}.txt")
        #expect(composed.path == decomposed.path)
        #expect(RestoreBatch.covering([composed, decomposed]).count == 2)
    }

    @Test("names that would land twice in one folder are named, without case, each once")
    func collidingNames() {
        let names = ["Notes.txt", "notes.txt", "notes.txt", "Photos", "unique.txt", "Photos"]
        #expect(RestoreBatch.collidingNames(names) == ["Notes.txt", "Photos"])
        #expect(RestoreBatch.collidingNames(["a.txt", "b.txt"]).isEmpty)
    }

    @Test("one restic call per folder of the backup and directory, in the order each first appears")
    func groups() {
        let desktop = URL(fileURLWithPath: "/Users/me/Desktop")
        let a = file("/Data/Docs/a.txt")
        let b = folder("/Data/Pictures/Trip")
        let c = file("/Data/Docs/c.txt")
        let top = folder("/Volumes")
        let groups = RestoreBatch.groups([(a, desktop), (b, desktop), (c, desktop), (top, desktop)])
        #expect(groups == [
            RestoreBatch.Group(parent: "/Data/Docs", directory: desktop, nodes: [a, c]),
            RestoreBatch.Group(parent: "/Data/Pictures", directory: desktop, nodes: [b]),
            RestoreBatch.Group(parent: "/", directory: desktop, nodes: [top]),
        ])
        // Original location: one folder of the backup, one directory each.
        let back = RestoreBatch.groups([
            (a, URL(fileURLWithPath: "/Data/Docs")), (c, URL(fileURLWithPath: "/Data/Docs")),
        ])
        #expect(back.map(\.nodes) == [[a, c]])
    }

    @Test("an include matches its one name: restic's pattern characters are escaped")
    func includePattern() {
        #expect(RestoreBatch.includePattern(forName: "plain name.txt") == "/plain name.txt")
        #expect(RestoreBatch.includePattern(forName: "a[1].txt") == #"/a\[1\].txt"#)
        #expect(RestoreBatch.includePattern(forName: "star*?.txt") == #"/star\*\?.txt"#)
        #expect(RestoreBatch.includePattern(forName: #"back\slash"#) == #"/back\\slash"#)
        #expect(RestoreBatch.includePattern(forName: "-dash") == "/-dash")
        // A leading combining mark stays the name's own, not merged into the "/".
        #expect(RestoreBatch.includePattern(forName: "\u{0301}x").unicodeScalars.count == 3)
    }

    @Test("the folder holding a path, '/' above a top-level item")
    func parentPath() {
        #expect(RestoreBatch.parentPath(of: "/Data/Docs/a.txt") == "/Data/Docs")
        #expect(RestoreBatch.parentPath(of: "/Volumes") == "/")
        #expect(RestoreBatch.parentPath(of: "/Data/\u{0301}x") == "/Data")
    }
}
