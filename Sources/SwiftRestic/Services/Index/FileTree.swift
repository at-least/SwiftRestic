import Foundation

struct FileTreeRow: Identifiable, Equatable {
    let node: SnapshotNode
    let depth: Int
    var expanded: Bool
    var childrenLoaded: Bool
    /// Stored, not computed: the list reads it per row on every render, and
    /// the hex encoding allocates.
    let id: String

    fileprivate init(node: SnapshotNode, depth: Int, expanded: Bool, childrenLoaded: Bool) {
        self.node = node
        self.depth = depth
        self.expanded = expanded
        self.childrenLoaded = childrenLoaded
        id = FileTree.id(of: node.path)
    }
}

/// Kept out of SwiftUI so tests drive it. A snapshot switch rebuilds from the
/// roots; the caller re-expands whatever spine it wants to keep.
///
/// Paths match by their bytes (`PathKey`), never String's `==`, which calls
/// two names that differ only in Unicode normalization equal — a file system
/// that keeps the bytes it was given holds both.
struct FileTree: Equatable {
    private(set) var rows: [FileTreeRow] = []

    static func id(of path: String) -> String { PathKey(path).hex }

    func row(id: String) -> FileTreeRow? {
        rows.first { $0.id == id }
    }

    private func index(of path: String) -> Int? {
        let key = PathKey(path)
        return rows.firstIndex { PathKey($0.node.path) == key }
    }

    init(roots: [SnapshotNode]) {
        rows = roots.map {
            FileTreeRow(node: $0, depth: 0, expanded: false, childrenLoaded: !$0.isDirectory)
        }
    }

    /// Returns the path whose children the caller must fetch and hand to
    /// `replaceChildren`, or nil when there is nothing to fetch.
    mutating func toggleExpanded(path: String) -> String? {
        guard let index = index(of: path), rows[index].node.isDirectory
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

    /// `toggleExpanded`, except an open folder stays open: a reveal's step
    /// through a tree the user has already opened.
    mutating func expand(path: String) -> String? {
        guard let index = index(of: path), rows[index].node.isDirectory
        else { return nil }
        rows[index].expanded = true
        return rows[index].childrenLoaded ? nil : path
    }

    /// Idempotent: stale descendant rows — a fetch landing twice after a
    /// double-click race, or an earlier deeper walk — are replaced. A folder
    /// collapsed while its fetch was in flight refuses the late listing (the
    /// rows would appear under a folder showing as closed) and stays unloaded
    /// so re-expanding asks again.
    mutating func replaceChildren(of path: String, nodes: [SnapshotNode]) {
        guard let index = index(of: path), rows[index].expanded
        else { return }
        rows[index].childrenLoaded = true
        let depth = rows[index].depth
        let staleEnd = subtreeEnd(after: index)
        let children = nodes.map {
            FileTreeRow(node: $0, depth: depth + 1, expanded: false, childrenLoaded: !$0.isDirectory)
        }
        rows.replaceSubrange(index + 1 ..< staleEnd, with: children)
    }

    private func subtreeEnd(after index: Int) -> Int {
        let depth = rows[index].depth
        var end = index + 1
        while end < rows.count, rows[end].depth > depth { end += 1 }
        return end
    }

    /// A failed listing closes its folder through this, not a toggle: the
    /// user may have closed it while the listing was in flight, and a toggle
    /// would reopen it, empty, with no listing coming.
    mutating func collapse(path: String) {
        guard let index = index(of: path), rows[index].expanded else { return }
        _ = toggleExpanded(path: path)
    }

    func node(at path: String) -> SnapshotNode? {
        index(of: path).map { rows[$0].node }
    }
}

extension FileTree {
    enum HorizontalArrow: Sendable { case left, right }

    /// NSOutlineView's arrow-key grammar. Option-Right's expand-everything is
    /// left out: every folder is a `restic ls` round trip.
    enum ArrowStep: Equatable, Sendable {
        case expand(String)
        case collapse(String)
        case selectParent(String)
        case stay
    }

    /// A folder whose listing is still in flight counts as open — it shows as
    /// open. A path that is not a row (a search hit left selected) stays.
    func arrowStep(_ arrow: HorizontalArrow, from path: String) -> ArrowStep {
        guard let index = index(of: path) else { return .stay }
        let row = rows[index]
        switch arrow {
        case .right:
            return row.node.isDirectory && !row.expanded ? .expand(path) : .stay
        case .left:
            if row.node.isDirectory, row.expanded { return .collapse(path) }
            guard row.depth > 0 else { return .stay }
            // By depth, not the row directly above, which may sit inside an
            // open sibling folder.
            for candidate in rows[..<index].reversed() where candidate.depth == row.depth - 1 {
                return .selectParent(candidate.node.path)
            }
            return .stay
        }
    }
}
