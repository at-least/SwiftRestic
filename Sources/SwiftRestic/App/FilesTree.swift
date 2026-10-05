import Foundation
import Observation

/// The Files view's tree, one level per open folder: what the folder held
/// anywhere in its chain's history, from the index — items a later backup
/// no longer has included, which is what this view is for.
///
/// Each level is read under its repository's current listing and read again
/// when a newer listing lands. While the index is still reading the
/// repository, a level may lack older items, so it is read again every
/// `recheckInterval` for as long as it is on screen; and a chain the index
/// holds nothing of yet is listed from its newest backup through restic,
/// and says so.
@MainActor
@Observable
final class FilesTree {
    /// One child row of a level.
    struct Entry: Hashable, Identifiable {
        let node: FileNode
        /// The newest backup of the chain holding it.
        let newest: IndexVersion
        /// Whether the chain's newest backup holds it.
        let isInNewest: Bool

        var id: FileNode { node }
    }

    struct Level: Equatable {
        /// Folders first, then by name as Finder sorts.
        var entries: [Entry]
        /// Listed from the chain's newest backup through restic: the index
        /// holds nothing of the chain yet, so nothing deleted is in it.
        var isFallback: Bool
        /// Whether the index had read every backup of the repository when
        /// this was listed.
        var isComplete: Bool
        /// The listing it was read under (`AppModel.snapshotsLoadedAt`).
        var listedAt: Date?
        /// The listing the index had taken when it was read
        /// (`AppModel.indexTakenGeneration`): a level read before the index
        /// took the listing it was read under is read again once it has.
        var indexGeneration: UInt64?
    }

    enum State: Equatable {
        case loading
        case loaded(Level)
        case failed(String)
    }

    /// The tree's row list for one open level and the open folders under
    /// it, depth-first.
    enum Row: Hashable, Identifiable {
        case entry(Entry, depth: Int)
        /// The entries past `rowCap`, one row that opens the folder.
        case more(FileNode, count: Int, depth: Int)
        /// A level still reading, failed, or empty.
        case status(FileNode, depth: Int)

        var id: Self { self }
    }

    /// The most children one folder lists in the tree; the rest sit behind
    /// one row that opens the folder, whose pane lists them all. A folder of
    /// thousands would otherwise bury every folder below it.
    static let rowCap = 200
    static let recheckInterval: Duration = .seconds(15)

    private(set) var states: [FileNode: State] = [:]
    /// Levels the recheck asked to read again.
    private var due = Set<FileNode>()
    /// Which read each level's state is waiting on: a read whose `keep` was
    /// cancelled must not write over one a later `keep` started.
    private var readTokens: [FileNode: UUID] = [:]
    /// Reads one level: the index and restic (`level(of:model:)`), or a
    /// test's own.
    private let read: @MainActor (FileNode, AppModel) async throws -> Level
    /// Reads ahead the version rows of a level's files
    /// (`AppModel.warmFileHistory`), or a test's own.
    private let warm: @MainActor ([FileNode], AppModel) -> Void

    init(
        read: @escaping @MainActor (FileNode, AppModel) async throws -> Level = { try await FilesTree.level(of: $0, model: $1) },
        warm: @escaping @MainActor ([FileNode], AppModel) -> Void = { $1.warmFileHistory($0) }
    ) {
        self.read = read
        self.warm = warm
    }

    func state(of node: FileNode) -> State? {
        states[node]
    }

    /// How many times Try Again was asked, part of the load key: a failed
    /// level is never stale (`isStale`), so once every other level is
    /// current `keep` returns, and a key that stayed the same would never
    /// run it again — the row spun "Reading…" for good.
    private(set) var rereads = 0

    /// Reads `node` again: Try Again. The load key changes, so the view's
    /// task runs `keep` again, which finds the level unread.
    func reread(_ node: FileNode) {
        states[node] = nil
        rereads += 1
    }

    /// What a Files view's load task is keyed by: the levels on screen, the
    /// listings they must be current with and the ones the index has taken
    /// — their repositories' only, so another repository's refresh does not
    /// cancel a read here — and Try Again.
    func loadKey(_ needed: [FileNode], model: AppModel) -> FilesLoadKey {
        let repositories = Set(needed.map(\.repositoryID))
        return FilesLoadKey(
            nodes: needed,
            listings: model.snapshotsLoadedAt.filter { repositories.contains($0.key) },
            indexTaken: model.indexTakenGeneration.filter { repositories.contains($0.key) },
            rereads: rereads
        )
    }

    /// The rows under `parent`, recursing into the open folders whose levels
    /// are loaded.
    func rows(under parent: FileNode, open: Set<FileNode>) -> [Row] {
        Self.rows(under: parent, open: open, states: states)
    }

    /// `rows(under:open:)` over given levels — the pure rule the instance
    /// reads its own levels through.
    static func rows(under parent: FileNode, open: Set<FileNode>, states: [FileNode: State], depth: Int = 0) -> [Row] {
        guard case let .loaded(level)? = states[parent], !level.entries.isEmpty else {
            return [.status(parent, depth: depth)]
        }
        // The roots are the folders a chain's backups name: never so many
        // that they need a cap.
        let shown = parent.isRoots ? level.entries[...] : level.entries.prefix(rowCap)
        var rows: [Row] = []
        for entry in shown {
            rows.append(.entry(entry, depth: depth))
            if entry.node.isDirectory, open.contains(entry.node) {
                rows += Self.rows(under: entry.node, open: open, states: states, depth: depth + 1)
            }
        }
        if shown.count < level.entries.count {
            rows.append(.more(parent, count: level.entries.count - shown.count, depth: depth))
        }
        return rows
    }

    /// The row that shows `item` among `rows`: its own, or — past its
    /// folder's `rowCap` — the folder's "more items" row standing for it.
    /// Nil while neither is listed.
    nonisolated static func row(showing item: FileNode, in rows: [Row]) -> Row? {
        let folder = ResticPath.parent(of: item.path)
        var more: Row?
        for row in rows {
            switch row {
            case let .entry(entry, _) where entry.node == item:
                return row
            case let .more(parent, _, _) where parent.chainKey == item.chainKey
                && parent.repositoryID == item.repositoryID && PathKey(parent.path) == PathKey(folder):
                more = row
            default:
                continue
            }
        }
        return more
    }

    /// The levels the rows under `parent` need: `parent` and every open
    /// folder shown under it.
    func needed(under parent: FileNode, open: Set<FileNode>) -> [FileNode] {
        var nodes = [parent]
        for case let .entry(entry, _) in rows(under: parent, open: open)
        where entry.node.isDirectory && open.contains(entry.node) {
            nodes.append(entry.node)
        }
        return nodes
    }

    /// Keeps every level of `needed` read under its repository's current
    /// listing, and while any is incomplete reads those again every
    /// `recheckInterval`. A Files tab runs it as a task keyed by
    /// `loadKey`, so opening a folder restarts it and leaving the tab stops
    /// it; a level already current is not read again.
    func keep(_ needed: [FileNode], model: AppModel) async {
        while !Task.isCancelled {
            for node in needed where isStale(node, model: model) {
                await load(node, model: model)
                if Task.isCancelled { return }
            }
            let incomplete = needed.filter { node in
                if case let .loaded(level)? = states[node] { return !level.isComplete }
                return false
            }
            guard !incomplete.isEmpty else { return }
            do {
                try await Task.sleep(for: Self.recheckInterval)
            } catch {
                return
            }
            due.formUnion(incomplete)
        }
    }

    private func isStale(_ node: FileNode, model: AppModel) -> Bool {
        if due.contains(node) { return true }
        switch states[node] {
        // A read still in flight belongs to a `keep` a restart cancelled —
        // SwiftUI starts the new task before the old one unwinds — so this
        // one reads it again. Skipped, the level was left "Reading…" once
        // the cancelled read cleared it.
        case nil, .loading: return true
        case .failed: return false
        case let .loaded(level)?:
            return level.listedAt != model.snapshotsLoadedAt(for: node.repositoryID)
                || level.indexGeneration != model.indexTakenGeneration[node.repositoryID]
        }
    }

    /// Reads one level. A level already shown stays on screen while it is
    /// read again; a cancelled first read leaves no state behind, so the
    /// next `keep` starts it over — unless a later read of the level has
    /// begun, which owns its state from then on.
    private func load(_ node: FileNode, model: AppModel) async {
        due.remove(node)
        let token = UUID()
        readTokens[node] = token
        defer { if readTokens[node] == token { readTokens[node] = nil } }
        if states[node] == nil { states[node] = .loading }
        let listedAt = model.snapshotsLoadedAt(for: node.repositoryID)
        let indexGeneration = model.indexTakenGeneration[node.repositoryID]
        do {
            var level = try await read(node, model)
            guard readTokens[node] == token else { return }
            level.listedAt = listedAt
            level.indexGeneration = indexGeneration
            states[node] = .loaded(level)
            // An open folder's files, as many as it lists, so a click on one
            // finds its version rows read. Only once the index has read every
            // backup: until then the versions, and the backups they name,
            // still move.
            if !node.isRoots, level.isComplete, !level.isFallback {
                warm(level.entries.prefix(Self.rowCap).map(\.node).filter { !$0.isDirectory }, model)
            }
        } catch {
            guard readTokens[node] == token else { return }
            if Task.isCancelled {
                if states[node] == .loading { states[node] = nil }
            } else {
                states[node] = .failed(error.localizedDescription)
            }
        }
    }

    /// `path` and every shorter tail of it, longest first — "/a/b/c",
    /// "/b/c", "/c" — split on the separator's byte, so a name starting with
    /// a combining mark is never merged into the separator before it.
    nonisolated static func tails(of path: String) -> [String] {
        let parts = path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
        return parts.indices.map { "/" + parts[$0...].joined(separator: "/") }
    }

    /// One level as the index and restic answer it: the roots from the
    /// listing, a folder from the index or its fallback.
    static func level(of node: FileNode, model: AppModel) async throws -> Level {
        node.isRoots ? try await roots(of: node, model: model) : try await folder(node, model: model)
    }

    /// The root a Files tab selects as its roots level changes from `old` to
    /// `new`: the first one on a first visit (nothing selected), and the
    /// first again when the selected root has left the level — a relative
    /// backup's folder, read before the index had read the backup, moves
    /// from the absolute path the backup names to where its tree holds it.
    /// Nil leaves the selection alone: the user's pick below the roots, or a
    /// root still listed.
    nonisolated static func rootToSelect(selected: FileNode?, old: [FileNode], new: [FileNode]) -> FileNode? {
        guard let first = new.first else { return nil }
        guard let selected else { return first }
        return old.contains(selected) && !new.contains(selected) ? first : nil
    }

    /// The chain's backups, newest first, from the repository's listing.
    private static func backups(of node: FileNode, model: AppModel) -> [Snapshot] {
        model.snapshots(for: node.repositoryID).filter { SnapshotIndex.chainKey(for: $0) == node.chainKey }
    }

    /// The top of a chain's tree: every folder its backups name as backed
    /// up (`paths`), where each backup's tree holds it (`treePath`), each
    /// with the newest backup naming it. Their kinds come from the index,
    /// one read per parent folder; a root the index has not read yet is
    /// taken for a folder: backed-up roots almost always are.
    private static func roots(of node: FileNode, model: AppModel) async throws -> Level {
        let backups = backups(of: node, model: model)
        var holdersByTail: [PathKey: Set<String>] = [:]
        /// Where `backup`'s tree holds `path`: the longest tail of it the
        /// index has `backup` holding. restic names a folder backed up by a
        /// relative path — `restic backup Documents`, the console's way from
        /// inside a folder — by its absolute path, but stores only the
        /// relative one in its tree (/Documents). An absolute backup's whole
        /// path is its first tail; a backup the index has not read keeps it.
        func treePath(of path: String, in backup: Snapshot) async throws -> String {
            for tail in tails(of: path) {
                let key = PathKey(tail)
                if holdersByTail[key] == nil {
                    holdersByTail[key] = Set(try await model.indexedHolders(
                        ofPath: tail, inChain: node.chainKey, repositoryID: node.repositoryID
                    ).map(\.id))
                }
                if holdersByTail[key]?.contains(backup.id) == true { return tail }
            }
            return path
        }
        var holders: [PathKey: Snapshot] = [:]
        var newestPaths = Set<PathKey>()
        for (position, backup) in backups.enumerated() {
            for path in backup.paths {
                let key = PathKey(try await treePath(of: path, in: backup))
                if holders[key] == nil { holders[key] = backup }
                if position == 0 { newestPaths.insert(key) }
            }
        }
        var kinds: [PathKey: Bool] = [:]
        for parent in Set(holders.keys.map { PathKey(ResticPath.parent(of: $0.path)) }) {
            let children = try await model.indexedChildren(
                ofPath: parent.path, inChain: node.chainKey, repositoryID: node.repositoryID
            )
            for child in children { kinds[PathKey(child.path)] = child.isDirectory }
        }
        let entries = holders.map { key, backup in
            Entry(
                node: FileNode(
                    repositoryID: node.repositoryID, chainKey: node.chainKey,
                    path: key.path, isDirectory: kinds[key] ?? true
                ),
                newest: IndexVersion(id: backup.id, time: backup.time),
                isInNewest: newestPaths.contains(key)
            )
        }
        return Level(
            entries: entries.sorted { SnapshotIndex.bytesLess($0.node.path, $1.node.path) },
            isFallback: false,
            isComplete: await model.indexIsComplete(repositoryID: node.repositoryID)
        )
    }

    /// One folder's children across the chain's history, from the index —
    /// or, while the index holds nothing under it and is still reading, the
    /// chain's newest backup's listing through restic.
    private static func folder(_ node: FileNode, model: AppModel) async throws -> Level {
        let complete = await model.indexIsComplete(repositoryID: node.repositoryID)
        let children = try await model.indexedChildren(
            ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
        )
        if !children.isEmpty || complete {
            let entries = children.map { child in
                Entry(
                    node: FileNode(
                        repositoryID: node.repositoryID, chainKey: node.chainKey,
                        path: child.path, isDirectory: child.isDirectory
                    ),
                    newest: child.newest,
                    isInNewest: child.isInNewest
                )
            }
            return Level(entries: sorted(entries), isFallback: false, isComplete: complete)
        }
        guard let newest = backups(of: node, model: model).first else {
            return Level(entries: [], isFallback: false, isComplete: complete)
        }
        let listed = try await model.children(repositoryID: node.repositoryID, snapshotID: newest.id, path: node.path)
        let entries = listed.map { child in
            Entry(
                node: FileNode(
                    repositoryID: node.repositoryID, chainKey: node.chainKey,
                    path: child.path, isDirectory: child.isDirectory
                ),
                newest: IndexVersion(id: newest.id, time: newest.time),
                isInNewest: true
            )
        }
        return Level(entries: sorted(entries), isFallback: true, isComplete: false)
    }

    /// The browser's order (`ResticService.sortedForBrowser`): folders
    /// first, then names as Finder sorts them.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.node.isDirectory != rhs.node.isDirectory { return lhs.node.isDirectory }
            return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
        }
    }
}

/// What a Files view's load task is keyed by (`FilesTree.loadKey`): a
/// change restarts it.
struct FilesLoadKey: Equatable {
    let nodes: [FileNode]
    let listings: [UUID: Date]
    let indexTaken: [UUID: UInt64]
    let rereads: Int
}

/// A Files tab's search answer — the chain's hits, or why there are none —
/// with the search it answers.
struct FilesSearchAnswer: Equatable {
    enum Outcome: Equatable {
        case hits([FilesTree.Entry])
        case failed(String)
    }

    let roots: FileNode
    let query: String
    let outcome: Outcome
    /// Whether the index had read every backup of the repository when it
    /// answered: until then older backups' items may be missing.
    let isComplete: Bool

    /// The index's words while it has backups still to read — a Files
    /// pane's banner and a search say them alike.
    static let indexStillReading = "The index is still reading this repository — older backups may be missing."

    /// The index's hits as the column lists them: by name as Finder sorts
    /// names, one name's hits by path — the tree's rows, with no folders
    /// first, since a hit's folder is its caption.
    static func entries(_ hits: [IndexChild], under roots: FileNode) -> [FilesTree.Entry] {
        hits.map { hit in
            FilesTree.Entry(
                node: FileNode(
                    repositoryID: roots.repositoryID, chainKey: roots.chainKey,
                    path: hit.path, isDirectory: hit.isDirectory
                ),
                newest: hit.newest,
                isInNewest: hit.isInNewest
            )
        }
        .sorted { lhs, rhs in
            switch lhs.node.name.localizedStandardCompare(rhs.node.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: SnapshotIndex.bytesLess(lhs.node.path, rhs.node.path)
            }
        }
    }

    /// What the hits' footer says, if anything: that the list stops at the
    /// search's ceiling (Find Files' words), or that older backups may
    /// still hold more.
    @MainActor static func note(count: Int, isComplete: Bool) -> String? {
        if count >= AppModel.indexSearchLimit { return "Showing the first matches — narrow the search to see more." }
        return isComplete ? nil : indexStillReading
    }
}
