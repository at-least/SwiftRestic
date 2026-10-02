import SwiftUI

/// The restore pane: one backup record's file tree, browsed straight from
/// the sidebar, where a plan's backups fold open beneath it — Arq's
/// arrangement, where picking a dated record in the source list shows its
/// files in the main pane.
///
/// The app's one snapshot-first browser: the run drawer's Browse, both
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
    /// "Search All Backups…": the host opens Find Files on this repository
    /// with the query filled in.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

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
    /// The tree rows' content width, measured on the rows: a legacy
    /// scroller takes its width out of the rows but not out of the column
    /// header above the list, which has no other way to know it is there.
    /// A box only the header reads, not a width of the pane's own: the
    /// width changes on every step of a window resize, and as pane state
    /// each step re-rendered the whole tree (a replica with 20,000 rows:
    /// 59 pane re-renders and 190 ms per step, against none and 6 ms).
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
                    Text("This backup is no longer in the repository. Pick another one in the sidebar.")
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
            // Filling, whatever stands in for the tree: an empty search
            // result's ContentUnavailableView answered its own height, and
            // the whole pane floated mid-window with bands above and below.
            browser
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            Divider()
            footer(record: record)
        }
        // Fits the narrowest detail column the window allows: its 940-pt
        // minimum less the sidebar at its 340-pt maximum and the split's
        // 8 pt (SwiftResticApp.swift, SidebarView.swift). The sheet this
        // pane grew out of asked for 640, which pushed the split view 48 pt
        // wider than the window — measured 988 in 940, clipping Restore…
        // and the search field. Still a minimum: it also bounds the split
        // view's zero-width sizing query (a7a4609).
        .frame(minWidth: 592)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar (top)

    /// The open backup's name and what its Change column is compared with,
    /// then the search field, which searches the open backup — Repository ▸
    /// Find Files in Snapshots… (⇧⌘F) searches every backup. fd691ee
    /// dropped this header on the grounds that the sidebar's selection
    /// names the record and the column speaks for itself; neither holds.
    /// With the sidebar hidden nothing else names the open backup — the
    /// window title is always "Restore" — and a blank Change column can mean
    /// a first backup, no changes, a comparison still running, or a failed
    /// one. Only this line tells them apart.
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
                    // folder.fill, "Document" for doc); the kind is what the
                    // row means.
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
                // The column header copies this width (a geometry read, not a
                // gesture: the row stays free of them, see below).
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if rowContentWidth.value != width { rowContentWidth.value = width }
                }
                // Arq's signature restore gesture: drag straight out of the tree
                // into Finder. Tree rows only: the search list's rows offer
                // Restore… but no drag. Not for safety any more — a hit now
                // carries its kind in the open backup, read from that backup,
                // so it would not dump a folder as a file — only unwired.
                //
                // The list's own drag, not `.onDrag`, and no gesture on the
                // row at all: a SwiftUI gesture claims every click inside
                // what it covers, so a click on a row's name or icon never
                // selected it (`.onDrag` alone did that, and so did the old
                // double-click `.onTapGesture`; the old contentShape spread
                // it over the whole row). Measured with HID-level clicks on
                // macOS 26, where rows shaped like these selected on their
                // name, icon and blank space and dragged from all three.
                .itemProvider { listDragProvider(for: row.node) }
                .tag(row.id)
            }
            .listStyle(.inset)
            .focusOnClick($listIsFocused)
            // Double-click, the list's way: it expands a folder, as the
            // chevron does, and leaves a file alone. The list also sends
            // Return here — Return is spent in `handleKeyPress` first.
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
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
    /// 20×20, hanging 2 pt past its 16-pt layout box above and below so the
    /// row stays 24 pt like a file row. Measured with HID-level clicks and
    /// drags on a probe of this row (macOS 26): the padding sits outside the
    /// Button, because inside the label the Button hit-tests only its 20×16
    /// box; and the Button carries the row's drag itself, because the list's
    /// drag never starts on the Button — without it the square was the one
    /// part of the row a drag to Finder could not start from. Labelled for
    /// its folder: the symbol's own labels are "Forward" and "Go Down".
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
            // The hit's byte-exact id, not its path: a path's `==` is
            // canonical equivalence, so two hits whose names differ only
            // in Unicode normalization would share one selection.
            .tag(hit.id)
        }
        .listStyle(.inset)
        .focusOnClick($listIsFocused)
    }

    /// Arq's three ways out of a record, in one row: the primary Restore…
    /// for the selection on the right, the whole backup as the secondary
    /// action on the left, and the drag named in between — Arq's "Drag and
    /// drop to the desktop or a Finder window or click Restore:". The hint
    /// shows only over the tree, the one list whose rows drag. While a
    /// search lists hits and other backups hold more, the middle says so
    /// instead and offers the way there — never both. The keep/replace
    /// decision happens in the destination sheet, not as a permanent caption
    /// under every browse.
    private func footer(record: Snapshot?) -> some View {
        HStack(spacing: 12) {
            // Titles stay whole; the note beside them is what gives way. At
            // the pane's 592-pt minimum the search note squeezed this title
            // to "Restore Entire Backu…".
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
            } else if treeIsShowing {
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

    /// The browser's final branch — the tree list, and nothing standing in
    /// for it (spinner, error, search results, missing folder, empty folder).
    private var treeIsShowing: Bool {
        !isLoadingTree && loadError == nil && searchResult == nil && !folderMissing && !tree.rows.isEmpty
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
    /// screen count — a row its folder folded away is not restored unseen.
    /// Search hits were already filtered to paths the selected backup
    /// contains, and each carries its kind in that backup — which is what
    /// lets the synthesized node go straight to the restore, whose file and
    /// folder routes differ.
    private var selectedNodes: [SnapshotNode] {
        guard !selection.isEmpty else { return [] }
        if let hits = searchResult?.inThisBackup {
            return hits.filter { selection.contains($0.id) }.map { hit in
                let name = (hit.path as NSString).lastPathComponent
                return SnapshotNode(
                    name: name.isEmpty ? hit.path : name,
                    type: hit.isDirectory ? .dir : .file,
                    path: hit.path
                )
            }
        }
        return tree.rows.filter { selection.contains($0.id) }.map(\.node)
    }

    /// The one selected node, when exactly one row is selected.
    private var selectedRow: SnapshotNode? {
        let nodes = selectedNodes
        return nodes.count == 1 ? nodes[0] : nil
    }

    /// Arq's Change column: the word, in the text colour. restic's "+" and
    /// "M" were all VoiceOver had to read, and green or orange caption text
    /// measured 2.2–2.3:1 on the light list background, under the 4.5:1
    /// small text needs. The tooltip keeps what exactly changed ("content
    /// changed", "type changed", "bitrot detected").
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

    /// The list's drag asks on every mouse-down on a row, not only when a
    /// drag begins (a probe's provider counted one call per plain click), so
    /// a drag that can never land offers nothing here rather than posting
    /// `dragRestoreProvider`'s "Cannot drag to restore" at each click. The
    /// pane already says why: a record whose repository is gone is not
    /// found, and a missing restic has its strip over every pane. The
    /// chevron's own drag asks only when a drag starts, and keeps the
    /// banner.
    private func listDragProvider(for node: SnapshotNode) -> NSItemProvider? {
        guard model.repository(id: repositoryID) != nil, model.isResticAvailable else { return nil }
        return dragProvider(for: node)
    }

    /// → and ← first — the outline's own keys, which only a tree has — then
    /// the shared Finder grammar. `reveal` scrolls a row the keys selected
    /// into view.
    private func handleKeyPress(_ press: KeyPress, reveal: @escaping (String) -> Void) -> KeyPress.Result {
        // Plain arrows on a selected row only: a modified arrow keeps its
        // system meaning (Option-→ would expand every descendant in a native
        // outline — here, one `restic ls` per folder), and with nothing
        // selected the List moves as it always does.
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
                // scrolled out of view straight away left the child selected
                // as well — two selected rows, and the next ↓ went on from
                // the child. So the child comes into view and is deselected
                // in this turn, and the parent is selected and scrolled to
                // in the next (probed on macOS 26 with this list's shape:
                // one selected row whether the parent was on screen or not,
                // and with the child scrolled away before the key).
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
        // Return on a file, or on several rows, is the footer's Restore…, as
        // before the list had a primary action: left unhandled, the list now
        // hands Return to its double-click action and the default button
        // never sees it (measured on a probe). The same gate as the button.
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
        guard !inFlightFetches.contains(needed) else { return }
        inFlightFetches.insert(needed)
        // A focus change that keeps the row selected, as NSOutlineView's
        // does — not `navigate(to:)`, whose deselect would send the next ↓
        // back to the top of the list.
        currentPath = path
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
            // would be the one lie a search tool cannot tell. The membership
            // in the open backup comes from the same read of the index, so it
            // cannot fail apart from the search.
            //
            // Whether the index has read every backup is asked before the
            // search, not after: a backup once read stays read, so an index
            // complete before the query has read the open backup the hits
            // are split against. Until then the open backup itself may be
            // unread, and its own files would look as if only other backups
            // held them — FindFilesView and FolderBrowserView ask the same.
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

    /// One item goes the way a single item always has; several go together,
    /// less any inside another selected folder, which brings them anyway —
    /// and the sheet says so, or three selected rows would read as two.
    private func restoreSelection() {
        let selected = selectedNodes
        let nodes = RestoreBatch.covering(selected)
        let note = RestoreBatch.coveredNote(RestoreBatch.covered(selected))
        guard let record, let first = nodes.first else { return }
        let repositoryID = repositoryID
        guard nodes.count > 1 else {
            destinationRequest = RestoreDestinationRequest(
                subject: .item(name: first.name, path: first.path, isDirectory: first.isDirectory),
                selectionNote: note,
                backupTime: record.time,
                snapshotShortID: record.shortID
            ) { directories, overwrite in
                model.restore(
                    repositoryID: repositoryID,
                    snapshotID: record.id,
                    node: first,
                    to: directories[0],
                    overwrite: overwrite
                )
            }
            return
        }
        destinationRequest = RestoreDestinationRequest(
            subject: .items(nodes.map { RestoreItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }),
            selectionNote: note,
            backupTime: record.time,
            snapshotShortID: record.shortID
        ) { directories, overwrite in
            model.restore(
                repositoryID: repositoryID,
                snapshotID: record.id,
                items: zip(nodes, directories).map { (node: $0, directory: $1) },
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
                    // Only the pane's minimum width kept this one safe.
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

/// The tree rows' measured content width, written by the rows and read by
/// the column header alone.
@Observable
@MainActor
private final class RowContentWidth {
    var value: CGFloat?
}

/// Arq's table header over the outline: the columns the rows below carry,
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
        // the rows narrow by its width and their trailing columns stood
        // 17 pt left of these titles (measured on macOS 26). A cap, not a
        // width: a fixed width held the list open at its old size when the
        // pane narrowed, so the rows never shrank to report the new one.
        .frame(maxWidth: rowContentWidth.value, alignment: .leading)
        // The inset list's row content starts and ends 16 pt inside the
        // pane (measured on macOS 26); at 10 the header stood 12 pt left of
        // the names and 6 pt right of the Change words.
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
