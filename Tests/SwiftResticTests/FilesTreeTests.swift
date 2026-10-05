import Foundation
import Testing

/// A Files tab's tree rows, as the pure rule the tree lays out: a
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

    @Test("a selected item is shown by its own row, past its folder's cap by the folder's more row, and by nothing while neither is listed")
    func rowShowingItem() {
        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let big = node("/Big")
        let children = (0 ..< FilesTree.rowCap + 5).map { node(String(format: "/Big/f%04d", $0), folder: false) }
        let rows = FilesTree.rows(under: roots, open: [big], states: [roots: level([big]), big: level(children)])

        let first = children[0]
        #expect(FilesTree.row(showing: first, in: rows).map { text([$0]) } == ["1 \(first.path)"])
        #expect(FilesTree.row(showing: big, in: rows).map { text([$0]) } == ["0 /Big"])
        let pastCap = children[FilesTree.rowCap + 2]
        #expect(FilesTree.row(showing: pastCap, in: rows).map { text([$0]) } == ["1 more 5 of /Big"])
        // A closed folder's item, and another chain's, have no row yet.
        #expect(FilesTree.row(showing: node("/Other/x", folder: false), in: rows) == nil)
        let elsewhere = FileNode(repositoryID: repositoryID, chainKey: "swiftrestic-plan-bbbb", path: pastCap.path, isDirectory: false)
        #expect(FilesTree.row(showing: elsewhere, in: rows) == nil)
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

    @Test("a path's tails run from the whole path to its last name, split on the separator's byte")
    func tails() {
        #expect(FilesTree.tails(of: "/a/b/c") == ["/a/b/c", "/b/c", "/c"])
        #expect(FilesTree.tails(of: "/a") == ["/a"])
        #expect(FilesTree.tails(of: "/") == [])
        // A name starting with a combining mark keeps its own tail.
        #expect(FilesTree.tails(of: "/d/\u{0301}x") == ["/d/\u{0301}x", "/\u{0301}x"])
    }

    @Test("Try Again changes what the load task is keyed by, so a task that had returned — every level then current — runs again")
    func rereadRestartsTheLoad() {
        let tree = FilesTree()
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = FileNode(repositoryID: UUID(), chainKey: "swiftrestic-plan-x", path: "/Data", isDirectory: true)
        let before = tree.loadKey([folder], model: model)
        tree.reread(folder)
        #expect(tree.loadKey([folder], model: model) != before)
    }

    @Test("the load key moves when the index takes a listing, so a tree read before it reads again then")
    func indexTakeRestartsTheLoad() {
        let tree = FilesTree()
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = FileNode(repositoryID: UUID(), chainKey: "swiftrestic-plan-x", path: "/Data", isDirectory: true)
        let before = tree.loadKey([folder], model: model)
        model.indexTakenGeneration[folder.repositoryID] = 1
        let taken = tree.loadKey([folder], model: model)
        #expect(taken != before)
        // Another repository's listing and take leave it alone: they must
        // not cancel a read of this one.
        let other = UUID()
        model.snapshotsLoadedAt[other] = Date(timeIntervalSince1970: 1_000)
        model.indexTakenGeneration[other] = 7
        #expect(tree.loadKey([folder], model: model) == taken)
    }

    @Test("a folder level read whole reads ahead the files it lists; the roots, a fallback or an incomplete level do not")
    func levelsReadAheadTheirFiles() async {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = node("/Data")
        // A subfolder first, then more files than the tree lists.
        let files = (0 ..< FilesTree.rowCap + 5).map { node(String(format: "/Data/f%03d.txt", $0), folder: false) }
        let whole = FilesTree.Level(entries: ([node("/Data/Sub")] + files).map(entry), isFallback: false, isComplete: true)
        let warmed = WarmLog()
        func tree(_ level: FilesTree.Level) -> FilesTree {
            FilesTree(read: { _, _ in level }, warm: { files, _ in warmed.calls.append(files) })
        }

        await tree(whole).keep([folder], model: model)
        #expect(warmed.calls == [Array(files.prefix(FilesTree.rowCap - 1))])

        warmed.calls = []
        await tree(whole).keep([FileNode.roots(repositoryID: repositoryID, chainKey: chain)], model: model)
        var fallback = whole
        fallback.isFallback = true
        await tree(fallback).keep([folder], model: model)
        var incomplete = whole
        incomplete.isComplete = false
        let reading = tree(incomplete)
        // An incomplete level is read again every recheckInterval: stop
        // after the first read.
        let task = Task { await reading.keep([folder], model: model) }
        let deadline = ContinuousClock.now + .seconds(10)
        while reading.state(of: folder) == nil || reading.state(of: folder) == .loading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(reading.state(of: folder) != nil && reading.state(of: folder) != .loading, "the level was never read")
        task.cancel()
        await task.value
        #expect(warmed.calls.isEmpty)
    }

    @Test("a read a restart cancelled is read again by the restarted task — never left Reading… with no reader")
    func cancelledReadIsReadAgain() async {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = FileNode(repositoryID: UUID(), chainKey: "swiftrestic-plan-x", path: "/Data", isDirectory: true)
        let read = FilesTree.Level(entries: [], isFallback: false, isComplete: true)
        let reads = ReadCount()
        // The first read is still in flight when its task is cancelled — a
        // folder being read through restic when a listing restarts the load.
        let tree = FilesTree { _, _ in
            reads.value += 1
            if reads.value == 1 { try await Task.sleep(for: .seconds(600)) }
            return read
        }

        let first = Task { await tree.keep([folder], model: model) }
        while tree.state(of: folder) != .loading { await Task.yield() }
        // The restarted task runs before the cancelled one unwinds, as a
        // load-key change does: SwiftUI cancels the old task and starts the
        // new one at once.
        let second = Task { await tree.keep([folder], model: model) }
        await second.value
        first.cancel()
        await first.value

        guard case let .loaded(level)? = tree.state(of: folder) else {
            Issue.record("the folder was left \(String(describing: tree.state(of: folder))), with no read under way")
            return
        }
        #expect(level.entries == read.entries)
    }

    // MARK: - Search

    @Test("a search's hits list by name as Finder sorts names, one name's by path, each the tree row it selects")
    func searchHitsOrder() {
        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let day = IndexVersion(id: "s1", time: .now)
        let hits = [
            IndexChild(path: "/Docs/b/note10", isDirectory: false, newest: day, isInNewest: true),
            IndexChild(path: "/Docs/a/note2", isDirectory: false, newest: day, isInNewest: false),
            IndexChild(path: "/Docs/b/note2", isDirectory: false, newest: day, isInNewest: true),
            IndexChild(path: "/Docs/Notes", isDirectory: true, newest: day, isInNewest: true),
        ]
        let entries = FilesSearchAnswer.entries(hits, under: roots)
        // note2 before note10, numbers as numbers; no folders-first.
        #expect(entries.map(\.node.path) == ["/Docs/a/note2", "/Docs/b/note2", "/Docs/b/note10", "/Docs/Notes"])
        // A hit is the very node the tree lists, so picking it selects that
        // row's item, and the dimming comes with it.
        #expect(entries[0] == FilesTree.Entry(node: node("/Docs/a/note2", folder: false), newest: day, isInNewest: false))
        #expect(entries[3].node == node("/Docs/Notes"))
    }

    @Test("a search's footer says the ceiling first, then the index still reading, else nothing")
    func searchHitsNote() {
        #expect(FilesSearchAnswer.note(count: 3, isComplete: true) == nil)
        #expect(FilesSearchAnswer.note(count: 3, isComplete: false) == FilesSearchAnswer.indexStillReading)
        #expect(FilesSearchAnswer.note(count: AppModel.indexSearchLimit, isComplete: false)
            == "Showing the first matches — narrow the search to see more.")
    }
}

/// What a test's tree asked to read ahead, one list per level.
@MainActor
private final class WarmLog {
    var calls: [[FileNode]] = []
}

/// How many reads a test's level reader has answered.
@MainActor
private final class ReadCount {
    var value = 0
}
