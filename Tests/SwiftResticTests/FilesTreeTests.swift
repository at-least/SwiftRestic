import Foundation
import Testing

@MainActor
@Suite("a chain's items: identity, standing and search hits")
struct FilesTreeTests {
    private let repositoryID = UUID()
    private let chain = "swiftrestic-plan-aaaa"

    private func node(_ path: String, folder: Bool = true) -> FileNode {
        FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: folder)
    }

    private func entry(_ node: FileNode, _ standing: FilesTree.Standing = .onDisk) -> FilesTree.Entry {
        FilesTree.Entry(node: node, standing: standing)
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

    @Test("a search's hits list by name as Finder sorts names, one name's by path, each the tree row it selects, dimmed when no longer on this Mac")
    func searchHitsOrder() {
        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let day = IndexVersion(id: "s1", time: .now)
        let hits = [
            IndexChild(path: "/Docs/b/note10", isDirectory: false, newest: day, isInNewest: true),
            IndexChild(path: "/Docs/a/note2", isDirectory: false, newest: day, isInNewest: false),
            IndexChild(path: "/Docs/b/note2", isDirectory: false, newest: day, isInNewest: true),
            IndexChild(path: "/Docs/Notes", isDirectory: true, newest: day, isInNewest: true),
        ]
        let present: Set<PathKey> = ["/Docs/b/note10", "/Docs/b/note2", "/Docs/Notes"]
        let entries = FilesSearchAnswer.entries(hits, under: roots, present: present)
        // note2 before note10, numbers as numbers; no folders-first.
        #expect(entries.map(\.node.path) == ["/Docs/a/note2", "/Docs/b/note2", "/Docs/b/note10", "/Docs/Notes"])
        // A hit is the very node the tree lists, so picking it selects that
        // row's item; the one the disk no longer has is deleted.
        #expect(entries[0] == FilesTree.Entry(node: node("/Docs/a/note2", folder: false), standing: .deleted(lastBackedUp: day)))
        #expect(entries[1].standing == .onDisk)
        #expect(entries[3].node == node("/Docs/Notes"))
    }

    @Test("each standing has its words: a hit's tag and tooltip, VoiceOver's, and the pane's")
    func standingWords() {
        let when = Date(timeIntervalSince1970: 1_790_904_600)
        let stamp = Format.timestamp(when)
        let here = entry(node("/Docs/a.txt", folder: false))
        #expect(here.tag == nil)
        #expect(here.help == "/Docs/a.txt")
        #expect(here.spokenStanding == nil)

        #expect(FilesTree.Entry.notBackedUpReason(notRead: nil) == "No backup of this plan holds it")
        #expect(FilesTree.Entry.notBackedUpReason(notRead: "permission denied") == "The newest backup couldn’t read it (permission denied)")

        let gone = entry(node("/Docs/old.txt", folder: false), .deleted(lastBackedUp: IndexVersion(id: "s1", time: when)))
        #expect(gone.tag == Format.until(when))
        #expect(gone.help == "Not on this Mac — last backed up \(stamp)")
        #expect(gone.spokenStanding == "not on this Mac, last backed up \(stamp)")

        // On this Mac, but missing from the newest backup an older one is
        // not: the pane's line.
        #expect(FilesTree.Entry.standing(notRead: nil, lastBackedUp: when) == "Not in the newest backup — last backed up \(stamp)")
        #expect(FilesTree.Entry.standing(notRead: "permission denied", lastBackedUp: when)
            == "Not read by the newest backup (permission denied) — last backed up \(stamp)")
    }

    @Test("a search's footer says the ceiling first, then the index still reading, else nothing")
    func searchHitsNote() {
        #expect(FilesSearchAnswer.note(isTruncated: false, isComplete: true) == nil)
        #expect(FilesSearchAnswer.note(isTruncated: false, isComplete: false) == FilesSearchAnswer.searchStillReading)
        #expect(FilesSearchAnswer.note(isTruncated: true, isComplete: false)
            == "Not every match is shown — narrow the search to see the rest.")
    }

    @Test("a hit's folder line is read from the folder holding the plan's root, deepest holder winning, by bytes")
    func folderLines() {
        let documents = FileNode(repositoryID: repositoryID, chainKey: chain, path: "/Users/me/Documents", isDirectory: true)
        // Computed, not written: tilde abbreviation is against this Mac's home.
        let tilde = { (path: String) in (path as NSString).abbreviatingWithTildeInPath }

        // Under the root's parent: the part that tells the hits apart.
        #expect(FilesSearchAnswer.folderLine(for: "/Users/me/Documents/reports/a.txt", under: [documents]) == "Documents/reports")
        #expect(FilesSearchAnswer.folderLine(for: "/Users/me/Documents/a.txt", under: [documents]) == "Documents")
        // The root itself sits at its parent — no shorter line exists.
        #expect(FilesSearchAnswer.folderLine(for: "/Users/me/Documents", under: [documents]) == tilde("/Users/me"))
        #expect(FilesSearchAnswer.folderLine(for: "/Volumes/Elsewhere/x.txt", under: [documents]) == tilde("/Volumes/Elsewhere"))

        // Two roots, one inside the other: the deepest holder wins, so the
        // prefix they share cannot eat the line.
        let work = FileNode(repositoryID: repositoryID, chainKey: chain, path: "/Users/me/Documents/Work", isDirectory: true)
        #expect(FilesSearchAnswer.folderLine(for: "/Users/me/Documents/Work/oct/x.txt", under: [documents, work]) == "Work/oct")

        // By bytes (`ResticPath`): an NFC root and an NFD hit are two
        // spellings, never folded together.
        let nfc = FileNode(repositoryID: repositoryID, chainKey: chain, path: "/Users/me/Doc\u{e9}", isDirectory: true)
        #expect(FilesSearchAnswer.folderLine(for: "/Users/me/Doce\u{301}/a.txt", under: [nfc]) == tilde("/Users/me/Doce\u{301}"))
    }
}

