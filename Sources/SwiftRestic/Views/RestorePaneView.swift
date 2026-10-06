import SwiftUI

/// The restore pane: one backup record's file tree. The app's one
/// snapshot-first browser — the run drawer's Browse, a group's Restore
/// Files… and the Files view's Show in Backups all land here
/// (`AppRouter.showRestore`) — so the Change column, search, drag-to-Finder
/// and whole-backup restore never depend on which button you came through.
///
/// The sidebar owns the timeline; a record is identified, not chosen, here.
/// Switching records keeps the folder you are in, and the restore progress
/// strip lives on the window above every pane, so it outlives a pane switch.
struct RestorePaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router

    let repositoryID: UUID
    let snapshotID: String
    /// "Search All Backups…": the host opens Find Files on this repository
    /// with the query filled in.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    @State private var tree = FileTree(roots: [])
    /// The folder the tree is focused on — kept across record switches.
    @State private var currentPath: String?
    @State private var changes: [String: ResticDiffChange] = [:]
    /// What `changes` was computed against, for the header: written beside
    /// the map in `loadLevel`, never re-derived — the header must name the
    /// comparison whose marks are on screen.
    @State private var comparison: ChangeComparison?
    @State private var searchText = ""
    /// The search's answer for the open backup; nil while not searching.
    @State private var searchResult: RestorePaneSearch?
    /// The selected rows' ids — paths in the tree, `SearchHit.id` among
    /// search results. Several at once, as in Finder (⌘- or ⇧-click):
    /// Restore… restores them together.
    @State private var selection: Set<String> = []
    /// The tree's or the search results' keyboard focus, whichever is on
    /// screen — taken by a click in it (`focusOnClick`).
    @FocusState private var listIsFocused: Bool
    @State private var isLoadingTree = false
    @State private var loadError: String?
    /// Set when the focused folder does not exist in the selected record.
    @State private var folderMissing = false
    /// The record the tree on screen was built for. A folder listing that
    /// lands after a record switch must not install itself into the new
    /// record's tree.
    @State private var loadedSnapshotID: String?
    /// The fetch tasks, so the pane's departure can stop them: an expand
    /// that outlives the pane keeps a restic listing running and writes
    /// into state nobody reads. A key present is a fetch already running.
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
    /// The tree rows' content width, read by the column header alone: a
    /// legacy scroller narrows the rows but not the header above them, and
    /// the header has no other way to know it is there. Held in a box, not
    /// pane state — the width changes on every resize step, and pane state
    /// would re-render the whole tree each step.
    @State private var rowContentWidth = RowContentWidth()

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
        // One snapshot-list scan per render: the nil-test and the footer's
        // restore button both need the record, and the computed property
        // re-scans the repository's whole snapshot list at every access.
        let currentRecord = record
        return Group {
            if currentRecord != nil {
                browserPane(record: currentRecord)
            } else {
                ContentUnavailableView {
                    Label("Backup not found", systemImage: "questionmark.folder")
                } description: {
                    Text("This backup is no longer in the repository. Pick another one in the sidebar.")
                }
            }
        }
        .navigationTitle("Restore")
        // The heavy reload — diff, tree rebuild, folder re-walk — belongs to
        // record switches only: folder moves change `currentPath` alone, the
        // tree already holds their rows, and re-running the diff on every
        // chevron click would make a large repository feel broken.
        .task(id: snapshotID) { await loadLevel() }
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        .onDisappear {
            // The pane's queries must not keep running after the pane is gone.
            searchTask?.cancel()
            for (_, task) in fetchTasks { task.cancel() }
        }
    }

    private func browserPane(record: Snapshot?) -> some View {
        VStack(spacing: 0) {
            // A restore started here ends here: the result lands at the top
            // of the pane, under the window's restore strip whose place it
            // takes. Its own view, so a banner never re-renders the tree.
            // Claims height before the tree: at the stack's equal default
            // share, queued banners are cut to a line each, while the
            // scrolling tree keeps a floor of a few rows.
            RestorePaneBanners()
                .layoutPriority(1)
            toolbar(record: record)
            Divider()
            // Its own view, reading the run history itself: a new run
            // record re-renders the strip, never the tree below it.
            IncompleteSnapshotStrip(snapshotID: snapshotID, repositoryID: repositoryID)
            // Filling, whatever stands in for the tree: a
            // ContentUnavailableView answers its own height, and without
            // this the pane floats mid-window.
            browser
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            Divider()
            footer(record: record)
        }
        // Fits the narrowest detail column the window allows: its 940-pt
        // minimum less the sidebar at its 340-pt maximum and the split's
        // 8 pt (SwiftResticApp.swift, SidebarView.swift). Still a minimum:
        // it also bounds the split view's zero-width sizing query.
        .frame(minWidth: 592)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar (top)

    /// The open backup's name and what its Change column is compared with,
    /// then the search field, which searches the open backup — Repository ▸
    /// Find Files in Snapshots… (⇧⌘F) searches every backup. With the
    /// sidebar hidden nothing else names the open backup or tells a blank
    /// Change column's meanings apart: first backup, no changes, still
    /// comparing, failed.
    private func toolbar(record: Snapshot?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let record {
                RestoreRecordHeader(
                    repositoryID: repositoryID,
                    record: record,
                    // Between a record switch and loadLevel's first line,
                    // `comparison` still belongs to the previous record;
                    // show none rather than that one.
                    comparison: loadedSnapshotID == record.id ? comparison : nil
                )
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
            SearchField(placeholder: "Search this backup", text: $searchText)
                .frame(width: 230)
                .onChange(of: searchText) { _, newValue in
                    searchChanged(newValue)
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
        } else if let result = searchResult {
            if result.inThisBackup.isEmpty {
                // Not a dead end: the index knows whether other backups
                // hold a match, and Find Files lists them with their dates.
                ContentUnavailableView {
                    Label("No matches in this backup", systemImage: "magnifyingglass")
                } description: {
                    Text(result.note ?? "No other backup matches either, as far as the search index has read.")
                } actions: {
                    searchAllButton
                }
            } else {
                searchResults(result.inThisBackup)
            }
        } else if folderMissing {
            ContentUnavailableView {
                Label("Not in this backup", systemImage: "folder.badge.questionmark")
            } description: {
                Text("This folder does not exist in the selected backup. Pick another backup in the sidebar, or go up a level.")
            }
        } else if tree.rows.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            VStack(spacing: 0) {
                TreeColumnHeader(rowContentWidth: rowContentWidth)
                Divider()
                treeList
            }
        }
    }

    private var treeList: some View {
        ScrollViewReader { proxy in
            List(tree.rows, selection: $selection) { row in
                HStack(spacing: 6) {
                    Spacer().frame(width: CGFloat(row.depth) * 16)
                    Group {
                        if row.node.isDirectory {
                            disclosure(for: row)
                        } else {
                            Spacer().frame(width: 20)
                        }
                    }
                    // SF Symbols' own labels name the picture ("Move" for
                    // folder.fill); the kind is what the row means.
                    Image(systemName: row.node.browserIconName)
                        .foregroundStyle(row.node.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                        .accessibilityLabel(row.node.kindName)
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
                // The column header copies this width — a geometry read; the
                // row carries no gesture (see the drag below).
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if rowContentWidth.value != width { rowContentWidth.value = width }
                }
                // Drag straight out of the tree into Finder, as from the
                // search's hits below.
                //
                // The list's own drag, not `.onDrag`, and no gesture on the
                // row: a SwiftUI gesture claims every click inside what it
                // covers, so a click on a row's name or icon would never
                // select it.
                .itemProvider { listDragProvider(for: row.node) }
                .tag(row.id)
            }
            .listStyle(.inset)
            .focusOnClick($listIsFocused)
            // Double-click, the list's way: it expands a folder, as the
            // chevron does, and leaves a file alone. The list also sends
            // Return here — Return is spent in `handleKeyPress` first.
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let path = ids.first, let node = tree.node(at: path) {
                    showVersionsItem(path: node.path, isDirectory: node.isDirectory)
                }
            } primaryAction: { ids in
                guard ids.count == 1, let path = ids.first,
                      tree.node(at: path)?.isDirectory == true
                else { return }
                expand(path: path)
            }
            .onKeyPress(phases: .down) { press in
                // Left's parent may sit above the visible rows; the list
                // does not follow a selection it did not make itself.
                handleKeyPress(press) { proxy.scrollTo($0) }
            }
            .help("→ or Return expands a folder; ← collapses it or selects the folder above; ⌘↑ or ⌫ goes up; double-click also expands; ⌘- or ⇧-click selects several items; drag an item to Finder to restore it there")
            // Initial as well: the routed focus is set while the spinner stands
            // in for this list, so the list meets it on its first appearance.
            .onChange(of: revealPath, initial: true) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                revealPath = nil
            }
        }
    }

    /// A folder row's disclosure chevron: the macOS minimum control size,
    /// 20×20, padded 2 pt past its 16-pt box so the row stays 24 pt like a
    /// file row — padding outside the Button, which inside its label
    /// hit-tests only its 20×16 box. The Button carries the drag itself:
    /// the list's drag never starts on the Button, so without it the
    /// chevron is the one part of the row a drag to Finder cannot start
    /// from. Labelled for its folder; the symbol's own labels are
    /// "Forward" and "Go Down".
    private func disclosure(for row: FileTreeRow) -> some View {
        Button {
            expand(path: row.node.path)
        } label: {
            Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -2)
        .onDrag { dragProvider(for: row.node) }
        .help(row.expanded ? "Collapse" : "Expand")
        .accessibilityLabel(row.expanded ? "Collapse \(row.node.name)" : "Expand \(row.node.name)")
    }

    private func searchResults(_ hits: [SearchHit]) -> some View {
        List(hits, selection: $selection) { hit in
            HStack(spacing: 6) {
                Image(systemName: hit.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(hit.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 16)
                    .accessibilityLabel(hit.isDirectory ? "Folder" : "File")
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
            // A hit drags out like a tree row, through the same gate, as
            // the node a restore of it would get (`node(for:)`): a hit
            // carries its kind in the open backup.
            .itemProvider { listDragProvider(for: node(for: hit)) }
            // The hit's byte-exact id, not its path: a path's `==` is
            // canonical equivalence, so two hits whose names differ only
            // in Unicode normalization would share one selection.
            .tag(hit.id)
        }
        .listStyle(.inset)
        .focusOnClick($listIsFocused)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let hit = hits.first(where: { $0.id == id }) {
                showVersionsItem(path: hit.path, isDirectory: hit.isDirectory)
            }
        }
    }

    /// Show Versions: the item through every backup of its history, on the
    /// Files tab of the page that holds it — its plan's, or its group's
    /// under Other backups — opening at this backup.
    @ViewBuilder
    private func showVersionsItem(path: String, isDirectory: Bool) -> some View {
        if let record {
            Button("Show Versions") {
                router.showVersions(
                    path: path,
                    isDirectory: isDirectory,
                    in: record,
                    repositoryID: repositoryID,
                    page: model.shelves(for: repositoryID).page(of: record, repositoryID: repositoryID)
                )
            }
        }
    }

    /// The pane's three ways out of a record, in one row: the primary
    /// Restore… for the selection, the whole backup on the left, and the
    /// drag named in between. The hint shows over a list whose rows drag
    /// — the tree, or a search's hits; while a search lists hits and other
    /// backups hold more, the middle says so and offers the way there —
    /// never both. The keep/replace decision lives in the destination sheet, not
    /// as a permanent caption under every browse.
    private func footer(record: Snapshot?) -> some View {
        HStack(spacing: 12) {
            // Titles stay whole; the note beside them is what gives way.
            Button("Restore Entire Backup…") { restoreWholeRecord() }
                .disabled(model.isRestoring || record == nil)
                .help("Restore everything in this backup — each folder is recreated under its full original path inside the folder you choose")
                .fixedSize()
            Spacer(minLength: 12)
            // An empty result says it in the empty state, button included.
            if let result = searchResult, !result.inThisBackup.isEmpty, let note = result.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(note)
                searchAllButton
                    .controlSize(.small)
                    .fixedSize()
            } else if dragListIsShowing {
                Text("Drag an item to Finder to restore it there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Restore…") { restoreSelection() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedNodes.isEmpty || model.isRestoring || record == nil)
                .help("Restore the selected items from this backup (Return)")
        }
        .padding(12)
    }

    /// The browser shows a list whose rows drag: the search's hits in this
    /// backup, or the tree — not a spinner, an error, an empty answer, a
    /// missing folder or an empty one standing in for them.
    private var dragListIsShowing: Bool {
        guard !isLoadingTree, loadError == nil else { return false }
        if let searchResult { return !searchResult.inThisBackup.isEmpty }
        return !folderMissing && !tree.rows.isEmpty
    }

    /// One title, help and guard wherever the pane offers it: Find Files
    /// needs restic, as the Repository menu's item does.
    private var searchAllButton: some View {
        Button("Search All Backups…") {
            onSearchAllBackups(repositoryID, searchText.trimmingCharacters(in: .whitespaces))
        }
        .disabled(!model.isResticAvailable)
        .help("Open Find Files with this search, across every backup in this repository")
    }

    // MARK: - Rows

    /// The nodes behind the current selection, in the list's order: tree
    /// rows while browsing, synthesized hits while searching. Only rows on
    /// screen count — a row whose folder is folded away is not restored
    /// unseen.
    private var selectedNodes: [SnapshotNode] {
        guard !selection.isEmpty else { return [] }
        if let hits = searchResult?.inThisBackup {
            return hits.filter { selection.contains($0.id) }.map(node(for:))
        }
        return tree.rows.filter { selection.contains($0.id) }.map(\.node)
    }

    /// A hit as the node its restore and its drag both get, made in one
    /// place so the two cannot disagree. Hits are already filtered to paths
    /// the selected backup contains and carry their kind, so the node goes
    /// straight to the restore, whose file and folder routes differ.
    private func node(for hit: SearchHit) -> SnapshotNode {
        let name = (hit.path as NSString).lastPathComponent
        return SnapshotNode(
            name: name.isEmpty ? hit.path : name,
            type: hit.isDirectory ? .dir : .file,
            path: hit.path
        )
    }

    /// The one selected node, when exactly one row is selected.
    private var selectedRow: SnapshotNode? {
        let nodes = selectedNodes
        return nodes.count == 1 ? nodes[0] : nil
    }

    /// The Change column: the word, in the text colour — restic's "+" and
    /// "M" leave VoiceOver nothing to read, and coloured caption text falls
    /// short of the contrast small text needs. The tooltip keeps what
    /// exactly changed.
    private func changeBadge(for path: String) -> some View {
        Group {
            if let change = changes[path] {
                Text(change.category.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .help(change.explanation)
                    .frame(width: 56, alignment: .leading)
            } else {
                Spacer().frame(width: 56)
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

    /// The list's drag asks on every mouse-down, not only when a drag
    /// begins, so a drag that can never land offers nothing rather than
    /// posting `dragRestoreProvider`'s "Cannot drag to restore" at each
    /// click — the pane already says why (record not found, or restic
    /// missing under its strip). The chevron's drag asks only when a drag
    /// starts, and keeps the banner.
    private func listDragProvider(for node: SnapshotNode) -> NSItemProvider? {
        guard model.repository(id: repositoryID) != nil, model.isResticAvailable else { return nil }
        return dragProvider(for: node)
    }

    /// → and ← first — the outline's own keys, which only a tree has — then
    /// the shared Finder grammar. `reveal` scrolls a row the keys selected
    /// into view.
    private func handleKeyPress(_ press: KeyPress, reveal: @escaping (String) -> Void) -> KeyPress.Result {
        // Plain arrows on a selected row only: a modified arrow keeps its
        // system meaning (Option-→ would expand every descendant — one
        // `restic ls` per folder), and with nothing selected the List moves
        // as it always does.
        let arrow: FileTree.HorizontalArrow? = switch press.key {
        case .leftArrow: .left
        case .rightArrow: .right
        default: nil
        }
        let isPlain = press.modifiers.isDisjoint(with: [.command, .option, .control, .shift])
        if let arrow, isPlain, selection.count > 1, searchResult == nil {
            // Finder's outline with several rows selected: → opens every
            // selected folder and ← closes every open one; the selection
            // stays where it is. Not over search results, whose paths can
            // name tree rows hidden behind them.
            for node in selectedNodes where node.isDirectory {
                switch tree.arrowStep(arrow, from: node.path) {
                case .expand(let path), .collapse(let path): expand(path: path)
                case .selectParent, .stay: break
                }
            }
            return .handled
        }
        if let arrow, isPlain, selection.count == 1, let selected = selection.first {
            switch tree.arrowStep(arrow, from: selected) {
            case .expand(let path), .collapse(let path):
                // The step already knows the direction; expand toggles.
                expand(path: path)
            case .selectParent(let path):
                // The list applies a selection set in code only to rows it
                // has realized, on or near the screen: selecting a parent
                // scrolled out of view straight away leaves the child
                // selected as well — two selected rows, and the next ↓ goes
                // on from the child. So the child comes into view and is
                // deselected in this turn, and the parent is selected and
                // scrolled to in the next.
                reveal(selected)
                selection = []
                Task {
                    selection = [path]
                    reveal(path)
                }
            case .stay:
                break
            }
            // Spent either way, as the native outline spends it.
            return .handled
        }
        // Return on a file, or on several rows, is the footer's Restore…:
        // left unhandled, the list hands Return to its double-click action
        // and the default button never sees it. The same gate as the
        // button.
        if press.key == .return, isPlain,
           selectedNodes.count > 1 || selectedRow.map({ !$0.isDirectory }) == true {
            guard !model.isRestoring, record != nil else { return .ignored }
            restoreSelection()
            return .handled
        }
        // The shared Finder grammar, with this pane's open action: a
        // directory's Return expands it in place rather than entering it —
        // the tree already holds every loaded row.
        return BrowserListGrammar.keyPress(
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
        selection = []
    }

    // MARK: - Loading

    /// The selected record changed: rebuild the tree, walk the preserved
    /// folder's spine back open, and load the change annotations. Search
    /// belongs to the record it was searched in — both the hits and the
    /// query go, so a record switch never shows another backup's search.
    private func loadLevel() async {
        searchResult = nil
        searchText = ""
        guard let record else {
            tree = FileTree(roots: [])
            comparison = nil
            return
        }
        // Show in Backups' focus folder, when the route asked for this
        // record: walked open by the same spine a record switch re-walks.
        // A path outside the record's roots is dropped, not walked.
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
                ?? .compared(
                    baseline: predecessor,
                    changeCount: marks.changes.count,
                    removed: ChangeComparison.removals(in: marks.changes)
                )
        } else {
            changes = [:]
            comparison = .firstBackup
        }

        // Re-open the folder the user was in. The first missing ancestor
        // stops the walk: a listing that answers without it is as much an
        // answer as a failed fetch, and the pane must say so rather than
        // show a shallower tree with breadcrumbs claiming the deeper path.
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
            selection = [focus]
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
        guard fetchTasks[needed] == nil else { return }
        // A focus change that keeps the row selected, as NSOutlineView's
        // does — not `navigate(to:)`, whose deselect would send the next ↓
        // back to the top of the list.
        currentPath = path
        fetchTasks[needed] = Task {
            defer { fetchTasks[needed] = nil }
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
                // back and say why, instead of an empty expansion. Close,
                // not toggle: a ← or chevron that closed it meanwhile stands.
                tree.collapse(path: path)
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

    /// Search runs against the index (instant) and lists the paths the
    /// selected record contains — the tree must stay honest about which
    /// backup it is showing — while counting the matches only other backups
    /// hold.
    private func searchChanged(_ newValue: String) {
        let query = newValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let record else {
            searchTask?.cancel()
            searchResult = nil
            // Clearing the search is a fresh look: a stale load error
            // replaces the whole browser, and must not read as still failing.
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
            // would be the one lie a search tool cannot tell. The membership
            // in the open backup comes from the same read, so it cannot fail
            // apart from the search.
            //
            // Completeness is asked before the search, not after: a backup
            // once read stays read, so an index complete before the query
            // has read the open backup the hits are split against. Until
            // then the open backup itself may be unread, and its own files
            // would look as if only other backups held them — FindFilesView
            // and the Files view ask the same.
            let indexIsComplete = await model.indexIsComplete(repositoryID: repositoryID)
            let found: SearchWithMembership
            do {
                // The hits, and which of them the open backup holds with
                // their kind there. Every hit is held by some backup — the
                // search returns no other path, in the same read — so the
                // rest are the matches elsewhere.
                found = try await model.searchIndexWithMembership(
                    pattern: query, inSnapshot: searchedRecordID, repositoryID: repositoryID
                )
            } catch {
                guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
                loadError = (error as? ResticError)?.errorDescription ?? error.localizedDescription
                return
            }
            guard !Task.isCancelled, loadedSnapshotID == searchedRecordID else { return }
            // The pane lists what the open backup holds; the rest is counted,
            // not dropped — it is where "Search All Backups…" leads.
            searchResult = RestorePaneSearch(
                hits: found.hits,
                inRecord: found.inSnapshot,
                limit: AppModel.indexSearchLimit,
                indexIsComplete: indexIsComplete
            )
            selection = []
            // The index answered: a load error from an earlier failed read
            // must not sit in front of these results or behind them.
            loadError = nil
        }
    }

    /// The picked rows through the shared factory
    /// (`RestoreDestinationRequest.picked`): the covering rule and the
    /// sheet's wording live there, one rule for this pane and the Files
    /// view's folder versions.
    private func restoreSelection() {
        guard let record else { return }
        destinationRequest = RestoreDestinationRequest.picked(
            selectedNodes,
            repositoryID: repositoryID,
            snapshotID: record.id,
            snapshotShortID: record.shortID,
            backupTime: record.time,
            model: model
        )
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
                label: model.recordLabel(of: record, repositoryID: repositoryID)
            ),
            backupTime: record.time,
            snapshotShortID: record.shortID
        ) { directories, overwrite in
            model.restoreWholeSnapshot(
                repositoryID: repositoryID,
                snapshotID: record.id,
                to: directories[0],
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
            label: model.recordLabel(of: record, repositoryID: repositoryID),
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
            .help(heading.detail)
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
            .help(heading.detail)
            // Its own tooltip: a `.help` on the stack would cover this
            // line's too.
            if let removed = heading.removed {
                Text(removed.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(removed.detail)
            }
        }
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
    let repositoryID: UUID

    /// Enough to answer the question for the usual one or two items without
    /// growing into a second scrolling list above the tree.
    private static let shownItems = 3

    /// The shown items the backup before this one holds, each with its kind
    /// there: those lines are routes to that good copy's versions. Empty
    /// until the index answers, and for items no earlier backup has.
    @State private var heldBefore: [PathKey: Bool] = [:]

    var body: some View {
        if let run = model.backupRun(forSnapshot: snapshotID), run.snapshotCompleteness == .incomplete {
            strip(run)
            Divider()
        }
    }

    private func strip(_ run: RunRecord) -> some View {
        let unreadable = run.itemErrorCount
        let lines = Array(run.unreadableItems.prefix(Self.shownItems))
        let baseline = SnapshotLineage.changeBaseline(for: snapshotID, in: model.snapshots(for: repositoryID))
        let paths = lines.compactMap { run.unreadableItemPaths?[$0] }
        return HStack(alignment: .top, spacing: 8) {
            // Beside words that say the same thing: decoration to VoiceOver.
            Image(systemName: RunRecord.Outcome.completedWithErrors.symbolName ?? "exclamationmark.triangle.fill")
                .foregroundStyle(StatusPalette.status(.completedWithErrors))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(unreadable > 0
                    ? "This backup is incomplete: restic could not read \(Format.plural(unreadable, "item")) when it was made."
                    : "This backup is incomplete: restic could not read some of the source data when it was made, and did not name it.")
                    .font(.callout.weight(.medium))
                    // Not height-pinned, for BannerView's reason: the pane
                    // does not scroll, and a pinned text answers the split
                    // view's zero-width sizing query a character per line.
                    // Only the pane's minimum width keeps this one safe.
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let baseline, let path = run.unreadableItemPaths?[line],
                       let isDirectory = heldBefore[PathKey(path)] {
                        // A row that goes somewhere: the item's versions,
                        // opening at the backup before, which has it.
                        Button {
                            router.showVersions(
                                path: path,
                                isDirectory: isDirectory,
                                in: baseline,
                                repositoryID: repositoryID,
                                page: model.shelves(for: repositoryID).page(of: baseline, repositoryID: repositoryID)
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Text(line)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(HoverableButtonStyle())
                        .help("Not in this backup — the backup of \(Format.timestamp(baseline.time)) has it. Show its versions.")
                    } else {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(line)
                            .textSelection(.enabled)
                    }
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
                router.focusRun(run.id)
            }
            .controlSize(.small)
            .help("Select the run that made this backup in Activity")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .task(id: [snapshotID, baseline?.id ?? ""] + paths) {
            heldBefore = [:]
            guard let baseline, !paths.isEmpty else { return }
            // A failed read leaves the lines plain text: the route is extra,
            // and nothing shown depends on it.
            let kinds = (try? await model.kinds(of: paths, inSnapshot: baseline.id, repositoryID: repositoryID)) ?? [:]
            guard !Task.isCancelled else { return }
            heldBefore = kinds
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

/// The tree rows' measured content width, written by the rows and read by
/// the column header alone.
@Observable
@MainActor
private final class RowContentWidth {
    var value: CGFloat?
}

/// A table header over the outline: the columns the rows below carry,
/// aligned to the same fixed gutters. Its own view, so the rows' width —
/// which moves with every resize step — re-renders the header, never the
/// tree.
private struct TreeColumnHeader: View {
    let rowContentWidth: RowContentWidth

    var body: some View {
        HStack(spacing: 6) {
            // The rows' depth indent: zero wide at the top level, but still
            // a slot the row's stack spaces.
            Spacer().frame(width: 0)
            Spacer().frame(width: 20)
            Spacer().frame(width: 16)
            Text("Item")
            Spacer(minLength: 12)
            Text("Change")
                .frame(width: 56, alignment: .leading)
            Text("Last Modified")
                .frame(width: 140, alignment: .trailing)
            Text("Size")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        // No wider than the rows' content: with a legacy scroller showing,
        // the rows narrow by its width and their trailing columns sit left
        // of these titles. A cap, not a width: a fixed width holds the
        // list open at its old size when the pane narrows, so the rows
        // never shrink to report the new one.
        .frame(maxWidth: rowContentWidth.value, alignment: .leading)
        // The inset list's row content starts and ends 16 pt inside the pane.
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
