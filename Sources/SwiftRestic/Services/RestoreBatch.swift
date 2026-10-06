import Foundation

/// Several items of one backup restored together — the Restore pane's
/// Restore… over a multiple selection. The rules that turn the selection into
/// restic calls, apart from restic so they can be tested.
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

    /// The items a selection restores, in its order. A folder brings
    /// everything in it, so an item selected inside a selected folder would
    /// be restored twice — it is dropped, as Finder's own copy drops it.
    static func covering(_ nodes: [SnapshotNode]) -> [SnapshotNode] {
        let folders = nodes.filter(\.isDirectory)
        var seen: Set<PathKey> = []
        return nodes.filter { node in
            guard seen.insert(PathKey(node.path)).inserted else { return false }
            return !folders.contains { isInside(node, $0) }
        }
    }

    /// The items `covering` drops for being inside another selected folder,
    /// each with the selected folder it is restored with — the outermost,
    /// the one `covering` keeps.
    static func covered(_ nodes: [SnapshotNode]) -> [(item: SnapshotNode, folder: SnapshotNode)] {
        let kept = covering(nodes)
        let keptPaths = Set(kept.map { PathKey($0.path) })
        let keptFolders = kept.filter(\.isDirectory)
        var reported: Set<PathKey> = []
        return nodes.compactMap { node in
            let key = PathKey(node.path)
            guard !keptPaths.contains(key), reported.insert(key).inserted,
                  let folder = keptFolders.first(where: { isInside(node, $0) })
            else { return nil }
            return (node, folder)
        }
    }

    /// The destination sheet's line about `covered` items, so a selection of
    /// three rows read as "Restore 2 items" says where the third went. Nil
    /// when nothing was dropped.
    static func coveredNote(_ covered: [(item: SnapshotNode, folder: SnapshotNode)]) -> String? {
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

    /// Whether `node` is somewhere inside `folder`, by bytes: a sibling whose
    /// name only begins with the folder's is not.
    private static func isInside(_ node: SnapshotNode, _ folder: SnapshotNode) -> Bool {
        node.path.utf8.starts(with: (folder.path.hasSuffix("/") ? folder.path : folder.path + "/").utf8)
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
