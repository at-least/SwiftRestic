import Foundation
import Testing

/// A Files folder's changes since the backup before, as the pane words
/// them: the counts in a fixed order, only those that are not zero, the
/// gone names, and a mark per listed child.
@Suite("Folder change summary")
struct FolderChangeSummaryTests {
    private let previous = Date(timeIntervalSince1970: 1_790_904_600)

    @Test("the line counts what changed in the folder itself, and says so when nothing did")
    func summaryLine() {
        let since = Format.timestamp(previous)
        #expect(FolderChanges().summary(since: previous) == "No changes in this folder since \(since)")
        let changes = FolderChanges(
            added: ["/d/new"], removed: ["/d/a", "/d/b"], modified: ["/d/m"], uncertain: ["/d/u"]
        )
        #expect(changes.summary(since: previous)
            == "Since \(since), in this folder: 1 added, 1 modified, 2 removed, 1 may have changed")
        #expect(FolderChanges(removed: ["/d/a"]).summary(since: previous) == "Since \(since), in this folder: 1 removed")
    }

    @Test("what is gone is named, and each listed child wears its mark by its path's bytes")
    func removedAndMarks() {
        let changes = FolderChanges(added: ["/d/new"], removed: ["/d/a", "/d/b"], modified: ["/d/caf\u{E9}"], uncertain: ["/d/u"])
        #expect(changes.removedNames == "Removed: a, b")
        #expect(FolderChanges(added: ["/d/x"]).removedNames == nil)
        #expect(changes.marks == [
            PathKey("/d/new"): "Added", PathKey("/d/caf\u{E9}"): "Modified", PathKey("/d/u"): "May have changed",
        ])
        // The other spelling of the same name is another file, unmarked.
        #expect(changes.marks[PathKey("/d/cafe\u{301}")] == nil)
    }
}
