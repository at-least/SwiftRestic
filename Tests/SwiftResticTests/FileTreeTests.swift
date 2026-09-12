import Foundation
import Testing

/// The restore browser's tree state machine: lazy expansion returns exactly
/// the directory that needs fetching, collapsing removes the subtree, and
/// rows keep their identity by path so SwiftUI selection survives reloads.
@Suite("restore file tree")
struct FileTreeTests {
    private func dir(_ path: String) -> SnapshotNode {
        let name = (path as NSString).lastPathComponent
        return SnapshotNode(name: name.isEmpty ? path : name, type: .dir, path: path)
    }

    private func file(_ path: String) -> SnapshotNode {
        let name = (path as NSString).lastPathComponent
        var node = SnapshotNode(name: name.isEmpty ? path : name, type: .file, path: path)
        node.size = 10
        return node
    }

    @Test("a fresh tree lists roots collapsed and asks for children on expand")
    func expandAsksForChildren() throws {
        var tree = FileTree(roots: [dir("/src"), dir("/data")])
        #expect(tree.rows.map(\.node.path) == ["/src", "/data"])
        #expect(tree.rows.allSatisfy { !$0.expanded && !$0.childrenLoaded })

        // Expanding asks for the children; once loaded, expanding asks
        // nothing more (the second toggle collapses), and collapsing then
        // re-expanding asks again.
        #expect(tree.toggleExpanded(path: "/src") == "/src")
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt"), dir("/src/sub")])
        #expect(tree.toggleExpanded(path: "/src") == nil)
        #expect(tree.toggleExpanded(path: "/src") == "/src")
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt"), dir("/src/sub")])

        // Files never ask: they have no children to load.
        #expect(tree.toggleExpanded(path: "/src/a.txt") == nil)
    }

    @Test("children land at one level deeper, in order, under their parent")
    func childrenInsertUnderParent() throws {
        var tree = FileTree(roots: [dir("/src"), dir("/data")])
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [dir("/src/sub"), file("/src/a.txt")])

        #expect(tree.rows.map(\.node.path) == ["/src", "/src/sub", "/src/a.txt", "/data"])
        #expect(tree.rows.first { $0.node.path == "/src/sub" }?.depth == 1)
        #expect(tree.rows.first { $0.node.path == "/data" }?.depth == 0)
        // Directories start unexpanded-and-unloaded even when nested.
        #expect(tree.rows.first { $0.node.path == "/src/sub" }?.childrenLoaded == false)
    }

    @Test("collapsing removes the subtree, and re-expanding re-asks for children")
    func collapseRemovesSubtree() throws {
        var tree = FileTree(roots: [dir("/src")])
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [dir("/src/sub"), file("/src/a.txt")])
        _ = tree.toggleExpanded(path: "/src/sub")
        tree.replaceChildren(of: "/src/sub", nodes: [file("/src/sub/deep.txt")])
        #expect(tree.rows.count == 4)

        // Collapse the top: everything under it goes away...
        #expect(tree.toggleExpanded(path: "/src") == nil)
        #expect(tree.rows.map(\.node.path) == ["/src"])

        // ...and re-expanding asks for children again — a listing is
        // per-snapshot and may have changed while collapsed.
        #expect(tree.toggleExpanded(path: "/src") == "/src")
        tree.replaceChildren(of: "/src", nodes: [dir("/src/sub"), file("/src/a.txt")])
        #expect(tree.rows.map(\.node.path) == ["/src", "/src/sub", "/src/a.txt"])
    }

    @Test("a snapshot switch resets to the new roots")
    func resetRebuilds() throws {
        var tree = FileTree(roots: [dir("/old")])
        _ = tree.toggleExpanded(path: "/old")
        tree.replaceChildren(of: "/old", nodes: [file("/old/a")])

        tree.reset(to: [dir("/new")])
        #expect(tree.rows.map(\.node.path) == ["/new"])
    }

    @Test("node lookup finds loaded rows only")
    func nodeLookup() throws {
        var tree = FileTree(roots: [dir("/src")])
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt")])

        #expect(tree.node(at: "/src/a.txt") != nil)
        #expect(tree.node(at: "/src/never-loaded.txt") == nil)
    }

    @Test("the same listing landing twice never duplicates rows")
    func duplicateFetchIsIdempotent() throws {
        var tree = FileTree(roots: [dir("/src")])
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt"), dir("/src/sub")])
        // The same listing arrives again — a double-click racing two fetches.
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt"), dir("/src/sub")])

        #expect(tree.rows.map(\.node.path) == ["/src", "/src/a.txt", "/src/sub"])

        // Stale deeper rows go with the level they were loaded under.
        _ = tree.toggleExpanded(path: "/src/sub")
        tree.replaceChildren(of: "/src/sub", nodes: [file("/src/sub/deep.txt")])
        #expect(tree.rows.map(\.node.path) == ["/src", "/src/a.txt", "/src/sub", "/src/sub/deep.txt"])
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt"), dir("/src/sub")])
        #expect(tree.rows.map(\.node.path) == ["/src", "/src/a.txt", "/src/sub"])
    }
}
