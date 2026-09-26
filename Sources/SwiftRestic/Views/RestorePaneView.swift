import SwiftUI

/// The restore pane: one backup record's file tree, browsed straight from
/// the sidebar's Restore section — Arq's arrangement, where picking a
/// dated record in the source list shows its files in the main pane.
///
/// The app's one snapshot-first browser: the Snapshots tables' Browse, both
/// Restore Files… buttons and Browse Folders' Show in Restore all land here
/// (`AppRouter.showRestore`), so the Change column, search, drag-to-Finder
/// and whole-backup restore never depend on which button you came through.
///
/// The record is identified, not chosen here: the sidebar owns the timeline.
/// Switching records keeps the folder you are in; the restore progress strip
/// lives on the window above every pane, so it outlives a pane switch too.
struct RestorePaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    let repositoryID: UUID
    let snapshotID: String

    @State private var tree = FileTree(roots: [])
    /// The folder the tree is focused on — kept across record switches.
    @State private var currentPath: String?
    @State private var changes: [String: ResticDiffChange] = [:]
    /// What `changes` was computed against, for the header. Written beside
    /// the map in `loadLevel`, never re-derived from the listing: the diff
    /// does not rerun when the listing changes, and the header must name the
    /// comparison whose marks are on screen.
    @State private var comparison: ChangeComparison?
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
    /// A routed focus folder the tree should scroll to once it is on screen —
    /// set by `loadLevel`, spent by the list. Plain record switches keep
    /// their folder open but never scroll.
    @State private var revealPath: String?
    /// The restore waiting in the destination sheet.
    @State private var destinationRequest: RestoreDestinationRequest?

    private var record: Snapshot? {
        model.snapshots(for: repositoryID).first { $0.id == snapshotID }
    }

    /// What the Change column compares against: the previous backup of the
    /// same folders from the same host, not the row above in a repository
    /// several plans share. Nil for a lineage's first backup, which shows no
    /// marks rather than a diff against an unrelated tree.
    private var predecessor: Snapshot? {
        SnapshotLineage.changeBaseline(for: snapshotID, in: model.snapshots(for: repositoryID))
    }

    var body: some View {
        // One snapshot-list scan per render: the nil-test here and the
        // footer's restore button both need the record, and the computed
        // property re-scans the repository's whole snapshot list at every
        // access.
        let currentRecord = record
        return Group {
            // Nil-test, not a binding: the bound value is never read here —
            // the browser pane re-reads the property behind its own guards.
            if currentRecord != nil {
                browserPane(record: currentRecord)
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
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        .onDisappear {
            // The pane's queries must not keep running — and keep writing —
            // after the pane is gone.
            searchTask?.cancel()
            for (_, task) in fetchTasks { task.cancel() }
        }
    }

    private func browserPane(record: Snapshot?) -> some View {
        VStack(spacing: 0) {
            // A restore started here ends here: the result — Reveal in
            // Finder, what Keep kept, a failure — lands at the top of the
            // pane, where Activity and the console carry the same queue,
            // right under the window's restore strip whose place it takes.
            // Its own view, so a banner never re-renders the tree. It claims
            // height before the tree does: an equal share, which the stack
            // gives by default, cut three queued restore banners to a line
            // each and dropped the newest one's "Kept N existing files" —
            // while the tree, which scrolls, keeps a floor of a few rows.
            RestorePaneBanners()
                .layoutPriority(1)
            toolbar(record: record)
            Divider()
            // Its own view, reading the run history itself: a new run
            // record re-renders the strip, never the tree below it.
            IncompleteSnapshotStrip(snapshotID: snapshotID)
            browser
                .frame(minHeight: 120)
            Divider()
            footer(record: record)
        }
        .frame(minWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar (top)

    /// The open backup's name and what its Change column is compared with,
    /// then the search field. fd691ee dropped this header on the grounds that
    /// the sidebar's selection names the record and the column speaks for
    /// itself; neither holds. With the sidebar hidden nothing else names the
    /// open backup — the window title is always "Restore" — and a blank
    /// Change column can mean a first backup, no changes, a comparison still
    /// running, or a failed one. Only this line tells them apart.
    private func toolbar(record: Snapshot?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let record {
                RestoreRecordHeader(
                    repositoryID: repositoryID,
                    record: record,
                    // For the frame between a record switch and loadLevel's
                    // first line, `comparison` still belongs to the previous
                    // record; the header shows none rather than that one.
                    comparison: loadedSnapshotID == record.id ? comparison : nil
                )
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
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
        ScrollViewReader { proxy in
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
                    Image(systemName: row.node.browserIconName)
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
                // Arq's signature restore gesture: drag straight out of the tree
                // into Finder. Tree rows only — a search hit's kind is the
                // index's guess, and a folder dumped as a file lands as a tar.
                .onDrag { dragProvider(for: row.node) }
                .tag(row.id)
            }
            .listStyle(.inset)
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .help("Return expands a folder; ⌘↑ or ⌫ goes up; double-click also expands; drag an item to Finder to restore it there")
            // Initial as well: the routed focus is set while the spinner stands
            // in for this list, so the list meets it on its first appearance.
            .onChange(of: revealPath, initial: true) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                revealPath = nil
            }
        }
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

    /// Arq's three ways out of a record, in one row: the primary Restore…
    /// for the selection on the right, the whole backup as the secondary
    /// action on the left, and the drag named in between — Arq's "Drag and
    /// drop to the desktop or a Finder window or click Restore:". The hint
    /// shows only over the tree, the one list whose rows drag. The
    /// keep/replace decision happens in the destination sheet, not as a
    /// permanent caption under every browse.
    private func footer(record: Snapshot?) -> some View {
        HStack(spacing: 12) {
            Button("Restore Entire Backup…") { restoreWholeRecord() }
                .disabled(model.isRestoring || record == nil)
                .help("Restore everything in this backup — each folder is recreated under its full original path inside the folder you choose")
            Spacer(minLength: 12)
            if treeIsShowing {
                Text("Drag an item to Finder to restore it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Restore…") { restoreSelection() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRow == nil || model.isRestoring || record == nil)
                .help("Restore the selected item from this backup (Return)")
        }
        .padding(12)
    }

    /// The browser's final branch — the tree list, and nothing standing in
    /// for it (spinner, error, search results, missing folder, empty folder).
    private var treeIsShowing: Bool {
        !isLoadingTree && loadError == nil && searchHits == nil && !folderMissing && !tree.rows.isEmpty
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

    /// The record a drag names is the one the rows on screen were built
    /// for: the `snapshotID` prop moves on a record switch one update before
    /// `loadLevel` rebuilds the tree.
    private func dragProvider(for node: SnapshotNode) -> NSItemProvider {
        guard let loadedSnapshotID else { return NSItemProvider() }
        return model.dragRestoreProvider(repositoryID: repositoryID, snapshotID: loadedSnapshotID, node: node)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // The shared Finder grammar, with this pane's open action: a
        // directory's Return expands it in place rather than entering it —
        // the tree already holds every loaded row.
        BrowserListGrammar.keyPress(
            press,
            selected: selectedRow,
            hasParent: currentPath != nil,
            open: { expand(path: $0.path) },
            goUp: { goUp() }
        )
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
            comparison = nil
            return
        }
        // Show in Restore's folder, when the route asked for this record:
        // walked open by the same spine a record switch re-walks. A path
        // outside the record's roots is dropped, not walked.
        let focus = router.takeRestoreFocus(repositoryID: repositoryID, snapshotID: record.id)
        if let focus, !Format.pathChain(of: focus, roots: record.paths).isEmpty {
            currentPath = focus
        }
        loadedSnapshotID = record.id
        let spine = currentPath.map { Format.pathChain(of: $0, roots: record.paths) } ?? []
        tree.reset(to: record.paths.map(SnapshotNode.directory))

        isLoadingTree = true
        loadError = nil
        folderMissing = false

        // Changes against the previous backup — one restic diff, streamed.
        if let predecessor {
            comparison = .comparing(baseline: predecessor)
            let marks = await model.snapshotChanges(
                repositoryID: repositoryID,
                olderID: predecessor.id,
                newerID: record.id
            )
            // A record switch during the diff must not install the old
            // record's change map into the new one's rows, nor its baseline
            // into the new one's header: both are written after this guard.
            guard !Task.isCancelled else { return }
            changes = marks.changes
            comparison = marks.failure.map { .failed(baseline: predecessor, reason: $0) }
                ?? .compared(baseline: predecessor, changeCount: marks.changes.count)
        } else {
            changes = [:]
            comparison = .firstBackup
        }

        // Re-open the folder the user was in. The first missing ancestor
        // stops the walk: this backup does not contain that folder — a
        // listing that answers without it is as much an answer as a failed
        // fetch, and the pane must say so rather than showing a shallower
        // tree with breadcrumbs that claim the deeper path.
        var deepest: String?
        for step in spine {
            guard tree.node(at: step) != nil else {
                guard !Task.isCancelled else { return }
                folderMissing = true
                isLoadingTree = false
                return
            }
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
        // The routed folder is open: select it and bring it on screen.
        if let focus, deepest == focus {
            selection = focus
            revealPath = focus
        }
        isLoadingTree = false
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
                // A folder that answers heals the pane: `loadError` replaces
                // the whole browser, so a transient failure must not outlive
                // the next successful read.
                loadError = nil
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
            navigate(to: BrowserListGrammar.parent(of: currentPath))
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
            // Back on the tree means back on the tree: a stale load error
            // replaces the whole browser, and clearing the search is a fresh
            // look, not a still-failing one.
            loadError = nil
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
            // would be the one lie a search tool cannot tell. The coverage
            // walk reads through the same index, so its failure says the
            // same thing and lands in the same catch.
            let hits: [SearchHit]
            let versionsByPath: [String: [IndexedSnapshot]]
            do {
                hits = try await model.searchIndex(pattern: query, repositoryID: repositoryID)
                versionsByPath = try await model.indexedVersions(
                    ofPaths: hits.map(\.path), repositoryID: repositoryID
                )
            } catch {
                guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
                loadError = (error as? ResticError)?.errorDescription ?? error.localizedDescription
                return
            }
            guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
            let covered = hits.filter { hit in
                versionsByPath[hit.path]?.contains { $0.id == searchedRecordID } == true
            }
            searchHits = covered
            selection = nil
            // The index answered: a load error from an earlier failed read
            // must not sit in front of these results or behind them.
            loadError = nil
        }
    }

    private func restoreSelection() {
        guard let record, let node = selectedRow else { return }
        let repositoryID = repositoryID
        destinationRequest = RestoreDestinationRequest(
            subject: .item(name: node.name, path: node.path, isDirectory: node.isDirectory),
            backupTime: record.time,
            snapshotShortID: record.shortID
        ) { destination, overwrite in
            model.restore(
                repositoryID: repositoryID,
                snapshotID: record.id,
                node: node,
                to: destination,
                overwrite: overwrite
            )
        }
    }

    /// The whole record, named the way the header and the sidebar name it
    /// and dated; the sheet says the layout restic will produce: `restore
    /// <id> --target` recreates every absolute path under the target.
    private func restoreWholeRecord() {
        guard let record else { return }
        let repositoryID = repositoryID
        destinationRequest = RestoreDestinationRequest(
            subject: .wholeSnapshot(paths: record.paths),
            backupName: SnapshotLineage.displayName(
                of: record,
                label: model.lineageLabel(of: record, repositoryID: repositoryID)
            ),
            backupTime: record.time,
            snapshotShortID: record.shortID
        ) { destination, overwrite in
            model.restoreWholeSnapshot(
                repositoryID: repositoryID,
                snapshotID: record.id,
                to: destination,
                overwrite: overwrite
            )
        }
    }
}

/// The shared banner queue at the top of the Restore pane. Never
/// height-pinned (BannerView's rule): the pane does not scroll as a whole.
/// Newer banners claim height first, so when the pane runs short the oldest
/// is the one cut, never the result of the restore just finished.
private struct RestorePaneBanners: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.banners.isEmpty {
            VStack(spacing: 8) {
                let banners = model.banners
                ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                    BannerView(banner: banner)
                        .layoutPriority(Double(banners.count - index))
                }
            }
            .padding([.horizontal, .top], 12)
        }
    }
}

/// The toolbar's leading side: which backup is open, and what its Change
/// column compares it with. Its own view because it reads the plans and the
/// lineages: a run-record or settings write re-renders this line, never the
/// tree beside it.
private struct RestoreRecordHeader: View {
    @Environment(AppModel.self) private var model

    let repositoryID: UUID
    let record: Snapshot
    let comparison: ChangeComparison?

    var body: some View {
        let heading = RestoreRecordHeading(
            record: record,
            label: model.lineageLabel(of: record, repositoryID: repositoryID),
            comparison: comparison
        )
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                // The name gives way in the middle; the day never does.
                Text(heading.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "—")
                    .accessibilityHidden(true)
                Text(heading.time)
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            HStack(spacing: 4) {
                // Orange only on the glyph, beside words that already say
                // it: the caption stays secondary for contrast.
                if heading.isProblem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                }
                Text(heading.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption)
        }
        .help(heading.detail)
    }
}

/// Shown above the tree for a backup restic wrote with exit code 3: what it
/// could not read, in place — "is my file missing from this backup?" is
/// answered here, not only in Activity. The first few items inline; the
/// drawer in Activity holds every stored line, and the button lands there
/// on the run that wrote it. Renders nothing (and no divider) otherwise.
private struct IncompleteSnapshotStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    let snapshotID: String

    /// Enough to answer the question for the usual one or two items without
    /// growing into a second scrolling list above the tree.
    private static let shownItems = 3

    var body: some View {
        if let run = model.backupRun(forSnapshot: snapshotID), run.snapshotCompleteness == .incomplete {
            strip(run)
            Divider()
        }
    }

    private func strip(_ run: RunRecord) -> some View {
        let unreadable = run.itemErrorCount
        let lines = Array(run.unreadableItems.prefix(Self.shownItems))
        return HStack(alignment: .top, spacing: 8) {
            // Beside words that say the same thing: decoration to VoiceOver.
            Image(systemName: RunRecord.Outcome.completedWithErrors.symbolName ?? "exclamationmark.triangle.fill")
                .foregroundStyle(ChartPalette.status(.completedWithErrors))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(unreadable > 0
                    ? "This backup is incomplete: restic could not read \(Format.plural(unreadable, "item")) when it was made."
                    : "This backup is incomplete: restic could not read some of the source data when it was made, and did not name it.")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(line)
                        .textSelection(.enabled)
                }
                if unreadable > lines.count, !lines.isEmpty {
                    Text("and \(Format.count(unreadable - lines.count)) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Show in Activity") {
                // A problem run, so the problems filter already shows it;
                // the landing leaves that filter as the user set it.
                router.activityFocusRunID = run.id
                router.selection = .activity
            }
            .controlSize(.small)
            .help("Select the run that made this backup in Activity")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}
