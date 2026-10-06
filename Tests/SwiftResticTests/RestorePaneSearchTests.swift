import Foundation
import Testing

/// The Restore pane's search: the hits the open backup holds, and how many
/// matching items only other backups hold — the count that turns "No
/// matches in this backup" from a dead end into a way on.
@Suite("Restore pane search")
struct RestorePaneSearchTests {
    private func hit(_ path: String, isDirectory: Bool = false) -> SearchHit {
        SearchHit(path: path, isDirectory: isDirectory)
    }

    @Test("splits hits by the open backup and counts the rest")
    func splitsByOpenBackup() {
        let result = RestorePaneSearch(
            hits: [hit("/D/note-1.md"), hit("/D/note-12.md"), hit("/P/note.heic")],
            inRecord: ["/D/note-1.md": false],
            limit: 200,
            indexIsComplete: true
        )

        #expect(result.inThisBackup.map(\.path) == ["/D/note-1.md"])
        // Every hit is in some backup — the search returns no path whose
        // every version was pruned (SnapshotIndexTests pins it) — so the
        // hits the open backup lacks are the ones elsewhere.
        #expect(result.elsewhereCount == 2)
        #expect(result.isTruncated == false)
        #expect(result.note == "2 matching items are only in other backups.")
    }

    @Test("one elsewhere hit reads in the singular; nothing anywhere adds no note")
    func singularAndEmptyNotes() {
        let one = RestorePaneSearch(
            hits: [hit("/D/Budget.numbers")],
            inRecord: [:],
            limit: 200,
            indexIsComplete: true
        )
        #expect(one.inThisBackup.isEmpty)
        #expect(one.elsewhereCount == 1)
        #expect(one.note == "1 matching item is only in other backups.")

        let none = RestorePaneSearch(hits: [], inRecord: [:], limit: 200, indexIsComplete: true)
        #expect(none.elsewhereCount == 0)
        #expect(none.note == nil)
    }

    @Test("a search at the index ceiling quotes no count")
    func ceilingIsAFloor() {
        let result = RestorePaneSearch(
            hits: [hit("/a"), hit("/b"), hit("/c")],
            inRecord: ["/a": false],
            limit: 3,
            indexIsComplete: true
        )

        #expect(result.isTruncated)
        #expect(result.elsewhereCount == 2)
        #expect(result.note == "The search stopped at the first 3 matches in this repository — narrow it to see more.")
    }

    @Test("an index still reading places no match and quotes no count")
    func incompleteIndexHedges() {
        let hedge = "The search index is still reading this repository — some matches may be missing."
        // The open backup not read yet: the index answers nothing about it,
        // and holds its Budget.numbers only under the backups it has read,
        // so the file looks as if only they hold it — the pane must not say so.
        let unread = RestorePaneSearch(
            hits: [hit("/D/Budget.numbers")],
            inRecord: [:],
            limit: 200,
            indexIsComplete: false
        )
        #expect(unread.inThisBackup.isEmpty)
        #expect(unread.note == hedge)
        #expect(unread.note?.contains("only in other backups") == false)

        // Nothing found yet is not "no other backup matches".
        let none = RestorePaneSearch(hits: [], inRecord: [:], limit: 200, indexIsComplete: false)
        #expect(none.note == hedge)

        // It outranks the ceiling: both parts of a partial index are partial.
        let atCeiling = RestorePaneSearch(
            hits: [hit("/a"), hit("/b"), hit("/c")],
            inRecord: ["/a": false],
            limit: 3,
            indexIsComplete: false
        )
        #expect(atCeiling.note == hedge)
    }

    /// The NFC and NFD spellings of a name are one String to Swift and two
    /// paths to restic: an older backup holds the NFD file, the open one the
    /// NFC folder. The pane must list only the folder, as a folder — the
    /// file is elsewhere — and the two hits must be two rows.
    @Test("a hit only canonically equal to a path the open backup holds is not listed in it")
    func byteDistinctSpellingsSplitByBytes() {
        let nfc = "/data/caf\u{e9}"       // … 66 C3 A9
        let nfd = "/data/cafe\u{301}"     // … 66 65 CC 81
        let result = RestorePaneSearch(
            hits: [hit(nfd, isDirectory: false), hit(nfc, isDirectory: true)],
            inRecord: [PathKey(nfc): true],
            limit: 200,
            indexIsComplete: true
        )
        #expect(result.inThisBackup.map { Array($0.path.utf8) } == [Array(nfc.utf8)])
        #expect(result.inThisBackup.map(\.isDirectory) == [true])
        #expect(result.elsewhereCount == 1)
        #expect(hit(nfc).id != hit(nfd).id)
    }

    /// The search's kind is the path's kind in the newest backup holding it;
    /// the pane restores from the open backup, whose kind may differ — and
    /// the restore picks `dump` or `restore` by the kind it is handed.
    @Test("a hit the open backup holds carries its kind in that backup, not the search's")
    func inRecordHitCarriesRecordKind() {
        let result = RestorePaneSearch(
            hits: [
                hit("/D/Project", isDirectory: false),      // a file in the newest backup…
                hit("/D/notes", isDirectory: true),         // …a folder there
                hit("/D/report.pdf", isDirectory: false),
            ],
            inRecord: ["/D/Project": true, "/D/notes": false, "/D/report.pdf": false],
            limit: 200,
            indexIsComplete: true
        )

        #expect(result.inThisBackup == [
            SearchHit(path: "/D/Project", isDirectory: true),
            SearchHit(path: "/D/notes", isDirectory: false),
            SearchHit(path: "/D/report.pdf", isDirectory: false),
        ])
        #expect(result.elsewhereCount == 0)
    }
}
