import Foundation
import Testing
@testable import SwiftRestic

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
