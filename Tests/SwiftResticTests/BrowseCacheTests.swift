import Foundation
import Testing

/// The browse caches — one directory's `restic ls` answer and one `restic
/// diff`, stored verbatim per immutable content key. The contract under
/// test: a capture meets its lookup whatever spelling the caller used, an
/// explicit empty listing is a hit and not a miss, a repeated capture does
/// not overwrite, and a snapshot's death sweeps its rows in the same
/// transaction that declares the death.
@Suite("browse caches")
struct BrowseCacheTests {
    private func makeStore() throws -> SQLiteIndexStore {
        try SQLiteIndexStore(path: nil)
    }

    private func snapshot(_ id: String, time: Date) -> Snapshot {
        let document: [String: Any] = [
            "id": id,
            "short_id": String(id.prefix(8)),
            "time": time.timeIntervalSince1970,
            "paths": ["/data"],
            "tags": [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try! decoder.decode(Snapshot.self, from: data)
    }

    private func node(_ path: String, kind: SnapshotNode.Kind = .file, size: Int64? = 1, mtime: Date? = nil) -> CachedListingNode {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return CachedListingNode(
            SnapshotNode(name: name, type: kind, path: path, size: size, mtime: mtime)
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    @Test("a captured listing round-trips with kind, size and mtime intact")
    func listingRoundTrip() throws {
        let store = try makeStore()
        let mtime = Date(timeIntervalSince1970: 5_000)
        let captured: [CachedListingNode] = [
            node("/src/notes.txt", size: 42, mtime: mtime),
            node("/src/loop", kind: .symlink, size: nil),
            node("/src/sub", kind: .dir, size: nil),
        ]
        try store.recordListing(snapshotID: "s1", directory: "/src", nodes: captured)

        guard let read = try store.listing(snapshotID: "s1", directory: "/src") else {
            Issue.record("the captured listing missed")
            return
        }
        #expect(read == captured)
        let restored = read.map(\.snapshotNode)
        #expect(restored[0].name == "notes.txt")
        #expect(restored[0].size == 42)
        #expect(restored[0].mtime == mtime)
        #expect(restored[1].type == .symlink)
        #expect(restored[2].type == .dir)
    }

    @Test("an empty directory is a hit, not a miss, and the key is canonical")
    func emptyListingAndCanonicalKey() throws {
        let store = try makeStore()
        try store.recordListing(snapshotID: "s1", directory: "/src/empty/", nodes: [])

        // The trailing slash in the capture spelling must not hide the row.
        #expect(try store.listing(snapshotID: "s1", directory: "/src/empty") == [])
        #expect(try store.listing(snapshotID: "s1", directory: "/src/empty/") == [])
        // The root keeps its slash; other spellings still meet it.
        try store.recordListing(snapshotID: "s1", directory: "/", nodes: [node("/bin")])
        #expect(try store.listing(snapshotID: "s1", directory: "/")?.count == 1)
        // Nothing captured elsewhere.
        #expect(try store.listing(snapshotID: "s1", directory: "/src") == nil)
        #expect(try store.listing(snapshotID: "other", directory: "/src/empty") == nil)
    }

    @Test("a repeated capture never overwrites: the first verbatim answer stands")
    func firstCaptureWins() throws {
        let store = try makeStore()
        let first = [node("/src/a.txt")]
        let second = [node("/src/b.txt")]
        try store.recordListing(snapshotID: "s1", directory: "/src", nodes: first)
        try store.recordListing(snapshotID: "s1", directory: "/src", nodes: second)
        #expect(try store.listing(snapshotID: "s1", directory: "/src") == first)
    }

    @Test("a captured diff round-trips; unknown pairs miss")
    func diffRoundTrip() throws {
        let store = try makeStore()
        let changes = [
            CachedDiffChange(ResticDiffChange(path: "/src/new.txt", modifier: "+")),
            CachedDiffChange(ResticDiffChange(path: "/src/gone.txt", modifier: "-")),
            CachedDiffChange(ResticDiffChange(path: "/src/moved/", modifier: "TU")),
        ]
        try store.recordDiff(olderID: "s1", newerID: "s2", changes: changes)

        guard let read = try store.diff(olderID: "s1", newerID: "s2") else {
            Issue.record("the captured diff missed")
            return
        }
        #expect(read.map(\.resticDiffChange) == changes.map(\.resticDiffChange))
        #expect(read[2].resticDiffChange.category == .modified)
        #expect(try store.diff(olderID: "s2", newerID: "s1") == nil)
        #expect(try store.diff(olderID: "s1", newerID: "s3") == nil)
    }

    @Test("a snapshot's death sweeps its listings and every diff that names it")
    func deathSweepsCacheRows() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0),
            snapshot("s2", time: t1),
        ])
        try store.recordListing(snapshotID: "s1", directory: "/src", nodes: [node("/src/a.txt")])
        try store.recordListing(snapshotID: "s2", directory: "/src", nodes: [node("/src/b.txt")])
        try store.recordDiff(olderID: "s1", newerID: "s2", changes: [])

        let died = try store.reconcile(aliveSnapshots: [snapshot("s2", time: t1)])
        #expect(died.died == ["s1"])
        #expect(try store.listing(snapshotID: "s1", directory: "/src") == nil)
        #expect(try store.diff(olderID: "s1", newerID: "s2") == nil)
        // The survivor keeps both its listing and its diffs to still-alive pairs.
        #expect(try store.listing(snapshotID: "s2", directory: "/src") != nil)

        // Revival is free but starts from an empty cache: the rows were
        // reclaimed, so the next browse goes to restic once and re-captures.
        let revived = try store.reconcile(aliveSnapshots: [
            snapshot("s1", time: t0),
            snapshot("s2", time: t1),
        ])
        #expect(revived.revived == ["s1"])
        #expect(try store.listing(snapshotID: "s1", directory: "/src") == nil)
    }

    @Test("cache rows naming an ID the index never held alive are swept too")
    func unknownIDSweep() throws {
        let store = try makeStore()
        _ = try store.reconcile(aliveSnapshots: [snapshot("s2", time: t1)])
        try store.recordListing(snapshotID: "s2", directory: "/src", nodes: [node("/src/b.txt")])
        // A browse that raced a forget: the listing lands for an ID the
        // snapshot table does not hold alive — captured here as "never seen".
        try store.recordListing(snapshotID: "ghost", directory: "/src", nodes: [node("/src/a.txt")])
        try store.recordDiff(olderID: "ghost", newerID: "s2", changes: [])

        _ = try store.reconcile(aliveSnapshots: [snapshot("s2", time: t1)])
        #expect(try store.listing(snapshotID: "ghost", directory: "/src") == nil)
        #expect(try store.diff(olderID: "ghost", newerID: "s2") == nil)
        #expect(try store.listing(snapshotID: "s2", directory: "/src") != nil)
    }

    @Test("the coordinator serves the caches per repository and canonicalizes lookups")
    func coordinatorPassThrough() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticBrowseCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = IndexCoordinator(directory: directory)

        let captured = [node("/src/a.txt")]
        let repository = UUID()
        await coordinator.cacheListing(snapshotID: "s1", directory: "/src", nodes: captured.map(\.snapshotNode), repositoryID: repository)
        // Stores are per repository: another repository's cache never sees
        // this row, even though the lazy store creation means both have a file.
        #expect(await coordinator.cachedListing(snapshotID: "s1", directory: "/src", repositoryID: UUID()) == nil)

        let read = await coordinator.cachedListing(snapshotID: "s1", directory: "/src/", repositoryID: repository)
        #expect(read == captured)

        let changes = [CachedDiffChange(ResticDiffChange(path: "/src/new.txt", modifier: "+"))]
        await coordinator.cacheDiff(olderID: "s1", newerID: "s2", changes: changes.map(\.resticDiffChange), repositoryID: repository)
        #expect(
            await coordinator.cachedDiff(olderID: "s1", newerID: "s2", repositoryID: repository)?.map(\.resticDiffChange)
                == changes.map(\.resticDiffChange)
        )
    }
}
