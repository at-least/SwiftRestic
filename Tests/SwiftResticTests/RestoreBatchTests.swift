import Foundation
import Testing

/// Several items restored together: which items a selection restores,
/// which names it refuses, and the restic calls it becomes.
@Suite("Restore batch")
struct RestoreBatchTests {
    private func file(_ path: String) -> SnapshotNode {
        SnapshotNode(name: (path as NSString).lastPathComponent, type: .file, path: path)
    }

    private func folder(_ path: String) -> SnapshotNode {
        SnapshotNode(name: (path as NSString).lastPathComponent, type: .dir, path: path)
    }

    /// A selection of one backup, as the Restore pane's is.
    private func oneBackup(_ nodes: [SnapshotNode]) -> (kept: [SnapshotNode], covered: [(item: SnapshotNode, folder: SnapshotNode)]) {
        RestoreBatch.covering(nodes, backup: { _ in "backup" })
    }

    @Test("an item inside a selected folder is dropped — the folder brings it — and a repeat counts once")
    func covering() {
        let project = folder("/Data/Project")
        let inside = file("/Data/Project/notes.txt")
        let deeper = file("/Data/Project/src/main.swift")
        // A sibling whose name only starts with the folder's is not inside it.
        let sibling = file("/Data/Project 2.txt")
        let other = file("/Data/todo.txt")
        #expect(oneBackup([inside, project, sibling, deeper, other, project]).kept.map(\.path)
            == ["/Data/Project", "/Data/Project 2.txt", "/Data/todo.txt"])
        // A file is no folder: nothing is inside it.
        #expect(oneBackup([file("/Data/a"), file("/Data/a/b")]).kept.count == 2)
        // A folder spelled with its slash, or the root, is not inside itself.
        let slashed = oneBackup([folder("/Data/Project/"), inside])
        #expect(slashed.kept.map(\.path) == ["/Data/Project/"])
        #expect(slashed.covered.map(\.item.path) == ["/Data/Project/notes.txt"])
        let root = oneBackup([folder("/"), other])
        #expect(root.kept.map(\.path) == ["/"])
        #expect(root.covered.map(\.item.path) == ["/Data/todo.txt"])
    }

    @Test("what was dropped for being inside a selected folder, with the folder that brings it, in words")
    func coveredAndItsNote() {
        let project = folder("/Data/Project")
        let src = folder("/Data/Project/src")
        let main = file("/Data/Project/src/main.swift")
        let notes = file("/Data/Project/notes.txt")
        let photos = folder("/Data/Photos")
        let trip = file("/Data/Photos/trip.jpg")
        let other = file("/Data/todo.txt")

        // A file inside a folder inside the selected one is restored with
        // the outermost — the folder `covering` keeps.
        let covered = oneBackup([project, src, main, other]).covered
        #expect(covered.map(\.item.path) == ["/Data/Project/src", "/Data/Project/src/main.swift"])
        #expect(covered.map(\.folder.path) == ["/Data/Project", "/Data/Project"])
        // A row twice is restored once, and was not inside anything.
        #expect(oneBackup([project, other, project]).covered.isEmpty)
        // Nothing inside anything: nothing to say.
        #expect(oneBackup([project, other]).covered.isEmpty)
        #expect(RestoreBatch.coveredNote(oneBackup([]).covered) == nil)

        func note(_ nodes: [SnapshotNode]) -> String? {
            RestoreBatch.coveredNote(oneBackup(nodes).covered)
        }
        #expect(note([src, main]) == "“main.swift” is inside “src” and is restored with it.")
        #expect(note([project, notes, main]) == "“notes.txt” and “main.swift” are inside “Project” and are restored with it.")
        #expect(note([project, notes, main, src]) == "3 of the selected items are inside “Project” and are restored with it.")
        #expect(note([project, notes, photos, trip]) == "2 of the selected items are inside selected folders and are restored with them.")
    }

    @Test("from several backups, a folder brings only what its own backup holds: a file found in an older backup restores on its own")
    func coveringAcrossBackups() {
        // Find Files' rows, each path at the newest backup holding it: Oct 2
        // still holds notes/ and keep.txt, notes.txt was deleted after Oct 1.
        let notes = RestoreSource(folder("/src/notes"), snapshotID: "oct2", backupTime: nil)
        let keep = RestoreSource(file("/src/notes/keep.txt"), snapshotID: "oct2", backupTime: nil)
        let deleted = RestoreSource(file("/src/notes/notes.txt"), snapshotID: "oct1", backupTime: nil)
        let (kept, covered) = RestoreBatch.covering([notes, keep, deleted, keep], backup: \.snapshotID)
        #expect(kept.map(\.path) == ["/src/notes", "/src/notes/notes.txt"])
        #expect(kept.map(\.snapshotID) == ["oct2", "oct1"])
        #expect(covered.map(\.item.path) == ["/src/notes/keep.txt"])
        #expect(RestoreBatch.coveredNote(covered) == "“keep.txt” is inside “notes” and is restored with it.")
    }

    @Test("two names differing only in normalization are two items, not one")
    func coveringIsByteExact() {
        // "é" precomposed and decomposed: equal as Swift strings.
        let composed = file("/Data/caf\u{00E9}.txt")
        let decomposed = file("/Data/cafe\u{0301}.txt")
        #expect(composed.path == decomposed.path)
        #expect(oneBackup([composed, decomposed]).kept.count == 2)
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
