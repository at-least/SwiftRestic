import Foundation
import Testing

@MainActor
@Suite("a chain's items: identity and standing")
struct FilesTreeTests {
    private let repositoryID = UUID()
    private let chain = "swiftrestic-plan-aaaa"

    private func node(_ path: String, folder: Bool = true) -> FileNode {
        FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: folder)
    }


    @Test("FileNode's identity is the repository, chain, path bytes and kind; the roots level is no path")
    func fileNodeIdentity() {
        // NFC and NFD spellings of one name: one String to Swift, two paths
        // to restic, two rows here.
        #expect(node("/caf\u{E9}") != node("/cafe\u{301}"))
        #expect(node("/a") != node("/a", folder: false))
        #expect(node("/a") == node("/a"))
        #expect(FileNode.roots(repositoryID: repositoryID, chainKey: chain).isRoots)
        #expect(!node("/a").isRoots)
        #expect(node("/a/b.txt", folder: false).name == "b.txt")
    }

    @Test("a path becomes a find pattern matching only itself: glob characters and the escape escaped, scalar by scalar")
    func globEscaping() {
        #expect(ResticService.globEscaped("/d/a[1].txt") == #"/d/a\[1].txt"#)
        #expect(ResticService.globEscaped("/d/b*c?.txt") == #"/d/b\*c\?.txt"#)
        #expect(ResticService.globEscaped(#"/d/back\slash"#) == #"/d/back\\slash"#)
        #expect(ResticService.globEscaped("/d/plain.txt") == "/d/plain.txt")
        // A combining mark after "[" makes one Character of the two; the
        // bracket is still escaped.
        #expect(ResticService.globEscaped("/d/[\u{301}x") == "/d/\\[\u{301}x")
    }

    @Test("ResticPath.parent cuts at the last separator, the root's children under /")
    func parentPaths() {
        #expect(ResticPath.parent(of: "/a/b/c") == "/a/b")
        #expect(ResticPath.parent(of: "/a") == "/")
        #expect(ResticPath.parent(of: "a") == "a")
        // In the scalar view: a Prepend character before the slash stays.
        #expect(ResticPath.parent(of: "/d\u{0600}/x") == "/d\u{0600}")
    }

    @Test("a listing's reconcile marks the generation taken only when the store took it and the repository is still configured")
    func takenGenerationFollowsTheStore() async throws {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let repository = namedRepository("NAS")
        model.configuration.repositories = [repository]
        model.indexReconcile(repositoryID: repository.id, listing: [], generation: 1)
        await model.tasks.drain()
        #expect(model.indexTakenGeneration[repository.id] == 1)

        // Removed while a refresh's reconcile was in flight: the removal
        // cleared the entry, and the reconcile that lands after must not
        // write it back — the store refused the listing, and UUIDs are
        // never reused, so nothing would clear it again.
        model.deleteRepository(id: repository.id)
        await model.tasks.drain()
        #expect(model.indexTakenGeneration[repository.id] == nil)
        model.indexReconcile(repositoryID: repository.id, listing: [], generation: 2)
        await model.tasks.drain()
        #expect(model.indexTakenGeneration[repository.id] == nil)
        await model.indexCoordinator.shutdown()
    }

    @Test("each standing has the versions pane's words")
    func standingWords() {
        let when = Date(timeIntervalSince1970: 1_790_904_600)
        let stamp = Format.timestamp(when)

        #expect(FileStandingWords.notBackedUpReason(notRead: nil) == "No backup of this plan holds it")
        #expect(FileStandingWords.notBackedUpReason(notRead: "permission denied") == "The newest backup couldn’t read it (permission denied)")

        #expect(FileStandingWords.standing(notRead: nil, lastBackedUp: when) == "Not in the newest backup — last backed up \(stamp)")
        #expect(FileStandingWords.standing(notRead: "permission denied", lastBackedUp: when)
            == "Not read by the newest backup (permission denied) — last backed up \(stamp)")
    }
}

