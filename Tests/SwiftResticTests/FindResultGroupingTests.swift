import Foundation
import Testing

@Suite("Search results by path")
struct FindResultGroupingTests {
    @Test("a search's rows are newest first by their newest version, ties keeping the search's order")
    func indexRowsOrder() {
        let old = IndexVersion(id: "old", time: Date(timeIntervalSince1970: 1_000))
        let new = IndexVersion(id: "new", time: Date(timeIntervalSince1970: 2_000))
        let hits = [SearchHit(path: "/d/a.txt", isDirectory: false), SearchHit(path: "/d/b.txt", isDirectory: false)]
        let built = FindResultGrouping.indexRows(
            hits: hits,
            summaries: [
                PathKey("/d/a.txt"): VersionSummary(count: 2, newest: old),
                PathKey("/d/b.txt"): VersionSummary(count: 5, newest: new),
            ]
        )
        #expect(built.rows.map(\.snapshotID) == ["new", "old"])
        #expect(built.dropped == 0)

        // Equal times keep the search's own order (name, then path), so ties
        // never shuffle between searches.
        let tied = FindResultGrouping.indexRows(
            hits: hits.reversed(),
            summaries: [
                PathKey("/d/a.txt"): VersionSummary(count: 1, newest: new),
                PathKey("/d/b.txt"): VersionSummary(count: 1, newest: new),
            ]
        )
        #expect(tied.rows.map(\.match.path) == ["/d/b.txt", "/d/a.txt"])
    }

    @Test("a search's rows carry the hit and the summary's facts; a hit without its summary is dropped, not a row")
    func indexRowsFacts() {
        let newest = IndexVersion(id: "s9", time: Date(timeIntervalSince1970: 3_000))
        let folder = SearchHit(path: "/d/Sub", isDirectory: true)
        let file = SearchHit(path: "/d/a.txt", isDirectory: false)
        let built = FindResultGrouping.indexRows(
            hits: [folder, file, SearchHit(path: "/d/gone.txt", isDirectory: false)],
            summaries: [
                PathKey("/d/Sub"): VersionSummary(count: 3, newest: newest),
                PathKey("/d/a.txt"): VersionSummary(count: 7, newest: newest),
            ]
        )
        #expect(built.dropped == 1, "a hit without its summary reads as a truncated list, not silence")
        #expect(built.rows.count == 2)
        let byPath = Dictionary(uniqueKeysWithValues: built.rows.map { ($0.match.path, $0) })
        #expect(byPath["/d/Sub"]?.match.type == .dir)
        #expect(byPath["/d/a.txt"]?.match.type == .file)
        #expect(byPath["/d/Sub"]?.count == 3)
        #expect(byPath["/d/a.txt"]?.count == 7)
        #expect(built.rows.allSatisfy { $0.snapshotID == "s9" && $0.snapshotTime == newest.time })
        #expect(byPath["/d/a.txt"]?.hit == file)
        #expect(byPath["/d/Sub"]?.match.size == nil && byPath["/d/Sub"]?.match.mtime == nil)
    }
}

@Suite("Search All Backups")
struct AllBackupsSearchTests {
    private func row(_ path: String, at seconds: TimeInterval) -> FindResultGrouping.IndexRow {
        FindResultGrouping.IndexRow(
            match: FindMatch(path: path, type: .file, size: nil, mtime: nil),
            snapshotID: "s\(Int(seconds))",
            snapshotTime: Date(timeIntervalSince1970: seconds),
            count: 2,
            hit: SearchHit(path: path, isDirectory: false)
        )
    }

    @Test("every repository's rows merge newest first, one path in two repositories being two rows")
    func merge() {
        let (home, nas) = (UUID(), UUID())
        let search = AllBackupsSearch([
            .init(repositoryID: home, outcome: .rows([row("/a", at: 100), row("/b", at: 300)], isTruncated: false, isComplete: true)),
            .init(repositoryID: nas, outcome: .rows([row("/a", at: 200)], isTruncated: false, isComplete: true)),
        ])
        #expect(search.rows.map(\.path) == ["/b", "/a", "/a"])
        #expect(search.rows.map(\.repositoryID) == [home, nas, home])
        #expect(Set(search.rows.map(\.id)).count == 3)
        #expect(search.isWhole)
        #expect(!search.isTruncated)
    }

    @Test("what couldn’t be covered is said by repository, and never takes the others' rows with it")
    func partial() {
        let (reading, broken, whole) = (UUID(), UUID(), UUID())
        let search = AllBackupsSearch([
            .init(repositoryID: reading, outcome: .rows([], isTruncated: false, isComplete: false)),
            .init(repositoryID: broken, outcome: .failed("database disk image is malformed")),
            .init(repositoryID: whole, outcome: .rows([row("/a", at: 100)], isTruncated: true, isComplete: true)),
        ])
        #expect(search.rows.map(\.path) == ["/a"])
        #expect(search.stillReading == [reading])
        #expect(search.failures == [.init(repositoryID: broken, message: "database disk image is malformed")])
        #expect(!search.isWhole, "a short list must not pass for the whole answer")
        #expect(search.isTruncated)
    }
}
