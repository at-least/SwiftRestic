import Foundation

/// Several items of one backup restored together — the Restore pane's
/// Restore… over a multiple selection. The rules that turn the selection into
/// restic calls, apart from restic so they can be tested.
///
/// Paths are compared on their Unicode scalars, never as Swift strings:
/// `String`'s `==` and `hasPrefix` are canonical equivalence, under which two
/// backed-up names that differ only in normalization would be one item.
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
    /// be restored twice — it is dropped, as Finder drops it from a copy.
    static func covering(_ nodes: [SnapshotNode]) -> [SnapshotNode] {
        let folders = nodes.filter(\.isDirectory).map { Array($0.path.unicodeScalars) }
        var seen: Set<[Unicode.Scalar]> = []
        return nodes.filter { node in
            let path = Array(node.path.unicodeScalars)
            guard seen.insert(path).inserted else { return false }
            return !folders.contains { folder in
                folder != path && path.starts(with: folder + (folder.last == "/" ? [] : ["/"]))
            }
        }
    }

    /// Names two items would both land under in one directory — the same
    /// name from two folders of the backup — each once, as first selected.
    /// The second would merge into or replace the first, so such a restore
    /// is refused. Compared without case: the Mac's default volume format
    /// treats "Notes" and "notes" as one name.
    static func collidingNames(_ nodes: [SnapshotNode]) -> [String] {
        var seen: [String: String] = [:]
        var colliding: [String] = []
        for node in nodes {
            let name = ResticService.sanitizedRestoreName(node.name)
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
            let parent: [Unicode.Scalar]
            let directory: String
        }
        var order: [Key] = []
        var members: [Key: (parent: String, directory: URL, nodes: [SnapshotNode])] = [:]
        for (node, directory) in items {
            let parent = parentPath(of: node.path)
            let key = Key(parent: Array(parent.unicodeScalars), directory: directory.path)
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
    /// restored nothing and "star*.txt" would match "starfish.txt" too;
    /// escaped, each matched exactly itself (restic 0.19.1, probed).
    static func includePattern(forName name: String) -> String {
        var pattern = String.UnicodeScalarView(["/"])
        for scalar in name.unicodeScalars {
            if "\\*?[]".unicodeScalars.contains(scalar) { pattern.append("\\") }
            pattern.append(scalar)
        }
        return String(pattern)
    }
}
