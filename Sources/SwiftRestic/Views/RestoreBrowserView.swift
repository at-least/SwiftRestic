import SwiftUI

/// One repository's restore surface, laid out like the tools people already
/// know: the backup timeline on the left, the selected backup's file tree on
/// the right, search on top, Restore at the bottom. Switching backups keeps
/// the folder you are in.
struct RestoreBrowserTarget: Identifiable {
    var repositoryID: UUID
    var id: String { repositoryID.uuidString }
}

struct RestoreBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: RestoreBrowserTarget

    @State private var snapshots: [Snapshot] = []
    @State private var selectedID: Snapshot.ID?
    @State private var tree = FileTree(roots: [])
    /// The folder the tree is focused on — kept across snapshot switches.
    @State private var currentPath: String?
    @State private var changes: [String: ResticDiffChange] = [:]
    @State private var searchText = ""
    @State private var searchHits: [SearchHit]?
    @State private var selection: String?
    @State private var isLoadingTree = false
    @State private var loadError: String?
    /// Set when the focused folder does not exist in the selected snapshot.
    @State private var folderMissing = false
    /// Directories with a fetch already running — a double-click racing
    /// itself must not spawn duplicate listings.
    @State private var inFlightFetches: Set<String> = []

    private struct Level: Equatable {
        var snapshotID: String?
        var path: String?
    }

    private var level: Level {
        Level(snapshotID: selectedID, path: currentPath)
    }

    private var selected: Snapshot? {
        snapshots.first { $0.id == selectedID }
    }

    /// The backup immediately before the selected one — what the Change
    /// column compares against.
    private var predecessor: Snapshot? {
        guard let index = snapshots.firstIndex(where: { $0.id == selectedID }) else { return nil }
        let older = index + 1
        return older < snapshots.count ? snapshots[older] : nil
    }

    var body: some View {
        HSplitView {
            timeline
                .frame(minWidth: 190, maxWidth: 280)
            VStack(spacing: 0) {
                searchField
                Divider()
                breadcrumbBar
                Divider()
                browser
                Divider()
                footer
            }
            .frame(minWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, minHeight: 560)
        .task { await loadSnapshots() }
        .task(id: level) { await loadLevel() }
    }

    // MARK: - Timeline (left)

    private var timeline: some View {
        List(snapshots, selection: $selectedID) { snapshot in
            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                Text(snapshot.shortID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .tag(snapshot.id)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("\(Format.plural(snapshots.count, "backup"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .help("Pick a backup; the file tree on the right shows it")
    }

    // MARK: - Browser (right)

    private var searchField: some View {
        HStack(spacing: 8) {
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
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .onChange(of: searchText) { _, newValue in
            searchChanged(newValue)
        }
    }

    @ViewBuilder
    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            if searchHits != nil {
                Text("Search: \(Format.plural(searchHits!.count, "hit")) in this backup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let currentPath {
                PathBreadcrumb(path: currentPath, roots: selected?.paths ?? []) { target in
                    self.currentPath = target
                    selection = nil
                }
            } else {
                Text(selected.map { $0.time.formatted(date: .abbreviated, time: .shortened) } ?? "No backup selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !changes.isEmpty {
                Text("changes are against \(predecessor.map { Format.timestamp($0.time) } ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

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
                    description: Text("Other backups may hold it — clear the search and pick another backup on the left.")
                )
            } else {
                searchResults(hits)
            }
        } else if folderMissing {
            ContentUnavailableView {
                Label("Not in this backup", systemImage: "folder.badge.questionmark")
            } description: {
                Text("This folder does not exist in the selected backup. Pick another backup on the left, or go up a level.")
            }
        } else if tree.rows.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            treeList
        }
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
                if !row.node.isDirectory {
                    Text(Format.bytes(row.node.size))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                Text(Format.timestamp(row.node.mtime))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 140, alignment: .trailing)
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

    private var footer: some View {
        VStack(spacing: 10) {
            if let progress = model.restoreActivity {
                OperationProgressView(
                    title: model.restoreDescription,
                    progress: progress,
                    startedAt: nil,
                    onCancel: { model.cancelRestore() }
                )
            }
            HStack {
                Text("Restoring overwrites existing files at the destination.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.isRestoring ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(model.isRestoring ? "The restore keeps running" : "Close")
                Button("Restore Selected…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedRow == nil || model.isRestoring || selected == nil)
                    .help("Restore the selected item from the selected backup (Return)")
            }
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
                    .frame(width: 36, alignment: .leading)
            } else {
                Spacer().frame(width: 36)
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
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            goUp()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Loading

    private func loadSnapshots() async {
        snapshots = model.snapshots(for: target.repositoryID)
        selectedID = snapshots.first?.id
    }

    /// The selected snapshot changed: rebuild the tree, walk the preserved
    /// folder's spine back open, and load the change annotations. Search
    /// results belong to the backup they were searched in.
    private func loadLevel() async {
        searchHits = nil
        guard let selected else {
            tree = FileTree(roots: [])
            return
        }
        let spine = Self.spine(of: currentPath, under: selected.paths)
        tree.reset(to: selected.paths.map(SnapshotNode.directory))

        isLoadingTree = true
        loadError = nil
        folderMissing = false

        // Changes against the previous backup — one restic diff, streamed.
        if let predecessor {
            changes = await model.snapshotChanges(
                repositoryID: target.repositoryID,
                olderID: predecessor.id,
                newerID: selected.id
            )
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
                        repositoryID: target.repositoryID,
                        snapshotID: selected.id,
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
        guard let selected else { return }
        // One fetch per directory at a time: a double-click racing itself
        // must not land two listings (the tree is replace-idempotent, but
        // skipping the duplicate spares a restic round trip).
        guard !inFlightFetches.contains(needed) else { return }
        inFlightFetches.insert(needed)
        currentPath = path
        Task {
            defer { inFlightFetches.remove(needed) }
            let nodes = try? await model.children(
                repositoryID: target.repositoryID,
                snapshotID: selected.id,
                path: needed
            )
            guard let nodes else { return }
            tree.replaceChildren(of: needed, nodes: nodes)
        }
    }

    private func goUp() {
        guard let currentPath else { return }
        let roots = selected?.paths ?? []
        if roots.contains(currentPath) {
            self.currentPath = nil
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            self.currentPath = parent.isEmpty || parent == "/" ? nil : parent
        }
        selection = nil
    }

    /// Search runs against the index (instant) and is filtered to paths the
    /// selected backup contains — the tree on the right must stay honest
    /// about which backup it is showing.
    private func searchChanged(_ newValue: String) {
        let query = newValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let selected else {
            searchHits = nil
            return
        }
        Task {
            let hits = (try? await model.searchIndex(pattern: query, repositoryID: target.repositoryID)) ?? []
            var covered: [SearchHit] = []
            for hit in hits {
                let versions = await model.indexedVersions(ofPath: hit.path, repositoryID: target.repositoryID)
                if versions.contains(where: { $0.id == selected.id }) {
                    covered.append(hit)
                }
            }
            guard !Task.isCancelled else { return }
            searchHits = covered
            selection = nil
        }
    }

    private func restoreSelection() {
        guard let selected, let node = selectedRow else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(node.name)” from \(selected.time.formatted(date: .abbreviated, time: .shortened)). Restoring overwrites existing files at the destination.",
            prompt: "Restore"
        ) else { return }
        model.restore(
            repositoryID: target.repositoryID,
            snapshotID: selected.id,
            node: node,
            to: destination
        )
    }
}
