import SwiftUI

/// One repository's restore surface, laid out like Arq's: the backup
/// records in a source list on the left, the selected backup's file tree
/// on the right under a "Backup: …" title with back/forward arrows, a
/// columned file table, search on top, Restore at the bottom right.
/// Switching backups keeps the folder you are in.
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
    /// The folder trail behind the back/forward arrows. Entries are the
    /// `currentPath` at each step; nil is the records' root level.
    @State private var navHistory: [String?] = [nil]
    @State private var navIndex = 0
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

    private var repositoryName: String {
        model.configuration.repositories.first { $0.id == target.repositoryID }?.name ?? "Repository"
    }

    private var canGoBack: Bool { navIndex > 0 }
    private var canGoForward: Bool { navIndex + 1 < navHistory.count }

    var body: some View {
        HSplitView {
            timeline
                .frame(minWidth: 200, maxWidth: 300)
            VStack(spacing: 0) {
                toolbar
                Divider()
                if searchHits != nil || currentPath != nil {
                    breadcrumbBar
                    Divider()
                }
                browser
                Divider()
                footer
            }
            .frame(minWidth: 640)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 940, minHeight: 560)
        .task { await loadSnapshots() }
        .task(id: level) { await loadLevel() }
    }

    // MARK: - Timeline (left)

    private var timeline: some View {
        VStack(spacing: 0) {
            // Arq's source-list header: the caps section label with the
            // backup set's name under it — here the repository being
            // restored from.
            VStack(alignment: .leading, spacing: 2) {
                Text("RESTORE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(repositoryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            List(snapshots, selection: $selectedID) { snapshot in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .font(.caption)
                        .help("This backup is complete and restorable")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.timestamp(snapshot.time))
                            .lineLimit(1)
                        Text(snapshot.shortID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .tag(snapshot.id)
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(Format.plural(snapshots.count, "backup"))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .help("Pick a backup; the file tree on the right shows it")
    }

    // MARK: - Toolbar (right, top)

    /// Arq's header band: back/forward arrows, the bold "Backup: …" title,
    /// and the search field on the right.
    private var toolbar: some View {
        HStack(spacing: 10) {
            navButtons
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    selected.map { "Backup: \(Format.timestamp($0.time))" }
                        ?? "No backup selected"
                )
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                if let selected {
                    Text(selected.shortID)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            if !changes.isEmpty {
                Text("changes are against \(predecessor.map { Format.timestamp($0.time) } ?? "—")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            searchField
                .frame(width: 230)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The back/forward pair as one bordered capsule, Arq-style.
    private var navButtons: some View {
        HStack(spacing: 0) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 20)
                    .foregroundStyle(canGoBack ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .help("Go back (⌘←)")
            Divider().frame(height: 12)
            Button {
                goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 20)
                    .foregroundStyle(canGoForward ? Color.primary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .help("Go forward (⌘→)")
        }
        .padding(.horizontal, 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.15))
        )
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

    @ViewBuilder
    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            if let hits = searchHits {
                Text("Search: \(Format.plural(hits.count, "hit")) in this backup")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let currentPath {
                PathBreadcrumb(path: currentPath, roots: selected?.paths ?? []) { target in
                    navigate(to: target)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // MARK: - Browser (right)

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
                Button("Restore…") { restoreSelection() }
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
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            goUp()
            return .handled
        case .leftArrow where press.modifiers.contains(.command):
            goBack()
            return .handled
        case .rightArrow where press.modifiers.contains(.command):
            goForward()
            return .handled
        default:
            return .ignored
        }
    }

    // MARK: - Navigation

    /// Pushes a folder onto the navigation trail, dropping any forward
    /// branch — the standard back/forward stack behaviour.
    private func navigate(to path: String?) {
        guard path != navHistory[navIndex] else { return }
        if navIndex + 1 < navHistory.count {
            navHistory.removeSubrange((navIndex + 1)...)
        }
        navHistory.append(path)
        navIndex += 1
        currentPath = path
        selection = nil
    }

    private func goBack() {
        guard canGoBack else { return }
        navIndex -= 1
        currentPath = navHistory[navIndex]
        selection = nil
    }

    private func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        currentPath = navHistory[navIndex]
        selection = nil
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
        navigate(to: path)
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
            navigate(to: nil)
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            navigate(to: parent.isEmpty || parent == "/" ? nil : parent)
        }
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
