import Foundation

/// What `RestoreBatch.covering` reads of a selected item: its name, for the
/// destination sheet's note, its path in its backup, and whether it is a
/// folder.
protocol RestoreBatchItem {
    var name: String { get }
    var path: String { get }
    var isDirectory: Bool { get }
}

extension SnapshotNode: RestoreBatchItem {}

/// Several items restored together — a multiple selection of the Restore
/// pane, Find Files or the Compare sheet. The rules that turn the selection
/// into restic calls, apart from restic so they can be tested.
///
/// Paths are compared by their bytes (`PathKey`), never as Swift strings:
/// `String`'s `==` and `hasPrefix` are canonical equivalence, under which
/// two names differing only in normalization would be one item.
enum RestoreBatch {
    /// One restic call: the items that share a folder of the backup, restored
    /// into one directory on this Mac (`ResticService.restoreItems`).
    struct Group: Equatable, Sendable {
        /// The folder in the backup that holds them — what
        /// `restic restore <id>:<parent>` makes the root of its output.
        let parent: String
        let directory: URL
        let nodes: [SnapshotNode]
    }

    /// The items a selection restores, in its order, and the ones a
    /// selected folder brings, in theirs, each with that folder. A folder
    /// brings everything in it, so an item selected inside a selected folder
    /// would be restored twice — it is dropped, as Finder's own copy drops
    /// it — and a repeat counts once. Only within one backup: a folder
    /// restores as its own backup holds it and brings nothing of another's.
    /// A file found in an older backup than its folder's is one the folder's
    /// backup no longer holds (Find Files lists each path at the newest
    /// backup holding it), or one a diff's newer backup removed, so it
    /// restores on its own. A selection of one backup — the Restore pane's —
    /// names that one for every item.
    static func covering<Item: RestoreBatchItem>(
        _ items: [Item],
        backup: (Item) -> String
    ) -> (kept: [Item], covered: [(item: Item, folder: Item)]) {
        let keys = items.map { Key(backup: backup($0), path: PathKey($0.path)) }
        var keptKeys: Set<Key> = []
        var coveredByKey: [Key: (item: Item, folder: Item)] = [:]
        for (backupID, members) in Dictionary(grouping: items.indices, by: { keys[$0].backup }) {
            let group = members.map { items[$0] }
            let kept = covering(group)
            for item in kept { keptKeys.insert(Key(backup: backupID, path: PathKey(item.path))) }
            for pair in covered(group, kept: kept) {
                coveredByKey[Key(backup: backupID, path: PathKey(pair.item.path))] = pair
            }
        }
        // Each verdict is taken once, so a repeat of an item finds none.
        var keptItems: [Item] = []
        var coveredItems: [(item: Item, folder: Item)] = []
        for (item, key) in zip(items, keys) {
            if keptKeys.remove(key) != nil {
                keptItems.append(item)
            } else if let pair = coveredByKey.removeValue(forKey: key) {
                coveredItems.append(pair)
            }
        }
        return (keptItems, coveredItems)
    }

    /// An item of a selection: its backup and its path's bytes.
    private struct Key: Hashable {
        let backup: String
        let path: PathKey
    }

    /// One backup's items that restore, in its order: each once, none
    /// inside a selected folder.
    private static func covering<Item: RestoreBatchItem>(_ items: [Item]) -> [Item] {
        let folders = items.filter(\.isDirectory).map { insidePrefix($0.path) }
        var seen: Set<PathKey> = []
        return items.filter { item in
            guard seen.insert(PathKey(item.path)).inserted else { return false }
            return !folders.contains { isInside(item.path, prefix: $0) }
        }
    }

    /// One backup's items `covering` dropped for being inside a selected
    /// folder, `kept` being what it kept: each with the folder it is
    /// restored with — the outermost, the one `covering` keeps.
    private static func covered<Item: RestoreBatchItem>(
        _ items: [Item],
        kept: [Item]
    ) -> [(item: Item, folder: Item)] {
        let keptPaths = Set(kept.map { PathKey($0.path) })
        let keptFolders = kept.filter(\.isDirectory).map { (folder: $0, prefix: insidePrefix($0.path)) }
        var reported: Set<PathKey> = []
        return items.compactMap { item in
            guard !keptPaths.contains(PathKey(item.path)), reported.insert(PathKey(item.path)).inserted,
                  let folder = keptFolders.first(where: { isInside(item.path, prefix: $0.prefix) })?.folder
            else { return nil }
            return (item, folder)
        }
    }

    /// The destination sheet's line about `covered` items, so a selection of
    /// three rows read as "Restore 2 items" says where the third went. Nil
    /// when nothing was dropped.
    static func coveredNote<Item: RestoreBatchItem>(_ covered: [(item: Item, folder: Item)]) -> String? {
        guard let first = covered.first else { return nil }
        let folders = Set(covered.map { PathKey($0.folder.path) })
        guard folders.count == 1 else {
            return "\(Format.count(covered.count)) of the selected items are inside selected folders and are restored with them."
        }
        let folder = "“\(first.folder.name)”"
        switch covered.count {
        case 1:
            return "“\(first.item.name)” is inside \(folder) and is restored with it."
        case 2:
            return "“\(first.item.name)” and “\(covered[1].item.name)” are inside \(folder) and are restored with it."
        default:
            return "\(Format.count(covered.count)) of the selected items are inside \(folder) and are restored with it."
        }
    }

    /// The bytes every path inside a folder starts with: its path and a
    /// slash, so a sibling whose name only begins with the folder's is not
    /// inside it.
    private static func insidePrefix(_ folderPath: String) -> [UInt8] {
        Array((folderPath.hasSuffix("/") ? folderPath : folderPath + "/").utf8)
    }

    /// Whether `path` is inside the folder `prefix` came from: longer than
    /// it, so a folder spelled with its slash, or the root, is not inside
    /// itself.
    private static func isInside(_ path: String, prefix: [UInt8]) -> Bool {
        path.utf8.count > prefix.count && path.utf8.starts(with: prefix)
    }

    /// Names two items would both land under in one directory — the same
    /// name from two folders of the backup — each once, as first selected.
    /// The second would merge into or replace the first, so such a restore
    /// is refused. Compared without case: the Mac's default volume format
    /// treats "Notes" and "notes" as one name.
    static func collidingNames(_ names: [String]) -> [String] {
        var seen: [String: String] = [:]
        var colliding: [String] = []
        for original in names {
            let name = ResticService.sanitizedRestoreName(original)
            let key = name.lowercased()
            if let first = seen[key] {
                if !colliding.contains(first) { colliding.append(first) }
            } else {
                seen[key] = name
            }
        }
        return colliding
    }

    /// The restic calls for `items`: one per folder of the backup and
    /// directory, in the order each first appears.
    static func groups(_ items: [(node: SnapshotNode, directory: URL)]) -> [Group] {
        struct Key: Hashable {
            let parent: PathKey
            let directory: String
        }
        var order: [Key] = []
        var members: [Key: (parent: String, directory: URL, nodes: [SnapshotNode])] = [:]
        for (node, directory) in items {
            let parent = parentPath(of: node.path)
            let key = Key(parent: PathKey(parent), directory: directory.path)
            if members[key] == nil {
                order.append(key)
                members[key] = (parent, directory, [])
            }
            members[key]?.nodes.append(node)
        }
        return order.map { key in
            let group = members[key]!
            return Group(parent: group.parent, directory: group.directory, nodes: group.nodes)
        }
    }

    /// The folder holding `path` in the backup: "/" above a top-level item.
    static func parentPath(of path: String) -> String {
        let scalars = Array(path.unicodeScalars)
        guard let slash = scalars.lastIndex(of: "/"), slash > 0 else { return "/" }
        var parent = String.UnicodeScalarView()
        parent.append(contentsOf: scalars[..<slash])
        return String(parent)
    }

    /// The `--include` that restores one item of its group: anchored at the
    /// group's folder, with every character restic's patterns treat as
    /// special escaped, so a name matches only itself. Unescaped, "a[1].txt"
    /// matches nothing and "star*.txt" matches "starfish.txt" too.
    static func includePattern(forName name: String) -> String {
        var pattern = String.UnicodeScalarView(["/"])
        for scalar in name.unicodeScalars {
            if "\\*?[]".unicodeScalars.contains(scalar) { pattern.append("\\") }
            pattern.append(scalar)
        }
        return String(pattern)
    }
}
