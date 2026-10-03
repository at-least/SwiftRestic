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
/// holds nothing of yet is listed from its newest backup through restic, as
/// Browse Folders did, and says so.
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
    }

    enum State: Equatable {
        case loading
        case loaded(Level)
        case failed(String)
    }

    /// The sidebar row list for one open level and the open folders under
    /// it, depth-first.
    enum Row: Hashable, Identifiable {
        case entry(Entry, depth: Int)
        /// The entries past `rowCap`, one row that opens the folder.
        case more(FileNode, count: Int, depth: Int)
        /// A level still reading, failed, or empty.
        case status(FileNode, depth: Int)

        var id: Self { self }
    }

    /// The most children one folder lists in the sidebar; the rest sit
    /// behind one row that opens the folder, whose pane lists them all. A
    /// folder of thousands would otherwise push every repository and
    /// Activity out of reach.
    static let rowCap = 200
    static let recheckInterval: Duration = .seconds(15)

    private(set) var states: [FileNode: State] = [:]
    /// Levels the recheck asked to read again.
    private var due = Set<FileNode>()

    func state(of node: FileNode) -> State? {
        states[node]
    }

    /// Reads `node` again on the next `keep`: Try Again.
    func reread(_ node: FileNode) {
        states[node] = nil
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
        // The roots are a plan's sources: never so many that they need a cap.
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
    /// `recheckInterval`. The sidebar runs it as a task keyed by what is
    /// open, so opening a folder restarts it and the window closing stops
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
        case nil: return true
        case .loading, .failed: return false
        case let .loaded(level)?: return level.listedAt != model.snapshotsLoadedAt(for: node.repositoryID)
        }
    }

    /// Reads one level. A level already shown stays on screen while it is
    /// read again; a cancelled first read leaves no state behind, so the
    /// next `keep` starts it over.
    private func load(_ node: FileNode, model: AppModel) async {
        due.remove(node)
        if states[node] == nil { states[node] = .loading }
        let listedAt = model.snapshotsLoadedAt(for: node.repositoryID)
        do {
            var level = node.isRoots ? try await Self.roots(of: node, model: model) : try await Self.folder(node, model: model)
            level.listedAt = listedAt
            states[node] = .loaded(level)
        } catch {
            if Task.isCancelled {
                if states[node] == .loading { states[node] = nil }
            } else {
                states[node] = .failed(error.localizedDescription)
            }
        }
    }

    /// The chain's backups, newest first, from the repository's listing.
    private static func backups(of node: FileNode, model: AppModel) -> [Snapshot] {
        model.snapshots(for: node.repositoryID).filter { SnapshotIndex.chainKey(for: $0) == node.chainKey }
    }

    /// The top of a chain's tree: every folder its backups name as backed
    /// up (`paths`), each with the newest backup naming it. Their kinds come
    /// from the index, one read per parent folder; a root the index has not
    /// read yet is taken for a folder, as Browse Folders took every root.
    private static func roots(of node: FileNode, model: AppModel) async throws -> Level {
        let backups = backups(of: node, model: model)
        var holders: [PathKey: Snapshot] = [:]
        for backup in backups {
            for path in backup.paths where holders[PathKey(path)] == nil {
                holders[PathKey(path)] = backup
            }
        }
        var kinds: [PathKey: Bool] = [:]
        for parent in Set(holders.keys.map { PathKey(ResticPath.parent(of: $0.path)) }) {
            let children = try await model.indexedChildren(
                ofPath: parent.path, inChain: node.chainKey, repositoryID: node.repositoryID
            )
            for child in children { kinds[PathKey(child.path)] = child.isDirectory }
        }
        let newestPaths = Set((backups.first?.paths ?? []).map { PathKey($0) })
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
