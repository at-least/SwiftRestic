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

    private func entry(_ node: FileNode, _ standing: FilesTree.Standing = .onDisk) -> FilesTree.Entry {
        FilesTree.Entry(node: node, standing: standing)
    }

    private func level(_ nodes: [FileNode]) -> FilesTree.State {
        .loaded(FilesTree.Level(entries: nodes.map { entry($0) }, isComplete: true))
    }

    private func child(_ path: String, folder: Bool = false, newest: String = "s2") -> IndexChild {
        IndexChild(path: path, isDirectory: folder, newest: IndexVersion(id: newest, time: .now), isInNewest: newest == "s2")
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

    @Test("ResticPath.ancestors walks parent by parent up to the root; none for the root or a bare name")
    func ancestorPaths() {
        #expect(ResticPath.ancestors(of: "/a/b/c") == ["/a/b", "/a", "/"])
        #expect(ResticPath.ancestors(of: "/a") == ["/"])
        #expect(ResticPath.ancestors(of: "/") == [])
        #expect(ResticPath.ancestors(of: "a") == [])
    }

    // MARK: - The disk beside the backups

    @Test("a folder's rows are the disk's items, each not backed up only once the index has read every backup and found none of it, then what only the backups hold")
    func diskBesideTheBackups() {
        let folder = node("/Docs")
        let disk: [DiskFolder.Item] = [
            .init(name: "b.txt", isDirectory: false, isHidden: false),
            .init(name: "new.txt", isDirectory: false, isHidden: false),
            .init(name: "Work", isDirectory: true, isHidden: false),
            // Hidden: listed only when a backup holds it.
            .init(name: ".DS_Store", isDirectory: false, isHidden: true),
            .init(name: ".zshrc", isDirectory: false, isHidden: true),
            // A file now where a backup held a folder: the disk's kind.
            .init(name: "k", isDirectory: false, isHidden: false),
        ]
        let indexed = [
            child("/Docs/b.txt"), child("/Docs/Work", folder: true), child("/Docs/.zshrc"),
            child("/Docs/k", folder: true),
            // Gone from the disk: the backups alone hold them.
            child("/Docs/old.txt", newest: "s1"), child("/Docs/Old", folder: true, newest: "s1"),
        ]
        func summary(_ entries: [FilesTree.Entry]) -> [String] {
            entries.map { entry in
                let mark = switch entry.standing {
                case .onDisk: "disk"
                case .notBackedUp: "not backed up"
                case let .deleted(lastBackedUp): "deleted \(lastBackedUp.id)"
                }
                return "\(entry.node.name)\(entry.node.isDirectory ? "/" : "") \(mark)"
            }
        }
        #expect(summary(FilesTree.entries(disk: disk, indexed: indexed, in: folder, isComplete: true)) == [
            "Work/ disk", ".zshrc disk", "b.txt disk", "k disk", "new.txt not backed up",
            "Old/ deleted s1", "old.txt deleted s1",
        ])
        // While the index still reads, an older backup may hold new.txt.
        #expect(summary(FilesTree.entries(disk: disk, indexed: indexed, in: folder, isComplete: false)) == [
            "Work/ disk", ".zshrc disk", "b.txt disk", "k disk", "new.txt disk",
            "Old/ deleted s1", "old.txt deleted s1",
        ])
        // Paths join under the folder, the root's without a doubled slash,
        // byte for byte: an NFD name is not its NFC twin.
        let nfc = child("/caf\u{E9}")
        let root = FilesTree.entries(
            disk: [.init(name: "cafe\u{301}", isDirectory: false, isHidden: false)],
            indexed: [nfc], in: node("/"), isComplete: true
        )
        #expect(root.map(\.node) == [node("/cafe\u{301}", folder: false), node("/caf\u{E9}", folder: false)])
        #expect(root.map(\.standing) == [.notBackedUp, .deleted(lastBackedUp: nfc.newest)])
    }

    @Test("what only the backups hold is a row only with Show Deleted Items, after the folder's own and under the same cap")
    func deletedAreNoRows() {
        let docs = node("/Docs")
        let here = (0 ..< FilesTree.rowCap + 2).map { entry(node(String(format: "/Docs/f%04d", $0), folder: false)) }
        let gone = entry(node("/Docs/zz-old", folder: false), .deleted(lastBackedUp: IndexVersion(id: "s1", time: .now)))
        let states: [FileNode: FilesTree.State] = [docs: .loaded(FilesTree.Level(entries: here + [gone], isComplete: true))]
        let rows = text(FilesTree.rows(under: docs, open: [], states: states))
        #expect(rows.count == FilesTree.rowCap + 1)
        #expect(rows.last == "0 more 2 of /Docs")
        // A folder whose items are all gone is empty on this Mac.
        let empty: [FileNode: FilesTree.State] = [docs: .loaded(FilesTree.Level(entries: [gone], isComplete: true))]
        #expect(text(FilesTree.rows(under: docs, open: [], states: empty)) == ["0 status /Docs"])

        // Show Deleted Items lists them after the folder's own, the cap
        // counting them too.
        let shown = text(FilesTree.rows(under: docs, open: [], showsDeleted: true, states: states))
        #expect(shown.count == FilesTree.rowCap + 1)
        #expect(shown.last == "0 more 3 of /Docs")
        #expect(text(FilesTree.rows(under: docs, open: [], showsDeleted: true, states: empty)) == ["0 /Docs/zz-old"])
        // Off at every launch.
        #expect(!AppRouter().filesShowsDeletedItems)
    }

    @Test("a request to show an item turns Show Deleted Items on when the tree lists it, or a folder above it, only as deleted — by its bytes, once each level on its way was read in the tab's turn")
    func revealDecides() {
        let roots = FileNode.roots(repositoryID: repositoryID, chainKey: chain)
        let data = node("/Data")
        let deleted = FilesTree.Standing.deleted(lastBackedUp: IndexVersion(id: "s1", time: .now))
        func read(_ entries: [FilesTree.Entry], complete: Bool = true, turn: UInt64 = 2) -> FilesTree.State {
            .loaded(FilesTree.Level(entries: entries, isComplete: complete, diskGeneration: turn))
        }
        // The disk's names, then what only the backups hold: among them a
        // name in another case and one in another normalization than the
        // disk's, which lstat takes for the disk's on APFS as Macs ship it.
        let nfd = "/Data/cafe\u{301}.txt"
        let nfc = "/Data/caf\u{E9}.txt"
        var states: [FileNode: FilesTree.State] = [
            roots: read([entry(data)]),
            data: read([
                entry(node("/Data/Archive")),
                entry(node("/Data/Notes.md", folder: false), .notBackedUp),
                entry(node(nfd, folder: false)),
                entry(node("/Data/Drafts"), deleted),
                entry(node("/Data/notes.md", folder: false), deleted),
                entry(node(nfc, folder: false), deleted),
            ]),
        ]
        func reveal(_ path: String, folder: Bool = false, turn: UInt64 = 2) -> FilesTree.Reveal {
            FilesTree.reveal(node(path, folder: folder), under: roots, open: [data], states: states, turn: turn)
        }
        // On this Mac: its row is there already.
        #expect(reveal("/Data", folder: true) == .nothing)
        #expect(reveal("/Data/Notes.md") == .nothing)
        #expect(reveal(nfd) == .nothing)
        // Listed only as deleted, by its bytes.
        #expect(reveal("/Data/notes.md") == .showDeleted)
        #expect(reveal(nfc) == .showDeleted)
        // Under a deleted folder, whose level is not read while the toggle
        // is off.
        #expect(reveal("/Data/Drafts/draft1.txt") == .showDeleted)
        // Under a folder of this Mac left closed: folded away either way.
        #expect(reveal("/Data/Archive/old.txt") == .nothing)
        // In no level, nothing to list.
        #expect(reveal("/Data/elsewhere.txt") == .nothing)
        // Another chain's item is not this tab's.
        #expect(FilesTree.reveal(
            FileNode(repositoryID: repositoryID, chainKey: "swiftrestic-plan-bbbb", path: "/Data/notes.md", isDirectory: false),
            under: roots, open: [data], states: states, turn: 2
        ) == .nothing)

        // A level read before the tab's turn waits for the read in it: a
        // folder last read there, or away, answers as it is now.
        #expect(reveal("/Data/notes.md", turn: 3) == .wait)
        // An index still reading may yet find a backup that holds it.
        states[data] = read([entry(node("/Data/Archive"))], complete: false)
        #expect(reveal("/Data/elsewhere.txt") == .wait)
        states[data] = nil
        #expect(reveal("/Data/notes.md") == .wait)
        states[data] = .loading
        #expect(reveal("/Data/notes.md") == .wait)
        // A level that failed or can't be read answers nothing: the tab, or
        // the folder's row, says why.
        states[data] = .failed("The index could not be read.")
        #expect(reveal("/Data/notes.md") == .nothing)
        states[data] = .unavailable(.blockedByMacOS(name: "Data"), diskGeneration: 2)
        #expect(reveal("/Data/notes.md") == .nothing)
        states[roots] = read([entry(data)], turn: 3)
        #expect(reveal("/Data/notes.md", turn: 3) == .wait)
        states[roots] = .unavailable(.volumeAway(volume: "TinyDisk"), diskGeneration: 2)
        #expect(reveal("/Data/notes.md") == .nothing)
        #expect(reveal("/Data/notes.md", turn: 3) == .wait)
    }

    @Test("a disk that may have changed reads every level again, keeping it on screen meanwhile; a folder that could not be listed waits for that")
    func diskTurnRereads() async {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = node("/Data")
        let away = node("/Volumes/Gone/Data")
        let reads = ReadCount()
        let tree = FilesTree(read: { node, _ in
            reads.value += 1
            if node == away { throw FolderAbsence.volumeAway(volume: "Gone") }
            return FilesTree.Level(entries: [], isComplete: true)
        }, warm: { _, _ in })

        await tree.keep([folder, away], model: model)
        #expect(reads.value == 2)
        #expect(tree.state(of: away) == .unavailable(.volumeAway(volume: "Gone"), diskGeneration: 0))
        // Current: nothing is read again, the unlisted folder included.
        await tree.keep([folder, away], model: model)
        #expect(reads.value == 2)

        let before = tree.loadKey([folder], model: model)
        tree.diskMayHaveChanged()
        #expect(tree.loadKey([folder], model: model) != before)
        await tree.keep([folder, away], model: model)
        #expect(reads.value == 4)
        guard case let .loaded(level)? = tree.state(of: folder) else {
            Issue.record("the folder was left \(String(describing: tree.state(of: folder)))")
            return
        }
        #expect(level.diskGeneration == 1)
        #expect(tree.state(of: away) == .unavailable(.volumeAway(volume: "Gone"), diskGeneration: 1))
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

    @Test("a folder level read whole reads ahead the files it lists that a backup holds; the roots or an incomplete level do not")
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
        // A file no backup holds has no versions to read.
        let unsaved = entry(node("/Data/zz-new.txt", folder: false), .notBackedUp)
        let whole = FilesTree.Level(entries: ([node("/Data/Sub")] + files).map { entry($0) } + [unsaved], isComplete: true)
        let warmed = WarmLog()
        func tree(_ level: FilesTree.Level) -> FilesTree {
            FilesTree(read: { _, _ in level }, warm: { files, _ in warmed.calls.append(files) })
        }

        await tree(whole).keep([folder], model: model)
        #expect(warmed.calls == [Array(files.prefix(FilesTree.rowCap - 1))])

        warmed.calls = []
        await tree(whole).keep([FileNode.roots(repositoryID: repositoryID, chainKey: chain)], model: model)
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

    @Test("a read a restart cancelled is read again by the restarted task — never left Reading… with no reader", .timeLimit(.minutes(1)))
    func cancelledReadIsReadAgain() async {
        let model = AppModel(
            store: ConfigStore(
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SwiftResticFilesTree-\(UUID().uuidString)")
            ),
            secrets: .inMemory([:])
        )
        let folder = FileNode(repositoryID: UUID(), chainKey: "swiftrestic-plan-x", path: "/Data", isDirectory: true)
        let read = FilesTree.Level(entries: [], isComplete: true)
        let reads = ReadCount()
        // The first read is still in flight when its task is cancelled — a
        // folder still being read when a listing restarts the load.
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

    @Test("each standing has its words: a row's tag and tooltip, VoiceOver's, and the pane's")
    func standingWords() {
        let when = Date(timeIntervalSince1970: 1_790_904_600)
        let stamp = Format.timestamp(when)
        let here = entry(node("/Docs/a.txt", folder: false))
        #expect(here.tag == nil)
        #expect(here.help(notRead: nil) == "/Docs/a.txt")
        #expect(here.spokenStanding(notRead: nil) == nil)

        let unsaved = entry(node("/Docs/new.txt", folder: false), .notBackedUp)
        #expect(unsaved.tag == "Not backed up")
        #expect(unsaved.help(notRead: nil) == "Not backed up. No backup of this plan holds it")
        #expect(unsaved.help(notRead: "permission denied") == "Not backed up. The newest backup could not read it (permission denied)")
        #expect(unsaved.spokenStanding(notRead: nil) == "not backed up")
        #expect(unsaved.spokenStanding(notRead: "permission denied") == "not backed up, the newest backup could not read it, permission denied")
        #expect(FilesTree.Entry.notBackedUpReason(notRead: nil) == "No backup of this plan holds it")

        let gone = entry(node("/Docs/old.txt", folder: false), .deleted(lastBackedUp: IndexVersion(id: "s1", time: when)))
        #expect(gone.tag == Format.until(when))
        #expect(gone.help(notRead: nil) == "Not on this Mac — last backed up \(stamp)")
        #expect(gone.spokenStanding(notRead: nil) == "not on this Mac, last backed up \(stamp)")

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
