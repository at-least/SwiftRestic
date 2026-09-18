import SwiftUI

/// The restore pane: one backup record's file tree, browsed straight from
/// the sidebar's Restore section — Arq's arrangement, where picking a
/// dated record in the source list shows its files in the main pane.
///
/// The record is identified, not chosen here: the sidebar owns the timeline.
/// Switching records keeps the folder you are in; the restore progress strip
/// lives on the window above every pane, so it outlives a pane switch too.
struct RestorePaneView: View {
    @Environment(AppModel.self) private var model

    let repositoryID: UUID
    let snapshotID: String

    @State private var tree = FileTree(roots: [])
    /// The folder the tree is focused on — kept across record switches.
    @State private var currentPath: String?
    @State private var changes: [String: ResticDiffChange] = [:]
    @State private var searchText = ""
    @State private var searchHits: [SearchHit]?
    @State private var selection: String?
    @State private var isLoadingTree = false
    @State private var loadError: String?
    /// Set when the focused folder does not exist in the selected record.
    @State private var folderMissing = false
    /// The record the tree on screen was built for. A folder listing that
    /// lands after a record switch must not install itself into the new
    /// record's tree.
    @State private var loadedSnapshotID: String?
    /// Directories with a fetch already running — a double-click racing
    /// itself must not spawn duplicate listings.
    @State private var inFlightFetches: Set<String> = []
    /// The fetch tasks themselves, so the pane's departure can stop them:
    /// an expand that outlives the pane keeps a restic listing running and
    /// writes into state nobody reads any more.
    @State private var fetchTasks: [String: Task<Void, Never>] = [:]
    /// The query in flight, so the next keystroke cancels it: a slower older
    /// search finishing last must not overwrite the newer one's answers.
    @State private var searchTask: Task<Void, Never>?

    private var record: Snapshot? {
        model.snapshots(for: repositoryID).first { $0.id == snapshotID }
    }

    /// The backup immediately before the selected one — what the Change
    /// column compares against.
    private var predecessor: Snapshot? {
        let listing = model.snapshots(for: repositoryID)
        guard let index = listing.firstIndex(where: { $0.id == snapshotID }) else { return nil }
        let older = index + 1
        return older < listing.count ? listing[older] : nil
    }

    var body: some View {
        Group {
            // Nil-test, not a binding: the bound value is never read here —
            // the browser pane re-reads the property behind its own guards.
            if record != nil {
                browserPane()
            } else {
                ContentUnavailableView {
                    Label("Backup not found", systemImage: "questionmark.folder")
                } description: {
                    Text("This backup is no longer in the repository. Pick another one under Restore on the left.")
                }
            }
        }
        .navigationTitle("Restore")
        // The heavy reload — diff, tree rebuild, folder re-walk — belongs to
        // record switches only. Plain folder moves (expand, goUp, breadcrumb
        // jumps) change `currentPath` but must not rebuild anything: the tree
        // already holds the rows, and re-running the diff on every chevron
        // click would make a large repository feel broken.
        .task(id: snapshotID) { await loadLevel() }
        .onDisappear {
            // The pane's queries must not keep running — and keep writing —
            // after the pane is gone.
            searchTask?.cancel()
            for (_, task) in fetchTasks { task.cancel() }
        }
    }

    private func browserPane() -> some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            browser
            Divider()
            footer
        }
        .frame(minWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar (top)

    /// The header row is the search field and nothing else: which record is
    /// open is visible in the sidebar's selection, and the Change column
    /// speaks for itself — the pane repeats neither.
    private var toolbar: some View {
        HStack {
            Spacer()
            searchField
                .frame(width: 230)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search this repository's backups",
                text: $searchText
            )
            .textFieldStyle(.plain)
            if searchHits != nil {
                Button {
                    searchText = ""
                    searchHits = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onChange(of: searchText) { _, newValue in
            searchChanged(newValue)
        }
    }


    // MARK: - Browser

    @ViewBuilder
    private var browser: some View {
        if isLoadingTree {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Could not read this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if let hits = searchHits {
            if hits.isEmpty {
                ContentUnavailableView(
                    "No matches in this backup",
                    systemImage: "magnifyingglass",
                    description: Text("Other backups may hold it — clear the search and pick another backup under Restore on the left.")
                )
            } else {
                searchResults(hits)
            }
        } else if folderMissing {
            ContentUnavailableView {
                Label("Not in this backup", systemImage: "folder.badge.questionmark")
            } description: {
                Text("This folder does not exist in the selected backup. Pick another backup under Restore on the left, or go up a level.")
            }
        } else if tree.rows.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            VStack(spacing: 0) {
                columnHeader
                Divider()
                treeList
            }
        }
    }

    /// Arq's table header over the outline: the columns the rows below
    /// carry, aligned to the same fixed gutters.
    private var columnHeader: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 12)
            Spacer().frame(width: 16)
            Text("Item")
            Spacer(minLength: 12)
            Text("Change")
                .frame(width: 44, alignment: .leading)
            Text("Last Modified")
                .frame(width: 140, alignment: .trailing)
            Text("Size")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var treeList: some View {
        List(tree.rows, selection: $selection) { row in
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(row.depth) * 16)
                Group {
                    if row.node.isDirectory {
                        Button {
                            expand(path: row.node.path)
                        } label: {
                            Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                                .frame(width: 12)
                        }
                        .buttonStyle(.plain)
                        .help(row.expanded ? "Collapse" : "Expand")
                    } else {
                        Spacer().frame(width: 12)
                    }
                }
                Image(systemName: icon(for: row.node))
                    .foregroundStyle(row.node.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(row.node.name)
                    .lineLimit(1)
                Spacer()
                changeBadge(for: row.node.path)
                Text(Format.timestamp(row.node.mtime))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 140, alignment: .trailing)
                // Reserved even for directories: a branch-less cell becomes
                // an EmptyView, and EmptyView drops `.frame` — the mtime
                // column would slide into the Size column's spot.
                    Group {
                        if row.node.isDirectory {
                            Text(verbatim: "")
                        } else {
                            Text(Format.bytes(row.node.size))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(width: 70, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if row.node.isDirectory { expand(path: row.node.path) }
            }
            .tag(row.id)
        }
        .listStyle(.inset)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .help("Return expands a folder; ⌘↑ or ⌫ goes up; double-click also expands")
    }

    private func searchResults(_ hits: [SearchHit]) -> some View {
        List(hits, selection: $selection) { hit in
            HStack(spacing: 6) {
                Image(systemName: hit.isDirectory == true ? "folder.fill" : "doc")
                    .foregroundStyle(hit.isDirectory == true ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text((hit.path as NSString).lastPathComponent)
                    .lineLimit(1)
                Spacer()
                Text((hit.path as NSString).deletingLastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .contentShape(Rectangle())
            .tag(hit.path)
        }
        .listStyle(.inset)
    }

    /// One button, Arq-style: the overwrite consequence is named where the
    /// decision happens — the destination dialog's message — not as a
    /// permanent caption under every browse.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Restore…") { restoreSelection() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRow == nil || model.isRestoring || record == nil)
                .help("Restore the selected item from this backup (Return)")
        }
        .padding(12)
    }

    // MARK: - Rows

    /// The node behind the current selection: a tree row while browsing, a
    /// synthesized hit while searching. Search hits were already filtered to
    /// paths the selected backup contains.
    private var selectedRow: SnapshotNode? {
        guard let selection else { return nil }
        if let hits = searchHits,
           let hit = hits.first(where: { $0.path == selection }) {
            let name = (hit.path as NSString).lastPathComponent
            return SnapshotNode(
                name: name.isEmpty ? hit.path : name,
                type: hit.isDirectory == true ? .dir : .file,
                path: hit.path
            )
        }
        return tree.node(at: selection)
    }

    private func changeBadge(for path: String) -> some View {
        Group {
            if let change = changes[path] {
                Text(verbatim: change.modifier)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(change.category == .added ? Theme.success : Theme.warning)
                    .help(change.explanation)
                    .frame(width: 44, alignment: .leading)
            } else {
                Spacer().frame(width: 44)
            }
        }
    }

    private func icon(for node: SnapshotNode) -> String {
        switch node.type {
        case .dir: "folder.fill"
        case .symlink: "arrow.turn.up.right"
        case .file: "doc"
        default: "questionmark.square.dashed"
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            if let node = selectedRow, node.isDirectory {
                expand(path: node.path)
                return .handled
            }
            return .ignored
        case .delete:
            guard currentPath != nil else { return .ignored }
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            guard currentPath != nil else { return .ignored }
            goUp()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Navigation

    /// Moves to a folder, or back to the root level with nil: the tree on
    /// screen already holds every loaded row, so this is only a focus change.
    /// Re-focusing the current folder is a no-op that keeps the selection.
    private func navigate(to path: String?) {
        guard path != currentPath else { return }
        currentPath = path
        selection = nil
    }

    // MARK: - Loading

    /// The selected record changed: rebuild the tree, walk the preserved
    /// folder's spine back open, and load the change annotations. Search
    /// belongs to the record it was searched in — both the hits and the
    /// query go, or the field would sit there filtered-looking with its
    /// clear button gone.
    private func loadLevel() async {
        searchHits = nil
        searchText = ""
        guard let record else {
            tree = FileTree(roots: [])
            return
        }
        loadedSnapshotID = record.id
        let spine = Self.spine(of: currentPath, under: record.paths)
        tree.reset(to: record.paths.map(SnapshotNode.directory))

        isLoadingTree = true
        loadError = nil
        folderMissing = false

        // Changes against the previous backup — one restic diff, streamed.
        if let predecessor {
            changes = await model.snapshotChanges(
                repositoryID: repositoryID,
                olderID: predecessor.id,
                newerID: record.id
            )
            // A record switch during the diff must not install the old
            // record's change map into the new one's rows.
            guard !Task.isCancelled else { return }
        } else {
            changes = [:]
        }

        // Re-open the folder the user was in. The first missing ancestor
        // stops the walk: this backup does not contain that folder.
        var deepest: String?
        for step in spine {
            if let needed = tree.toggleExpanded(path: step) {
                do {
                    let nodes = try await model.children(
                        repositoryID: repositoryID,
                        snapshotID: record.id,
                        path: needed
                    )
                    guard !Task.isCancelled else { return }
                    tree.replaceChildren(of: needed, nodes: nodes)
                } catch {
                    guard !Task.isCancelled else { return }
                    folderMissing = true
                    isLoadingTree = false
                    return
                }
            }
            deepest = step
        }
        if let deepest { currentPath = deepest }
        guard !Task.isCancelled else { return }
        isLoadingTree = false
    }

    /// The folder's ancestor chain, deepest-containing-root first — the order
    /// the tree must be expanded in to bring `currentPath` back on screen.
    private static func spine(of path: String?, under roots: [String]) -> [String] {
        guard let path else { return [] }
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            return [path]
        }
        var spine: [String] = [root]
        var walked = root
        for segment in path.dropFirst(root.count + 1).split(separator: "/") {
            walked = walked == "/" ? "/\(segment)" : walked + "/\(segment)"
            spine.append(walked)
        }
        return spine
    }

    private func expand(path: String) {
        guard let needed = tree.toggleExpanded(path: path) else { return }
        guard let record else { return }
        // One fetch per directory at a time: a double-click racing itself
        // must not land two listings (the tree is replace-idempotent, but
        // skipping the duplicate spares a restic round trip).
        guard !inFlightFetches.contains(needed) else { return }
        inFlightFetches.insert(needed)
        navigate(to: path)
        fetchTasks[needed] = Task {
            defer {
                inFlightFetches.remove(needed)
                fetchTasks[needed] = nil
            }
            do {
                let nodes = try await model.children(
                    repositoryID: repositoryID,
                    snapshotID: record.id,
                    path: needed
                )
                // The fetch may have raced a record switch; the new record's
                // tree must stay that record's.
                guard loadedSnapshotID == record.id, !Task.isCancelled else { return }
                tree.replaceChildren(of: needed, nodes: nodes)
            } catch {
                guard loadedSnapshotID == record.id, !Task.isCancelled else { return }
                // The chevron opened a folder that never arrived — close it
                // back and say why, instead of an empty expansion.
                _ = tree.toggleExpanded(path: path)
                loadError = error.localizedDescription
            }
        }
    }

    private func goUp() {
        guard let currentPath else { return }
        let roots = record?.paths ?? []
        if roots.contains(currentPath) {
            navigate(to: nil)
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            navigate(to: parent.isEmpty || parent == "/" ? nil : parent)
        }
    }

    /// Search runs against the index (instant) and is filtered to paths the
    /// selected record contains — the tree must stay honest about which
    /// backup it is showing.
    private func searchChanged(_ newValue: String) {
        let query = newValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let record else {
            searchTask?.cancel()
            searchHits = nil
            return
        }
        // The results must answer to what was typed and the record they were
        // searched in: both are snapshotted before the awaits, and anything
        // that lands after a keystroke or a record switch is discarded —
        // same contract FindFilesView's search runs under.
        let searchedRecordID = record.id
        searchTask?.cancel()
        searchTask = Task {
            // An index failure is its own answer — a confident "no matches"
            // would be the one lie a search tool cannot tell.
            let hits: [SearchHit]
            do {
                hits = try await model.searchIndex(pattern: query, repositoryID: repositoryID)
            } catch {
                guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
                loadError = (error as? ResticError)?.errorDescription ?? error.localizedDescription
                return
            }
            var covered: [SearchHit] = []
            for hit in hits {
                if Task.isCancelled { return }
                let versions = await model.indexedVersions(ofPath: hit.path, repositoryID: repositoryID)
                if versions.contains(where: { $0.id == searchedRecordID }) {
                    covered.append(hit)
                }
            }
            guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
            searchHits = covered
            selection = nil
        }
    }

    private func restoreSelection() {
        guard let record, let node = selectedRow else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(node.name)” from \(record.time.formatted(date: .abbreviated, time: .shortened)). Restoring overwrites existing files at the destination.",
            prompt: "Restore"
        ) else { return }
        model.restore(
            repositoryID: repositoryID,
            snapshotID: record.id,
            node: node,
            to: destination
        )
    }
}
