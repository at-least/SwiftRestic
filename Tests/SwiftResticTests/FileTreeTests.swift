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

    @Test("a listing that lands on a folder collapsed mid-fetch is not installed")
    func collapsedFolderRefusesLateListing() throws {
        var tree = FileTree(roots: [dir("/src")])
        _ = tree.toggleExpanded(path: "/src")
        // The user collapses while the fetch is in flight; the fetch is not
        // cancelled, so its listing lands on a collapsed folder.
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [file("/src/a.txt")])

        // Collapsed stays collapsed: no rows appear under a folder the user
        // closed, and the folder stays "unloaded" so re-expanding refetches.
        #expect(tree.rows.map(\.node.path) == ["/src"], "rows were \(tree.rows.map(\.node.path))")
        #expect(tree.rows[0].childrenLoaded == false)
        #expect(tree.toggleExpanded(path: "/src") == "/src")
    }

    // MARK: - Left and Right, NSOutlineView's grammar

    @Test("Right opens a closed folder; files and open folders stay")
    func rightOpensClosedFolders() throws {
        var tree = FileTree(roots: [dir("/src"), dir("/data")])
        #expect(tree.arrowStep(.right, from: "/src") == .expand("/src"))

        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [dir("/src/sub"), file("/src/a.txt")])
        // A file has nothing to open, and an open folder is already open —
        // the native outline leaves both alone rather than moving down.
        #expect(tree.arrowStep(.right, from: "/src/a.txt") == .stay)
        #expect(tree.arrowStep(.right, from: "/src") == .stay)

        // A nested folder opens the same way, and again after closing.
        _ = tree.toggleExpanded(path: "/src/sub")
        tree.replaceChildren(of: "/src/sub", nodes: [file("/src/sub/deep.txt")])
        _ = tree.toggleExpanded(path: "/src/sub")
        #expect(tree.arrowStep(.right, from: "/src/sub") == .expand("/src/sub"))
    }

    @Test("Left closes an open folder, otherwise selects the parent by depth")
    func leftClosesOrSelectsParent() throws {
        var tree = FileTree(roots: [dir("/src"), dir("/data")])
        _ = tree.toggleExpanded(path: "/src")
        tree.replaceChildren(of: "/src", nodes: [dir("/src/sub"), file("/src/a.txt")])
        _ = tree.toggleExpanded(path: "/src/sub")
        tree.replaceChildren(of: "/src/sub", nodes: [file("/src/sub/deep.txt")])
        #expect(tree.rows.map { "\($0.depth):\($0.node.path)" }
            == ["0:/src", "1:/src/sub", "2:/src/sub/deep.txt", "1:/src/a.txt", "0:/data"])

        // The parent is found by depth, not as the row above: a.txt sits
        // under /src/sub's open subtree, and its folder is /src.
        #expect(tree.arrowStep(.left, from: "/src/a.txt") == .selectParent("/src"))
        #expect(tree.arrowStep(.left, from: "/src/sub/deep.txt") == .selectParent("/src/sub"))
        #expect(tree.arrowStep(.left, from: "/src/sub") == .collapse("/src/sub"))
        // A closed top-level folder has nowhere to go.
        #expect(tree.arrowStep(.left, from: "/data") == .stay)

        // Once closed, the nested folder steps up to its own parent.
        _ = tree.toggleExpanded(path: "/src/sub")
        #expect(tree.arrowStep(.left, from: "/src/sub") == .selectParent("/src"))
    }

    @Test("a folder whose listing is still in flight counts as open")
    func inFlightFolderCountsAsOpen() throws {
        var tree = FileTree(roots: [dir("/src")])
        // Expanded, its listing asked for and not yet landed.
        #expect(tree.toggleExpanded(path: "/src") == "/src")

        // It shows as open, so Left closes it — and a late listing is then
        // refused, as for a chevron collapse — while Right asks no second
        // listing.
        #expect(tree.arrowStep(.left, from: "/src") == .collapse("/src"))
        #expect(tree.arrowStep(.right, from: "/src") == .stay)
    }

    @Test("a failed listing closes its folder only while it still shows open")
    func failedListingClosesOnlyAnOpenFolder() throws {
        var tree = FileTree(roots: [dir("/src")])
        // Opened, its listing in flight, then closed — by ← or the chevron —
        // before the listing failed: the failure leaves it closed, rather
        // than reopening it empty with no listing coming.
        #expect(tree.toggleExpanded(path: "/src") == "/src")
        _ = tree.toggleExpanded(path: "/src")
        tree.collapse(path: "/src")
        #expect(tree.rows.map(\.expanded) == [false])
        #expect(tree.arrowStep(.right, from: "/src") == .expand("/src"))

        // Still open when the listing failed: closed back, and opening it
        // again asks for the listing again.
        #expect(tree.toggleExpanded(path: "/src") == "/src")
        tree.collapse(path: "/src")
        #expect(tree.rows.map(\.expanded) == [false])
        #expect(tree.toggleExpanded(path: "/src") == "/src")
    }

    @Test("an unknown path stays")
    func unknownPathStays() throws {
        // A selection left over from a search hit that is not a tree row.
        let tree = FileTree(roots: [dir("/src")])
        #expect(tree.arrowStep(.left, from: "/nope") == .stay)
        #expect(tree.arrowStep(.right, from: "/nope") == .stay)
    }
}
