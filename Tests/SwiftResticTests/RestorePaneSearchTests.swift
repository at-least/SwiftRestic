import Foundation
import Testing

/// The Restore pane's search: the hits the open backup holds, and how many
/// matching items only other backups hold — the count that turns "No
/// matches in this backup" from a dead end into a way on.
@Suite("Restore pane search")
struct RestorePaneSearchTests {
    private func version(_ id: String) -> IndexedSnapshot {
        IndexedSnapshot(id: id, chain: "c", seq: 0, time: .distantPast, alive: true, coverage: .full)
    }

    private func hit(_ path: String) -> SearchHit {
        SearchHit(path: path, isDirectory: false)
    }

    @Test("splits hits by the open backup and counts the rest")
    func splitsByOpenBackup() {
        let result = RestorePaneSearch(
            hits: [hit("/D/note-1.md"), hit("/D/note-12.md"), hit("/D/pruned.md"), hit("/P/note.heic")],
            versionsByPath: [
                "/D/note-1.md": [version("abf"), version("672")],
                "/D/note-12.md": [version("672")],
                "/P/note.heic": [version("afb")],
            ],
            recordID: "abf",
            limit: 200,
            indexIsComplete: true
        )

        #expect(result.inThisBackup.map(\.path) == ["/D/note-1.md"])
        // Not hits minus the listed ones (3): a path every version of which
        // was pruned is in no backup at all.
        #expect(result.elsewhereCount == 2)
        #expect(result.isTruncated == false)
        #expect(result.note == "2 matching items are only in other backups.")
    }

    @Test("one elsewhere hit reads in the singular; nothing anywhere adds no note")
    func singularAndEmptyNotes() {
        let one = RestorePaneSearch(
            hits: [hit("/D/Budget.numbers")],
            versionsByPath: ["/D/Budget.numbers": [version("abf")]],
            recordID: "afb",
            limit: 200,
            indexIsComplete: true
        )
        #expect(one.inThisBackup.isEmpty)
        #expect(one.elsewhereCount == 1)
        #expect(one.note == "1 matching item is only in other backups.")

        let none = RestorePaneSearch(hits: [], versionsByPath: [:], recordID: "afb", limit: 200, indexIsComplete: true)
        #expect(none.elsewhereCount == 0)
        #expect(none.note == nil)
    }

    @Test("a search at the index ceiling quotes no count")
    func ceilingIsAFloor() {
        let result = RestorePaneSearch(
            hits: [hit("/a"), hit("/b"), hit("/c")],
            versionsByPath: ["/a": [version("abf")], "/b": [version("672")]],
            recordID: "abf",
            limit: 3,
            indexIsComplete: true
        )

        #expect(result.isTruncated)
        #expect(result.elsewhereCount == 1)
        #expect(result.note == "The search stopped at the first 3 matches in this repository — narrow it to see more.")
    }

    @Test("an index still reading places no match and quotes no count")
    func incompleteIndexHedges() {
        let hedge = "The search index is still reading this repository — some matches may be missing."
        // The open backup not read yet: the index holds its Budget.numbers
        // only under the backups it has read, so the file looks as if only
        // they hold it — the pane must not say so.
        let unread = RestorePaneSearch(
            hits: [hit("/D/Budget.numbers")],
            versionsByPath: ["/D/Budget.numbers": [version("73d"), version("672")]],
            recordID: "fresh",
            limit: 200,
            indexIsComplete: false
        )
        #expect(unread.inThisBackup.isEmpty)
        #expect(unread.note == hedge)
        #expect(unread.note?.contains("only in other backups") == false)

        // Nothing found yet is not "no other backup matches".
        let none = RestorePaneSearch(hits: [], versionsByPath: [:], recordID: "fresh", limit: 200, indexIsComplete: false)
        #expect(none.note == hedge)

        // It outranks the ceiling: both parts of a partial index are partial.
        let atCeiling = RestorePaneSearch(
            hits: [hit("/a"), hit("/b"), hit("/c")],
            versionsByPath: ["/a": [version("abf")], "/b": [version("672")]],
            recordID: "abf",
            limit: 3,
            indexIsComplete: false
        )
        #expect(atCeiling.note == hedge)
    }
}
