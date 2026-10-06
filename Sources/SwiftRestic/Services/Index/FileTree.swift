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
        reset(to: roots)
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
            rows.removeSubrange(index + 1 ..< subtreeEnd(after: index))
            return nil
        }
        rows[index].expanded = true
        if rows[index].childrenLoaded { return nil }
        return path
    }

    /// Installs a directory's children directly under it, one level deeper.
    /// Replacing is idempotent: any stale descendant rows — a fetch landing
    /// twice after a double-click race, or an earlier deeper walk — go away
    /// with the level they belong to. A folder collapsed while its fetch was
    /// in flight refuses the late listing — the rows would appear under a
    /// folder showing as closed — and stays unloaded so re-expanding asks
    /// again.
    mutating func replaceChildren(of path: String, nodes: [SnapshotNode]) {
        guard let index = rows.firstIndex(where: { $0.node.path == path }),
              rows[index].expanded
        else { return }
        rows[index].childrenLoaded = true
        let depth = rows[index].depth
        let staleEnd = subtreeEnd(after: index)
        let children = nodes.map {
            FileTreeRow(node: $0, depth: depth + 1, expanded: false, childrenLoaded: !$0.isDirectory)
        }
        rows.replaceSubrange(index + 1 ..< staleEnd, with: children)
    }

    /// One past the last row inside the subtree at `index` — the next row at
    /// its depth or shallower.
    private func subtreeEnd(after index: Int) -> Int {
        let depth = rows[index].depth
        var end = index + 1
        while end < rows.count, rows[end].depth > depth { end += 1 }
        return end
    }

    /// Marks every row unloaded and collapsed, keeping only the root level —
    /// the reset a snapshot switch performs before re-expanding the spine.
    mutating func reset(to roots: [SnapshotNode]) {
        rows = roots.map {
            FileTreeRow(node: $0, depth: 0, expanded: false, childrenLoaded: !$0.isDirectory)
        }
    }

    /// Closes a directory row if it is open; a closed one stays closed. A
    /// failed listing closes its folder through this, not a toggle: the user
    /// may have closed it — by ← or its chevron — while the listing was in
    /// flight, and a toggle would reopen it, empty, with no listing coming.
    mutating func collapse(path: String) {
        guard rows.first(where: { $0.node.path == path })?.expanded == true else { return }
        _ = toggleExpanded(path: path)
    }

    /// The row's full node, for restore actions.
    func node(at path: String) -> SnapshotNode? {
        rows.first { $0.node.path == path }?.node
    }
}

extension FileTree {
    /// The two horizontal arrows the tree answers.
    enum HorizontalArrow: Sendable { case left, right }

    /// What a Left or Right arrow does to the selected row — NSOutlineView's
    /// own grammar: Right opens a closed folder and otherwise does nothing;
    /// Left closes an open folder, otherwise selects the folder the row sits
    /// in, and does nothing on a top-level row. Option-Right's
    /// expand-everything is left out: every folder is a `restic ls` round
    /// trip.
    enum ArrowStep: Equatable, Sendable {
        case expand(String)
        case collapse(String)
        case selectParent(String)
        case stay
    }

    /// The step for `arrow` on the row at `path`. A folder whose listing is
    /// still in flight counts as open — it shows as open — so Left closes
    /// it and Right asks nothing more. A path that is not a row (a search
    /// hit left selected) stays.
    func arrowStep(_ arrow: HorizontalArrow, from path: String) -> ArrowStep {
        guard let index = rows.firstIndex(where: { $0.node.path == path }) else { return .stay }
        let row = rows[index]
        switch arrow {
        case .right:
            return row.node.isDirectory && !row.expanded ? .expand(path) : .stay
        case .left:
            if row.node.isDirectory, row.expanded { return .collapse(path) }
            guard row.depth > 0 else { return .stay }
            // The parent is the nearest row above at one level shallower —
            // by depth, not the row directly above, which may sit inside an
            // open sibling folder.
            for candidate in rows[..<index].reversed() where candidate.depth == row.depth - 1 {
                return .selectParent(candidate.node.path)
            }
            return .stay
        }
    }
}
