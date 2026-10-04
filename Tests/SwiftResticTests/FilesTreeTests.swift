import Foundation
import Testing

/// The Files view's sidebar rows, as the pure rule the tree lays out: a
/// level's entries, the open folders under them depth-first, a level not yet
/// read as one status row, and a folder past the row cap as its first
/// entries and one row that opens it.
@MainActor
@Suite("Files tree rows")
struct FilesTreeTests {
    private let repositoryID = UUID()
    private let chain = "swiftrestic-plan-aaaa"

    private func node(_ path: String, folder: Bool = true) -> FileNode {
        FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: folder)
    }

    private func entry(_ node: FileNode) -> FilesTree.Entry {
        FilesTree.Entry(node: node, newest: IndexVersion(id: "s1", time: .now), isInNewest: true)
    }

    private func level(_ nodes: [FileNode]) -> FilesTree.State {
        .loaded(FilesTree.Level(entries: nodes.map(entry), isFallback: false, isComplete: true))
    }

    /// Each row as text: an entry's path at its depth, "more N", or "status".
    private func text(_ rows: [FilesTree.Row]) -> [String] {
        rows.map { row in
            switch row {
            case let .entry(entry, depth): "\(depth) \(entry.node.path)"
            case let .more(folder, count, depth): "\(depth) more \(count) of \(folder.path)"
            case let .status(node, depth): "\(depth) status \(node.path)"
            }
        }
    }

    @Test("open folders list depth-first under their row; a closed or unread one does not")
    func depthFirst() {
        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let docs = node("/Docs")
        let work = node("/Docs/Work")
        let notes = node("/Docs/Notes")
        let states: [FileNode: FilesTree.State] = [
            roots: level([docs]),
            docs: level([notes, work, node("/Docs/a.txt", folder: false)]),
            work: level([node("/Docs/Work/r.txt", folder: false)]),
            // Notes is open but not read yet.
        ]
        let open: Set = [docs, work, notes]
        #expect(text(FilesTree.rows(under: roots, open: open, states: states)) == [
            "0 /Docs",
            "1 /Docs/Notes",
            "2 status /Docs/Notes",
            "1 /Docs/Work",
            "2 /Docs/Work/r.txt",
            "1 /Docs/a.txt",
        ])
        // Closing Docs hides everything under it, open or not.
        #expect(text(FilesTree.rows(under: roots, open: [work, notes], states: states)) == ["0 /Docs"])
        // A level with no state, or an empty one, is one status row.
        #expect(text(FilesTree.rows(under: node("/x"), open: [], states: [:])) == ["0 status /x"])
        #expect(text(FilesTree.rows(under: node("/x"), open: [], states: [node("/x"): level([])])) == ["0 status /x"])
    }

    @Test("a folder past the cap lists its first entries and one row for the rest; the roots are never capped")
    func rowCap() {
        let big = node("/Big")
        let children = (0 ..< FilesTree.rowCap + 5).map { node(String(format: "/Big/f%04d", $0), folder: false) }
        let rows = text(FilesTree.rows(under: big, open: [], states: [big: level(children)]))
        #expect(rows.count == FilesTree.rowCap + 1)
        #expect(rows.last == "0 more 5 of /Big")

        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let sources = (0 ..< FilesTree.rowCap + 5).map { node("/src\($0)") }
        #expect(FilesTree.rows(under: roots, open: [], states: [roots: level(sources)]).count == FilesTree.rowCap + 5)
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

    @Test("Try Again changes what the load task is keyed by, so a task that had returned — every level then current — runs again")
    func rereadRestartsTheLoad() {
        let tree = FilesTree()
        let folder = FileNode(repositoryID: UUID(), chainKey: "swiftrestic-plan-x", path: "/Data", isDirectory: true)
        let listings = [folder.repositoryID: Date(timeIntervalSince1970: 1_000)]
        let before = tree.loadKey([folder], listings: listings)
        tree.reread(folder)
        #expect(tree.loadKey([folder], listings: listings) != before)
    }
}
