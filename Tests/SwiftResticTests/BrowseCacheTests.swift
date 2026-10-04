import Foundation
import Testing

/// The browse caches as the coordinator serves them — one directory's
/// `restic ls` answer and one `restic diff`, stored verbatim per immutable
/// content key. The store-level contract (spelling-proof keys, an empty
/// listing as a hit, first capture wins, deaths sweep their rows) is pinned
/// by `SnapshotIndexBrowseCacheTests`; what is left here is the coordinator's
/// part: per-repository stores, canonical lookups and browser row order.
@Suite("browse caches")
struct BrowseCacheTests {
    @Test("the coordinator serves a cache hit already in browser order")
    func coordinatorSortsCachedListing() async throws {
        let scene = try CoordinatorScene("SwiftResticBrowseCache")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let repository = scene.repositoryID

        // Captured in no particular order: Finder order is the browser's row
        // order, and a hit must arrive in it. Sorting on the main actor is
        // the cache-hit path paying localizedStandardCompare over a whole
        // directory exactly when it exists to be instant — the live listing
        // already sorts off-main inside the service.
        coordinator.cacheListing(
            snapshotID: "s1", directory: "/src",
            nodes: [
                IndexTestData.cachedNode("/src/b.txt").snapshotNode,
                IndexTestData.cachedNode("/src/Zeta", kind: .dir, size: nil).snapshotNode,
                IndexTestData.cachedNode("/src/a.txt").snapshotNode,
                IndexTestData.cachedNode("/src/alpha", kind: .dir, size: nil).snapshotNode,
            ],
            repositoryID: repository
        )
        await coordinator.cacheWritesSettled()

        let read = await coordinator.cachedBrowserListing(
            snapshotID: "s1", directory: "/src", repositoryID: repository
        )
        // Directories first, Finder-style: case-insensitive, so alpha sorts
        // ahead of Zeta.
        #expect(read?.map(\.name) == ["alpha", "Zeta", "a.txt", "b.txt"])

        // A miss stays a miss; the wrapper adds no hit of its own.
        #expect(await coordinator.cachedBrowserListing(
            snapshotID: "s9", directory: "/src", repositoryID: repository
        ) == nil)
    }

    @Test("the coordinator serves a file's nodes per repository, a miss as nothing")
    func coordinatorFileNodes() async throws {
        let scene = try CoordinatorScene("SwiftResticBrowseCache")
        defer { scene.remove() }
        let coordinator = scene.coordinator
        let node = IndexTestData.cachedNode("/src/a.txt", size: 42).snapshotNode

        coordinator.cacheFileNodes(["/src/a.txt": ["s1": node]], repositoryID: scene.repositoryID)
        await coordinator.cacheWritesSettled()
        let read = await coordinator.cachedFileNodes(
            path: "/src/a.txt", snapshotIDs: ["s1", "s2"], repositoryID: scene.repositoryID
        )
        // SnapshotNode's equality is its path: the size is checked itself.
        #expect(read == ["s1": node])
        #expect(read["s1"]?.size == 42)
        #expect(await coordinator.cachedFileNodes(path: "/src/a.txt", snapshotIDs: ["s1"], repositoryID: UUID()).isEmpty)
    }

    @Test("the coordinator serves the caches per repository and canonicalizes lookups")
    func coordinatorPassThrough() async throws {
        let scene = try CoordinatorScene("SwiftResticBrowseCache")
        defer { scene.remove() }
        let coordinator = scene.coordinator

        let captured = [IndexTestData.cachedNode("/src/a.txt")]
        let repository = scene.repositoryID
        coordinator.cacheListing(snapshotID: "s1", directory: "/src", nodes: captured.map(\.snapshotNode), repositoryID: repository)
        await coordinator.cacheWritesSettled()
        // Stores are per repository: another repository's cache never sees
        // this row, even though the lazy store creation means both have a file.
        #expect(await coordinator.cachedListing(snapshotID: "s1", directory: "/src", repositoryID: UUID()) == nil)

        let read = await coordinator.cachedListing(snapshotID: "s1", directory: "/src/", repositoryID: repository)
        #expect(read == captured)

        let changes = [CachedDiffChange(ResticDiffChange(path: "/src/new.txt", modifier: "+"))]
        coordinator.cacheDiff(olderID: "s1", newerID: "s2", changes: changes.map(\.resticDiffChange), repositoryID: repository)
        await coordinator.cacheWritesSettled()
        #expect(
            await coordinator.cachedDiff(olderID: "s1", newerID: "s2", repositoryID: repository)?.map(\.resticDiffChange)
                == changes.map(\.resticDiffChange)
        )
    }
}
