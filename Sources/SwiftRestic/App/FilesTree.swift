import Foundation
import Observation

/// A plan's Files tab's tree, one level per open folder: the plan's folder
/// as this Mac holds it now, each item beside what the plan's backups hold
/// of it — the way to a current file's past versions, which is what this
/// view is for (2026-10-19; until then the tree listed every item any
/// backup had held). Items only the backups hold are read too, and listed
/// with Show Deleted Items.
///
/// Each level is read from the disk and the index, again when the
/// repository's listing changes or the index takes it, and again when the
/// disk may have changed (`diskMayHaveChanged`: the tab shown, the app made
/// active, a volume mounted or unmounted). While the index is still reading
/// the repository, a level may not know yet that an older backup holds an
/// item, so it says no item is not backed up, and is read again every
/// `recheckInterval` for as long as it is on screen.
@MainActor
@Observable
final class FilesTree {
    /// One child row of a level.
    struct Entry: Hashable, Identifiable {
        let node: FileNode
        let standing: Standing

        var id: FileNode { node }
    }

    /// Where an item stands between this Mac and the plan's backups.
    enum Standing: Hashable {
        /// On this Mac, and a backup of the plan holds it — or the index,
        /// still reading, has not read one that does yet.
        case onDisk
        /// On this Mac, and no backup of the plan holds it: the index has
        /// read every one.
        case notBackedUp
        /// Not on this Mac: only the backups hold it, the newest of them
        /// `lastBackedUp`.
        case deleted(lastBackedUp: IndexVersion)
    }

    struct Level: Equatable {
        /// What is on this Mac, folders first, then by name as Finder
        /// sorts — then, in the same order, what only the backups hold.
        var entries: [Entry]
        /// Whether the index had read every backup of the repository when
        /// this was listed.
        var isComplete: Bool
        /// The listing it was read under (`AppModel.snapshotsLoadedAt`).
        var listedAt: Date?
        /// The listing the index had taken when it was read
        /// (`AppModel.indexTakenGeneration`): a level read before the index
        /// took the listing it was read under is read again once it has.
        var indexGeneration: UInt64?
        /// The disk's turn it was read in (`FilesTree.diskGeneration`).
        var diskGeneration: UInt64 = 0
    }

    enum State: Equatable {
        case loading
        case loaded(Level)
        /// The folder could not be listed from the disk, and why — read
        /// again when the disk may have changed, from its turn on.
        case unavailable(FolderAbsence, diskGeneration: UInt64)
        /// The index could not answer: read again on Try Again.
        case failed(String)
    }

    /// The tree's row list for one open level and the open folders under
    /// it, depth-first.
    enum Row: Hashable, Identifiable {
        case entry(Entry, depth: Int)
        /// The entries past `rowCap`, one row that opens the folder.
        case more(FileNode, count: Int, depth: Int)
        /// A level still reading, unavailable, failed, or empty.
        case status(FileNode, depth: Int)

        var id: Self { self }
    }

    /// The most children one folder lists in the tree; the rest sit behind
    /// one row that opens the folder, whose pane lists them all. A folder of
    /// thousands would otherwise bury every folder below it.
    static let rowCap = 200
    static let recheckInterval: Duration = .seconds(15)

    private(set) var states: [FileNode: State] = [:]
    /// Moved by `diskMayHaveChanged`: a level read in an older turn is read
    /// again.
    private(set) var diskGeneration: UInt64 = 0
    /// Levels the recheck asked to read again.
    private var due = Set<FileNode>()
    /// Which read each level's state is waiting on: a read whose `keep` was
    /// cancelled must not write over one a later `keep` started.
    private var readTokens: [FileNode: UUID] = [:]
    /// Reads one level: the disk and the index (`level(of:model:)`), or a
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

    /// The disk may no longer be as the levels on screen were read: the
    /// Files tab shown again, the app made active — another app may have
    /// changed the folder meanwhile — or a volume mounted or unmounted.
    /// Every level is read again, staying on screen while it is.
    func diskMayHaveChanged() {
        diskGeneration += 1
    }

    /// What a Files view's load task is keyed by: the levels on screen, the
    /// listings they must be current with and the ones the index has taken
    /// — their repositories' only, so another repository's refresh does not
    /// cancel a read here — the disk's turn, and Try Again.
    func loadKey(_ needed: [FileNode], model: AppModel) -> FilesLoadKey {
        let repositories = Set(needed.map(\.repositoryID))
        return FilesLoadKey(
            nodes: needed,
            listings: model.snapshotsLoadedAt.filter { repositories.contains($0.key) },
            indexTaken: model.indexTakenGeneration.filter { repositories.contains($0.key) },
            diskGeneration: diskGeneration,
            rereads: rereads
        )
    }

    /// The rows under `parent`, recursing into the open folders whose levels
    /// are loaded.
    func rows(under parent: FileNode, open: Set<FileNode>, showsDeleted: Bool) -> [Row] {
        Self.rows(under: parent, open: open, showsDeleted: showsDeleted, states: states)
    }

    /// `rows(under:open:showsDeleted:)` over given levels — the pure rule
    /// the instance reads its own levels through. What only the backups
    /// hold is left out unless Show Deleted Items asks for it.
    static func rows(
        under parent: FileNode,
        open: Set<FileNode>,
        showsDeleted: Bool = false,
        states: [FileNode: State],
        depth: Int = 0
    ) -> [Row] {
        guard case let .loaded(level)? = states[parent] else {
            return [.status(parent, depth: depth)]
        }
        let listed = showsDeleted ? level.entries : level.entries.filter { entry in
            if case .deleted = entry.standing { return false }
            return true
        }
        guard !listed.isEmpty else { return [.status(parent, depth: depth)] }
        // The root is the plan's one folder: never so many that it needs a
        // cap.
        let shown = parent.isRoots ? listed[...] : listed.prefix(rowCap)
        var rows: [Row] = []
        for entry in shown {
            rows.append(.entry(entry, depth: depth))
            if entry.node.isDirectory, open.contains(entry.node) {
                rows += Self.rows(under: entry.node, open: open, showsDeleted: showsDeleted, states: states, depth: depth + 1)
            }
        }
        if shown.count < listed.count {
            rows.append(.more(parent, count: listed.count - shown.count, depth: depth))
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
    func needed(under parent: FileNode, open: Set<FileNode>, showsDeleted: Bool) -> [FileNode] {
        var nodes = [parent]
        for case let .entry(entry, _) in rows(under: parent, open: open, showsDeleted: showsDeleted)
        where entry.node.isDirectory && open.contains(entry.node) {
            nodes.append(entry.node)
        }
        return nodes
    }

    /// Keeps every level of `needed` read under its repository's current
    /// listing and the disk's turn, and while any is incomplete reads those
    /// again every `recheckInterval`. A Files tab runs it as a task keyed by
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
        case let .unavailable(_, generation): return generation != diskGeneration
        case let .loaded(level)?:
            return level.listedAt != model.snapshotsLoadedAt(for: node.repositoryID)
                || level.indexGeneration != model.indexTakenGeneration[node.repositoryID]
                || level.diskGeneration != diskGeneration
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
        let diskGeneration = diskGeneration
        do {
            var level = try await read(node, model)
            guard readTokens[node] == token else { return }
            level.listedAt = listedAt
            level.indexGeneration = indexGeneration
            level.diskGeneration = diskGeneration
            states[node] = .loaded(level)
            // An open folder's files the backups hold, as many as it lists,
            // so a click on one finds its version rows read. Only once the
            // index has read every backup: until then the versions, and the
            // backups they name, still move.
            if !node.isRoots, level.isComplete {
                // The rows come first in `entries`, what only the backups
                // hold after them.
                let listed = level.entries.prefix(Self.rowCap)
                warm(listed.filter { $0.standing == .onDisk && !$0.node.isDirectory }.map(\.node), model)
            }
        } catch let absence as FolderAbsence {
            guard readTokens[node] == token else { return }
            states[node] = .unavailable(absence, diskGeneration: diskGeneration)
        } catch {
            guard readTokens[node] == token else { return }
            if Task.isCancelled {
                if states[node] == .loading { states[node] = nil }
            } else {
                states[node] = .failed(error.localizedDescription)
            }
        }
    }

    /// One level as the disk and the index answer it: the plan's folder at
    /// the top, a folder's items below.
    static func level(of node: FileNode, model: AppModel) async throws -> Level {
        node.isRoots ? try await root(of: node, model: model) : try await folder(node, model: model)
    }

    /// The root a Files tab selects as its roots level changes from `old` to
    /// `new`: the first one on a first visit (nothing selected), and the
    /// first again when the selected root has left the level. Nil leaves the
    /// selection alone: the user's pick below the root, or a root still
    /// listed.
    nonisolated static func rootToSelect(selected: FileNode?, old: [FileNode], new: [FileNode]) -> FileNode? {
        guard let first = new.first else { return nil }
        guard let selected else { return first }
        return old.contains(selected) && !new.contains(selected) ? first : nil
    }

    /// The top of a plan's tree: its folder — or file — as this Mac holds
    /// it, by the plan's path. Empty for a plan deleted while its tab was
    /// still on screen, whose page goes with it.
    private static func root(of node: FileNode, model: AppModel) async throws -> Level {
        guard let plan = model.configuration.plans.first(where: { ResticService.planTag($0.id) == node.chainKey }) else {
            return Level(entries: [], isComplete: true)
        }
        let path = ResticService.expandTilde(plan.path)
        let isDirectory = try await Task.detached(priority: .userInitiated) { try DiskFolder.isDirectory(path) }.value
        // Asked before the holders: a backup once read stays read, so an
        // index complete beforehand has read every backup that holds it.
        let complete = await model.indexIsComplete(repositoryID: node.repositoryID)
        let holders = try await model.indexedHolders(ofPath: path, inChain: node.chainKey, repositoryID: node.repositoryID)
        let entry = Entry(
            node: FileNode(repositoryID: node.repositoryID, chainKey: node.chainKey, path: path, isDirectory: isDirectory),
            standing: holders.isEmpty && complete ? .notBackedUp : .onDisk
        )
        return Level(entries: [entry], isComplete: complete)
    }

    /// One folder's items as this Mac holds them, beside what the plan's
    /// backups ever held there (`entries(disk:indexed:in:isComplete:)`). A
    /// folder gone from this Mac — a deleted one opened with Show Deleted
    /// Items — holds only what the backups held in it.
    private static func folder(_ node: FileNode, model: AppModel) async throws -> Level {
        let path = node.path
        let disk: [DiskFolder.Item]
        do {
            disk = try await Task.detached(priority: .userInitiated) { try DiskFolder.list(path) }.value
        } catch FolderAbsence.missing(name: _) {
            disk = []
        }
        // Asked before the index's answer, as the root's is.
        let complete = await model.indexIsComplete(repositoryID: node.repositoryID)
        let indexed = try await model.indexedChildren(
            ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
        )
        return Level(entries: entries(disk: disk, indexed: indexed, in: node, isComplete: complete), isComplete: complete)
    }

    /// A folder's rows from its disk listing and the index's children of it
    /// (every item any backup of the chain held there): each item on disk,
    /// not backed up when the index, having read every backup, has none of
    /// it — a hidden one listed only when a backup holds it, so the
    /// excluded `.DS_Store` is not a row in every folder — then each item
    /// only the backups hold, as deleted. The kind is the disk's: the row
    /// is the item as it is now.
    nonisolated static func entries(disk: [DiskFolder.Item], indexed: [IndexChild], in folder: FileNode, isComplete: Bool) -> [Entry] {
        var held: [PathKey: IndexChild] = [:]
        for child in indexed { held[PathKey(child.path)] = child }
        let prefix = folder.path == "/" ? "" : folder.path
        var onDisk: [Entry] = []
        var present = Set<PathKey>()
        for item in disk {
            let path = prefix + "/" + item.name
            let key = PathKey(path)
            present.insert(key)
            let isHeld = held[key] != nil
            if item.isHidden, !isHeld { continue }
            onDisk.append(Entry(
                node: FileNode(repositoryID: folder.repositoryID, chainKey: folder.chainKey, path: path, isDirectory: item.isDirectory),
                standing: !isHeld && isComplete ? .notBackedUp : .onDisk
            ))
        }
        let deleted = indexed.filter { !present.contains(PathKey($0.path)) }.map { child in
            Entry(
                node: FileNode(repositoryID: folder.repositoryID, chainKey: folder.chainKey, path: child.path, isDirectory: child.isDirectory),
                standing: .deleted(lastBackedUp: child.newest)
            )
        }
        return sorted(onDisk) + sorted(deleted)
    }

    /// The index's children as rows of the backups alone — a search's hits
    /// — each on this Mac or deleted by `present`, unsorted; each caller
    /// applies its own order.
    nonisolated static func entries(_ children: [IndexChild], repositoryID: UUID, chainKey: String, present: Set<PathKey>) -> [Entry] {
        children.map { child in
            Entry(
                node: FileNode(
                    repositoryID: repositoryID, chainKey: chainKey,
                    path: child.path, isDirectory: child.isDirectory
                ),
                standing: present.contains(PathKey(child.path)) ? .onDisk : .deleted(lastBackedUp: child.newest)
            )
        }
    }

    /// The browser's order (`ResticService.sortedForBrowser`): folders
    /// first, then names as Finder sorts them.
    nonisolated private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if lhs.node.isDirectory != rhs.node.isDirectory { return lhs.node.isDirectory }
            return lhs.node.name.localizedStandardCompare(rhs.node.name) == .orderedAscending
        }
    }
}

extension FilesTree.Entry {
    /// The row's tooltip, the tree's and a search hit's: the item's whole
    /// path, or for one marked, its standing.
    func help(notRead: String?) -> String {
        switch standing {
        case .onDisk: node.path
        case .notBackedUp: Self.notBackedUp(notRead: notRead)
        case let .deleted(lastBackedUp): Self.deleted(lastBackedUp: lastBackedUp.time)
        }
    }

    /// The mark as VoiceOver reads it after the name, nil for an item on
    /// this Mac that the backups hold.
    func spokenStanding(notRead: String?) -> String? {
        switch standing {
        case .onDisk: nil
        case .notBackedUp: notRead.map { "not backed up, the newest backup could not read it, \($0)" } ?? "not backed up"
        case let .deleted(lastBackedUp): "not on this Mac, last backed up \(Format.timestamp(lastBackedUp.time))"
        }
    }

    /// What the row's tag says beside the name, nil for an item on this
    /// Mac that the backups hold.
    var tag: String? {
        switch standing {
        case .onDisk: nil
        case .notBackedUp: "Not backed up"
        case let .deleted(lastBackedUp): Format.until(lastBackedUp.time)
        }
    }

    /// For an item on this Mac no backup holds: that, and why — the row's
    /// tooltip.
    static func notBackedUp(notRead: String?) -> String {
        "Not backed up. " + notBackedUpReason(notRead: notRead)
    }

    /// Why an item on this Mac is not backed up: the newest backup's own
    /// run could not read it (`UnreadItems.reason`), or no backup of the
    /// plan holds it — the pane's words under its "Not backed up".
    static func notBackedUpReason(notRead: String?) -> String {
        notRead.map { "The newest backup could not read it (\($0))." } ?? "No backup of this plan holds it."
    }

    /// For an item only the backups hold: when it was last backed up.
    static func deleted(lastBackedUp: Date) -> String {
        "Not on this Mac — last backed up \(Format.timestamp(lastBackedUp))"
    }

    /// For an item on this Mac the chain's newest backup lacks, though an
    /// older one holds it: when it was last backed up, and why the newest
    /// lacks it when its own run could not read it (`UnreadItems.reason`) —
    /// the Files pane's line.
    static func standing(notRead: String?, lastBackedUp: Date) -> String {
        let when = "last backed up \(Format.timestamp(lastBackedUp))"
        return notRead.map { "Not read by the newest backup (\($0)) — \(when)" } ?? "Not in the newest backup — \(when)"
    }
}

/// What a Files view's load task is keyed by (`FilesTree.loadKey`): a
/// change restarts it.
struct FilesLoadKey: Equatable {
    let nodes: [FileNode]
    let listings: [UUID: Date]
    let indexTaken: [UUID: UInt64]
    let diskGeneration: UInt64
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
    /// Whether the chain holds more hits than the list shows.
    let isTruncated: Bool

    /// The index's words while it has backups still to read — a Files
    /// pane's banner and a search say them alike.
    static let indexStillReading = "The index is still reading this repository — older backups may be missing."

    /// How the index matches what is typed, said once for every surface that
    /// states it. `SnapshotIndex.ftsQuery` makes each word a prefix term.
    static let matchRule = "Matching is case-insensitive; each word you type matches the start of a word in the name — “note” also finds “notes.txt”."

    /// The index's hits as the column lists them — each on this Mac or
    /// deleted by `present`, the paths found on the disk: by name as Finder
    /// sorts names, one name's hits by path — the tree's rows, with no
    /// folders first, since a hit's folder is its caption.
    static func entries(_ hits: [IndexChild], under roots: FileNode, present: Set<PathKey>) -> [FilesTree.Entry] {
        FilesTree.entries(hits, repositoryID: roots.repositoryID, chainKey: roots.chainKey, present: present)
            .sorted { lhs, rhs in
                switch lhs.node.name.localizedStandardCompare(rhs.node.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: SnapshotIndex.bytesLess(lhs.node.path, rhs.node.path)
                }
            }
    }

    /// What the hits' footer says, if anything: that the chain holds more
    /// than the list shows — not "the first", since the list is in Finder's
    /// order and the index cut it in its own — or that older backups may
    /// still hold more.
    @MainActor static func note(isTruncated: Bool, isComplete: Bool) -> String? {
        if isTruncated { return "Showing \(AppModel.indexSearchLimit) matches — narrow the search to see the rest." }
        return isComplete ? nil : indexStillReading
    }
}
