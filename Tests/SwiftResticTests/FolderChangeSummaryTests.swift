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

    @Test("what the chosen backup's own run could not read is not read, not removed")
    func unreadIsNotRemoved() {
        let since = Format.timestamp(previous)
        let changes = FolderChanges(removed: ["/d/gone", "/d/locked.pdf"])
        let unread = UnreadItems(lines: ["/d/locked.pdf": "/d/locked.pdf: open /d/locked.pdf: permission denied"])
        let (shown, notRead) = changes.separatingUnread(unread)
        #expect(notRead == [RemovedItem(path: "/d/locked.pdf", isDirectory: false, reason: "permission denied")])
        #expect(shown.removed == ["/d/gone"])
        #expect(shown.summary(since: previous, notRead: notRead.count) == "Since \(since), in this folder: 1 removed, 1 not read")
        #expect(RemovedNames(notRead, label: "Not read: ").line == "Not read: locked.pdf")
        // Only what it could not read: the line says so, and no "Removed:".
        let (onlyUnread, one) = FolderChanges(removed: ["/d/locked.pdf"]).separatingUnread(unread)
        #expect(onlyUnread.removedNames == nil)
        #expect(onlyUnread.summary(since: previous, notRead: one.count) == "Since \(since), in this folder: 1 not read")
        // Nothing unread: nothing moves.
        #expect(changes.separatingUnread(UnreadItems()).changes == changes)
    }

    @Test("a folder restic could not read holds everything in it, by the path's bytes")
    func unreadFolderHoldsItsContents() {
        let line = "/d/private: open /d/private: operation not permitted"
        let unread = UnreadItems(lines: ["/d/private": line])
        #expect(unread.item(holding: "/d/private/x.txt")?.path == "/d/private")
        #expect(unread.item(holding: "/d/private/")?.line == line)
        #expect(unread.reason(for: "/d/private/sub/y") == "blocked by macOS")
        #expect(unread.item(holding: "/d/privateer") == nil)
        #expect(unread.item(holding: "/d") == nil)
        #expect(UnreadItems(lines: ["/d/caf\u{E9}": line]).item(holding: "/d/cafe\u{301}") == nil)
    }

    @MainActor
    @Test("a backup's unread items come from its own run, by path")
    func unreadItemsFromTheRun() {
        let suite = "SwiftResticUnreadItemsTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("SwiftResticUnread-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults
        )
        var run = RunRecord(kind: .backup, planID: UUID(), planName: "Documents")
        run.outcome = .completedWithErrors
        run.snapshotID = "feedface00000000"
        let line = "/d/locked.pdf: open /d/locked.pdf: permission denied"
        run.itemErrors = [line]
        run.itemErrorCount = 1
        run.unreadableItemPaths = [line: "/d/locked.pdf"]
        model.append(record: run)
        #expect(model.unreadItems(inBackup: "feedface00000000") == UnreadItems(lines: ["/d/locked.pdf": line]))
        #expect(model.unreadItems(inBackup: "0000000000000000") == UnreadItems())
    }

    @Test("what is gone is named, and each listed child wears its mark by its path's bytes")
    func removedAndMarks() {
        let changes = FolderChanges(added: ["/d/new"], removed: ["/d/a", "/d/b"], modified: ["/d/caf\u{E9}"], uncertain: ["/d/u"])
        #expect(changes.removedNames == "Removed: a, b")
        #expect(FolderChanges(added: ["/d/x"]).removedNames == nil)
        // The first three, each with its kind, are the line's routes.
        var many = FolderChanges(removed: ["/d/a", "/d/b", "/d/c", "/d/d"])
        many.removedFolders = [PathKey("/d/b")]
        let names = RemovedNames(many.removedItems)
        #expect(names.items == [
            RemovedItem(path: "/d/a", isDirectory: false), RemovedItem(path: "/d/b", isDirectory: true),
            RemovedItem(path: "/d/c", isDirectory: false),
        ])
        #expect(names.more == 1)
        #expect(names.line == "Removed: a, b, c, and 1 more")
        #expect(RemovedNames(changes.removedItems).line == "Removed: a, b")
        #expect(changes.marks == [
            PathKey("/d/new"): "Added", PathKey("/d/caf\u{E9}"): "Modified", PathKey("/d/u"): "May have changed",
        ])
        // The other spelling of the same name is another file, unmarked.
        #expect(changes.marks[PathKey("/d/cafe\u{301}")] == nil)
    }
}
