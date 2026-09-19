import Foundation

/// One visible row of the restore browser's file tree: a node, its indent
/// depth, and whether its children are shown / known.
struct FileTreeRow: Identifiable, Equatable {
    var node: SnapshotNode
    var depth: Int
    var expanded: Bool
    /// Directories start unloaded; `ls` fills them on first expansion.
    var childrenLoaded: Bool

    var id: String { node.path }
}

/// The visible rows of a lazily-loaded file tree, as one flat array — the
/// shape a `List` wants, with indent depth for the tree look.
///
/// Pure state machine so it is testable without SwiftUI: the view toggles
/// expansion, receives the directory whose children must be fetched, and
/// feeds listings back through `replaceChildren`. A snapshot switch rebuilds
/// from the roots; the caller re-expands whatever spine it wants to keep.
struct FileTree: Equatable {
    private(set) var rows: [FileTreeRow] = []

    init(roots: [SnapshotNode]) {
        rows = roots.map {
            FileTreeRow(node: $0, depth: 0, expanded: false, childrenLoaded: !$0.isDirectory)
        }
    }

    /// Flips expansion of a directory row. Collapsing removes its descendant
    /// rows. Expanding returns the directory's path when its children have
    /// never been loaded — the caller fetches them and calls
    /// `replaceChildren`; nil means the view has nothing to fetch.
    mutating func toggleExpanded(path: String) -> String? {
        guard let index = rows.firstIndex(where: { $0.node.path == path }),
              rows[index].node.isDirectory
        else { return nil }
        if rows[index].expanded {
            rows[index].expanded = false
            // The children come out with the subtree; re-expanding asks for
            // them again — listings are per-snapshot and may have changed.
            rows[index].childrenLoaded = false
            let depth = rows[index].depth
            var end = index + 1
            while end < rows.count, rows[end].depth > depth { end += 1 }
            rows.removeSubrange(index + 1 ..< end)
            return nil
        }
        rows[index].expanded = true
        if rows[index].childrenLoaded { return nil }
        return path
    }

    /// Installs a directory's children directly under it, at one level
    /// deeper. Replacing is idempotent: any stale descendant rows (a fetch
    /// landing twice after a double-click race, or an earlier deeper walk)
    /// go away with the level they belong to. A folder the user collapsed
    /// while its fetch was in flight refuses the late listing — the rows
    /// would appear under a folder showing as closed — and stays unloaded so
    /// re-expanding asks again.
    mutating func replaceChildren(of path: String, nodes: [SnapshotNode]) {
        guard let index = rows.firstIndex(where: { $0.node.path == path }),
              rows[index].expanded
        else { return }
        rows[index].childrenLoaded = true
        let depth = rows[index].depth
        var staleEnd = index + 1
        while staleEnd < rows.count, rows[staleEnd].depth > depth { staleEnd += 1 }
        let children = nodes.map {
            FileTreeRow(node: $0, depth: depth + 1, expanded: false, childrenLoaded: !$0.isDirectory)
        }
        rows.replaceSubrange(index + 1 ..< staleEnd, with: children)
    }

    /// Marks every row unloaded and collapsed, keeping only the root level —
    /// the reset a snapshot switch performs before re-expanding the spine.
    mutating func reset(to roots: [SnapshotNode]) {
        rows = roots.map {
            FileTreeRow(node: $0, depth: 0, expanded: false, childrenLoaded: !$0.isDirectory)
        }
    }

    /// The row's full node, for restore actions.
    func node(at path: String) -> SnapshotNode? {
        rows.first { $0.node.path == path }?.node
    }
}
