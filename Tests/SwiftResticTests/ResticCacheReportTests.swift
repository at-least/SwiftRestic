import Foundation
import Testing

@Suite("restic cache report")
struct ResticCacheReportTests {
    /// `restic cache` on 0.19.1: the table with sizes, two rows past 30 days.
    let withSizes = """
    Repo ID     Last Used    Old  Size
    ------------------------------------------
    88fad9a63b  41 days ago  yes  1.500 KiB
    a28001217f  33 days ago  yes  2.737 MiB
    0c66271f29   0 days ago       1.000 GiB
    ------------------------------------------
    3 cache dirs in /Users/me/Library/Caches/restic
    """

    @Test("the table's rows are counted with their sizes, the old ones apart, and the directory is the last line's")
    func parsesTable() {
        let report = ResticCacheReport.parse(withSizes)
        #expect(report == ResticCacheReport(
            directory: "/Users/me/Library/Caches/restic",
            count: 3,
            oldCount: 2,
            totalBytes: 1536 + 2_869_953 + 1_073_741_824
        ))
    }

    @Test("--no-size rows, a directory with spaces, and an empty cache still parse; anything else does not")
    func edges() {
        let noSize = """
        Repo ID     Last Used    Old
        ----------------------------
        88fad9a63b   1 days ago  yes
        0c66271f29   0 days ago
        ----------------------------
        2 cache dirs in /Volumes/My Disk/caches/restic
        """
        #expect(ResticCacheReport.parse(noSize) == ResticCacheReport(
            directory: "/Volumes/My Disk/caches/restic", count: 2, oldCount: 1, totalBytes: 0
        ))
        // An empty cache, as restic 0.19.1 prints it (no table, no count line).
        #expect(ResticCacheReport.parse("no cache dirs found, basedir is /Users/me/Library/Caches/restic")
            == ResticCacheReport(directory: "/Users/me/Library/Caches/restic", count: 0, oldCount: 0, totalBytes: 0))
        #expect(ResticCacheReport.parse("no old cache dirs found") == nil)
        #expect(ResticCacheReport.parse("") == nil)
    }

    @Test("the caption's last sentence counts the unused folders, and says an empty cache is empty")
    func unusedLine() {
        let empty = ResticCacheReport(directory: "/c", count: 0, oldCount: 0, totalBytes: 0)
        #expect(AppModel.unusedLine(empty) == "Nothing is cached yet.")
        let fresh = ResticCacheReport(directory: "/c", count: 4, oldCount: 0, totalBytes: 1_000)
        #expect(AppModel.unusedLine(fresh) == "None has gone unused for 30 days.")
        let one = ResticCacheReport(directory: "/c", count: 4, oldCount: 1, totalBytes: 1_000)
        #expect(AppModel.unusedLine(one) == "1 has not been used for 30 days.")
        let many = ResticCacheReport(directory: "/c", count: 5, oldCount: 3, totalBytes: 1_000)
        #expect(AppModel.unusedLine(many) == "3 have not been used for 30 days.")
    }

    @Test("the cleanup note counts what the two reports differ by, or says nothing was old enough")
    func cleanupNote() {
        let before = ResticCacheReport(directory: "/c", count: 5, oldCount: 3, totalBytes: 10_000_000)
        let after = ResticCacheReport(directory: "/c", count: 2, oldCount: 0, totalBytes: 1_000_000)
        #expect(AppModel.cleanupNote(before: before, after: after) == "Removed 3 folders, 9 MB.")
        #expect(AppModel.cleanupNote(before: after, after: after) == "Nothing was unused for 30 days.")
    }

    @Test("a new measurement drops the last cleanup's note, which speaks of a report no longer shown")
    @MainActor
    func measurementDropsTheNote() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResticCacheNote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        model.resticCacheNote = "Removed 3 folders, 9 MB."
        // No restic found: the measurement fails, and the note goes all the same.
        await model.measureResticCache()
        #expect(model.resticCacheNote == nil)
    }

    @Test("a cleanup with no cache measured does nothing")
    @MainActor
    func cleanupWithoutAMeasurementDoesNothing() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResticCacheCleanup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        await model.cleanupResticCache()
        #expect(model.resticCache == nil)
        #expect(model.resticCacheNote == nil)
        #expect(!model.isWorkingOnResticCache)
    }

    @Test("a cleanup with no restic found fails and drops the note about a cleanup that did not happen")
    @MainActor
    func cleanupWithoutResticFailsAndDropsTheNote() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResticCacheCleanupFail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        model.resticCacheNote = "Removed 3 folders, 9 MB."
        model.resticCache = .measured(ResticCacheReport(directory: "/c", count: 3, oldCount: 3, totalBytes: 1_000))
        await model.cleanupResticCache()
        guard case .failed = model.resticCache else {
            Issue.record("expected a failed cleanup, got \(String(describing: model.resticCache))")
            return
        }
        #expect(model.resticCacheNote == nil)
    }

    @Test("a cleanup removes the old folders, measures again, and the note counts what went")
    @MainActor
    func cleanupRemovesAndSaysWhatWent() async throws {
        // A stub restic: `cache --cleanup` touches a marker beside itself,
        // and `cache` answers the three-row table before the marker and the
        // one-fresh-row table after it — 2 folders and their bytes gone.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResticCacheCleanupRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("restic")
        try """
        #!/bin/sh
        if [ "$2" = "--cleanup" ]; then
          touch "$(dirname "$0")/cleaned"
          exit 0
        fi
        if [ -e "$(dirname "$0")/cleaned" ]; then
          cat "$(dirname "$0")/after.txt"
        else
          cat "$(dirname "$0")/before.txt"
        fi
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let after = """
        Repo ID     Last Used    Old  Size
        ------------------------------------------
        0c66271f29   0 days ago       1.000 GiB
        ------------------------------------------
        1 cache dirs in /Users/me/Library/Caches/restic
        """
        try withSizes.write(to: root.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
        try after.write(to: root.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)

        let model = AppModel(store: ConfigStore(directory: root.appendingPathComponent("config")), secrets: .inMemory())
        model.resticSearch = .found(ResticBinary(url: stub), version: "restic 0.19.1")
        await model.measureResticCache()
        guard case let .measured(before) = model.resticCache else {
            Issue.record("the measurement failed: \(String(describing: model.resticCache))")
            return
        }
        #expect(before == ResticCacheReport(
            directory: "/Users/me/Library/Caches/restic", count: 3, oldCount: 2, totalBytes: 1536 + 2_869_953 + 1_073_741_824
        ))

        await model.cleanupResticCache()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("cleaned").path), "the cleanup never ran")
        #expect(model.resticCache == .measured(ResticCacheReport(
            directory: "/Users/me/Library/Caches/restic", count: 1, oldCount: 0, totalBytes: 1_073_741_824
        )))
        #expect(model.resticCacheNote == "Removed 2 folders, \(Format.bytes(1_536 + 2_869_953)).")
    }

    @Test("restic's binary units convert to bytes; an unknown unit is refused")
    func units() {
        #expect(ResticCacheReport.bytes(value: "512", unit: "B") == 512)
        #expect(ResticCacheReport.bytes(value: "1.000", unit: "KiB") == 1024)
        #expect(ResticCacheReport.bytes(value: "2.737", unit: "MiB") == 2_869_953)
        #expect(ResticCacheReport.bytes(value: "1.000", unit: "GiB") == 1_073_741_824)
        #expect(ResticCacheReport.bytes(value: "0.001", unit: "TiB") == 1_099_511_628)
        #expect(ResticCacheReport.bytes(value: "2", unit: "MB") == nil)
        #expect(ResticCacheReport.bytes(value: "x", unit: "MiB") == nil)
    }
}
