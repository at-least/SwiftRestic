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
    private func node(_ path: String, kind: SnapshotNode.Kind = .file, size: Int64? = 1, mtime: Date? = nil) -> CachedListingNode {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return CachedListingNode(
            SnapshotNode(name: name, type: kind, path: path, size: size, mtime: mtime)
        )
    }

    @Test("the coordinator serves a cache hit already in browser order")
    func coordinatorSortsCachedListing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticBrowseCache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = IndexCoordinator(directory: directory)
        let repository = UUID()

        // Captured in no particular order: Finder order is the browser's row
        // order, and a hit must arrive in it. Sorting on the main actor is
        // the cache-hit path paying localizedStandardCompare over a whole
        // directory exactly when it exists to be instant — the live listing
        // already sorts off-main inside the service.
        await coordinator.cacheListing(
            snapshotID: "s1", directory: "/src",
            nodes: [
                node("/src/b.txt").snapshotNode,
                node("/src/Zeta", kind: .dir, size: nil).snapshotNode,
                node("/src/a.txt").snapshotNode,
                node("/src/alpha", kind: .dir, size: nil).snapshotNode,
            ],
            repositoryID: repository
        )

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
