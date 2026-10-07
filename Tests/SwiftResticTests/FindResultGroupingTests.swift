import Foundation
import Testing

/// Find Files' restic engine, read the way the index engine reads: one row
/// per path at the newest backup holding it, counting the backups that do.
@Suite("Find results by path")
struct FindResultGroupingTests {
    private func result(_ snapshot: String, _ paths: [String]) throws -> FindResult {
        let matches = paths.map { #"{"path":"\#($0)","type":"file","size":3}"# }.joined(separator: ",")
        return try JSONDecoder().decode(
            FindResult.self,
            from: Data(#"{"matches":[\#(matches)],"hits":\#(paths.count),"snapshot":"\#(snapshot)"}"#.utf8)
        )
    }

    @Test("a path found in several backups is one row, at the newest, with how many hold it")
    func onePerPath() throws {
        let day = { (d: Double) in Date(timeIntervalSince1970: 1_790_000_000 + d * 86_400) }
        let times = ["s1": day(1), "s2": day(2), "s3": day(3)]
        let rows = FindResultGrouping.rows(
            [
                try result("s1", ["/d/notes.txt", "/d/old/notes.txt"]),
                try result("s3", ["/d/notes.txt"]),
                try result("s2", ["/d/notes.txt", "/d/cafe\u{301}/notes.txt"]),
            ],
            times: times
        )
        #expect(rows.map(\.match.path) == ["/d/notes.txt", "/d/cafe\u{301}/notes.txt", "/d/old/notes.txt"])
        #expect(rows.map(\.snapshotID) == ["s3", "s2", "s1"])
        #expect(rows.map(\.count) == [3, 1, 1])
        // Another spelling of the same name is another path.
        let spellings = FindResultGrouping.rows(
            [try result("s1", ["/d/caf\u{E9}", "/d/cafe\u{301}"])], times: times
        )
        #expect(spellings.count == 2)
        // A backup the listing no longer has sorts last, never first.
        let unknown = FindResultGrouping.rows(
            [try result("gone", ["/d/x"]), try result("s1", ["/d/y"])], times: times
        )
        #expect(unknown.map(\.snapshotID) == ["s1", "gone"])
    }
}
