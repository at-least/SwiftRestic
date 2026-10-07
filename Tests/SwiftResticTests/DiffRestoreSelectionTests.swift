import Foundation
import Testing

/// The Compare sheet's Restore Selected…: which rows restore, from which of
/// the two backups, and what the destination sheet says about the rest.
@Suite("Compare sheet selection restore")
struct DiffRestoreSelectionTests {
    private func snapshot(_ id: String, time: String) throws -> Snapshot {
        let json = #"{"id":"\#(id)","time":"\#(time)","paths":["/src"],"tags":[]}"#
        return try ResticMessageDecoder.jsonDecoder.decode(Snapshot.self, from: Data(json.utf8))
    }

    @Test("each row restores from the backup that has it; a folder brings the rows inside it from its own backup only")
    func plan() throws {
        let older = try snapshot("a1", time: "2026-09-01T02:00:00Z")
        let newer = try snapshot("a2", time: "2026-09-02T02:00:00Z")
        let holder = { (change: ResticDiffChange) in change.holder(newer: newer, older: older) }
        // Last night's backup dropped a folder and a file elsewhere, and
        // changed a third.
        let gone = ResticDiffChange(path: "/src/sub/", modifier: "-")
        let goneInside = ResticDiffChange(path: "/src/sub/x.txt", modifier: "-")
        let checklist = ResticDiffChange(path: "/src/onboarding-checklist.txt", modifier: "-")
        let changed = ResticDiffChange(path: "/src/notes.txt", modifier: "M")

        let (items, note) = DiffRestoreSelection.plan([gone, goneInside, checklist, changed], holder: holder)
        #expect(items.map(\.path) == ["/src/sub", "/src/onboarding-checklist.txt", "/src/notes.txt"])
        #expect(items.map(\.backup.id) == ["a1", "a1", "a2"])
        #expect(note == "“x.txt” is inside “sub” and is restored with it.")

        // A folder of the newer backup does not hold what that backup
        // removed: the removed file restores on its own, from the older.
        let folderNow = ResticDiffChange(path: "/src/docs/", modifier: "M")
        let removedInside = ResticDiffChange(path: "/src/docs/old.txt", modifier: "-")
        let (mixed, mixedNote) = DiffRestoreSelection.plan([folderNow, removedInside], holder: holder)
        #expect(mixed.map(\.path) == ["/src/docs", "/src/docs/old.txt"])
        #expect(mixed.map(\.backup.id) == ["a2", "a1"])
        #expect(mixedNote == nil)

        // A row whose backup is no longer listed is left out.
        let (listed, _) = DiffRestoreSelection.plan([checklist, changed]) { $0 == changed ? newer : nil }
        #expect(listed.map(\.path) == ["/src/notes.txt"])
    }
}
