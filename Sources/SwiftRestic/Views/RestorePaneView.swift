import SwiftUI
import UniformTypeIdentifiers

/// One backup record's file tree, beside a page's Backups tab's list. The
/// app's one browser of what the backups hold: every route lands here
/// (`AppRouter.showBackup`), so the Change column and drag-to-Finder never
/// depend on the route. A file picked in it is handed to `onPick`, whose
/// versions (`versionsPane`) the tab shows under the tree, above the tab's
/// one bottom bar.
///
/// The list beside it chooses the record. Switching records keeps the
/// folder open. The window's title is the page's, its subtitle the open
/// backup's moment: the pane sets neither.
struct RestorePaneView<VersionsPane: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(DiskWatch.self) private var diskWatch

    let repositoryID: UUID
    let snapshotID: String
    /// The one file selected, or nil; told once the tree is read.
    let onPick: (RestorePanePick?) -> Void
    /// What the versions pane under the tree restores for the file
    /// selected: Restore and Return run it in place of the tree's own.
    let chosenVersion: ChosenVersionRestore
    let versionsPane: VersionsPane

    @State private var tree = FileTree(roots: [])
    /// The folder the tree is focused on — kept across record switches.
    @State private var currentPath: String?
    @State private var changes: [PathKey: ResticDiffChange] = [:]
    @State private var changesInside: [PathKey: ChangesInside] = [:]
    /// What `changes` was computed against, for the header: written beside
    /// the map in `loadLevel`, never re-derived — the header must name the
    /// comparison whose marks are on screen.
    @State private var comparison: ChangeComparison?
    /// The tree's rows this Mac no longer holds, for a backup made on this
    /// Mac (`DiskFile.localPath`): dimmed, as a search's deleted hits are.
    @State private var notOnThisMac: Set<PathKey> = []
    /// The selected rows' ids. Several at once, as in Finder (⌘- or
    /// ⇧-click): Restore restores them together.
    @State private var selection: Set<String> = []
    @FocusState private var listIsFocused: Bool
    @State private var isLoadingTree = false
    @State private var loadError: String?
    @State private var folderMissing = false
    /// The record the tree on screen was built for. A folder listing that
    /// lands after a record switch must not install itself into the new
    /// record's tree.
    @State private var loadedSnapshotID: String?
    /// The fetch tasks, so the pane's departure can stop them: an expand
    /// that outlives the pane keeps a restic listing running and writes
    /// into state nobody reads. A key present is a fetch already running.
    /// Keyed by backup too: a slow listing of one backup's folder must not
    /// hold back the same folder's listing in the backup switched to.
    @State private var fetchTasks: [FetchKey: Task<Void, Never>] = [:]

    private struct FetchKey: Hashable {
        let snapshotID: String
        let path: String
    }
    /// A routed focus folder the tree should scroll to once it is on screen —
    /// set by `loadLevel`, spent by the list. Plain record switches keep
    /// their folder open but never scroll.
    @State private var revealPath: String?
    @State private var previewer = PreviewSession()
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
        // One read per render: each read of `record` scans the repository's
        // whole snapshot list.
        let currentRecord = record
        return Group {
            if currentRecord != nil {
                browserPane(record: currentRecord)
            } else {
                ContentUnavailableView {
                    Label("Backup not found", systemImage: "questionmark.folder")
                } description: {
                    Text("This backup no longer exists. Select another one in the list.")
                }
            }
        }
        // The heavy reload — diff, tree rebuild, folder re-walk — belongs to
        // record switches only: folder moves and Finder drops change
        // `currentPath` alone, the tree already holds their rows, and
        // re-running the diff on every chevron click would make a large
        // repository feel broken.
        .task(id: snapshotID) { await loadLevel() }
        .onChange(of: pickReport) { _, report in
            guard !report.isLoading else { return }
            onPick(report.pick)
        }
        // Again as rows open and as the disk may have changed.
        .task(id: presenceKey) { await readPresence() }
        .previewSession(previewer)
        // The copy belongs to the backup on screen.
        .onChange(of: snapshotID) { previewer.end() }
        .onChange(of: previewer.failure) { _, failure in
            if let failure { model.post(Banner(title: failure.title, message: failure.message, level: .error)) }
        }
        .restoreFlow($destinationRequest)
        .onDisappear {
            for (_, task) in fetchTasks { task.cancel() }
        }
    }

    private func browserPane(record: Snapshot?) -> some View {
        // One comparison read per render, for every header below.
        let shown = shownComparison(for: record)
        return VStack(spacing: 0) {
            // Only a failed comparison takes a line: a blank Change column
            // then means "not known", not "unchanged". What the column
            // compares with otherwise is its title's tooltip.
            if case .failed = shown {
                toolbar(record: record, comparison: shown)
                Divider()
            }
            // Its own view, reading the run history itself: a new run
            // record re-renders the strip, never the tree below it.
            IncompleteSnapshotStrip(snapshotID: snapshotID, repositoryID: repositoryID)
            // Filling, whatever stands in for the tree: a
            // ContentUnavailableView answers its own height, and without
            // this the pane floats mid-window.
            browser(shown: shown)
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            versionsPane
            Divider()
            footer(record: record)
        }
        .restoreCommand(restore(record: record))
        // At most the narrowest detail column the window allows beside the
        // Backups tab's list. Still a minimum: it also bounds the split
        // view's zero-width sizing query.
        .frame(minWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `comparison`, when it is the open record's: between a record switch
    /// and loadLevel's first line it still belongs to the previous record.
    private func shownComparison(for record: Snapshot?) -> ChangeComparison? {
        guard let record, loadedSnapshotID == record.id else { return nil }
        return comparison
    }

    private static func isComparing(_ comparison: ChangeComparison?) -> Bool {
        if case .comparing = comparison { true } else { false }
    }

    private func toolbar(record: Snapshot?, comparison: ChangeComparison?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let record {
                RestoreRecordHeader(
                    repositoryID: repositoryID,
                    record: record,
                    comparison: comparison
                )
                .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func browser(shown: ChangeComparison?) -> some View {
        if isLoadingTree {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            FailureUnavailableView(title: "Couldn’t read this folder", message: loadError)
        } else if folderMissing {
            ContentUnavailableView {
                Label("Not in this backup", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Select another backup in the list.")
            }
        } else if tree.rows.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            VStack(spacing: 0) {
                TreeColumnHeader(
                    rowContentWidth: rowContentWidth,
                    hasChangeColumn: Self.hasChangeColumn(shown),
                    changeHelp: RestoreRecordHeading.columnHelp(for: shown),
                    isComparing: Self.isComparing(shown)
                )
                Divider()
                treeList(hasChangeColumn: Self.hasChangeColumn(shown))
            }
        }
    }

    /// No Change column for a first backup: nothing to compare with, and an
    /// empty column would read as "unchanged".
    private static func hasChangeColumn(_ comparison: ChangeComparison?) -> Bool {
        comparison != .firstBackup
    }

    private func treeList(hasChangeColumn: Bool) -> some View {
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
                    let isGone = notOnThisMac.contains(PathKey(row.node.path))
                    FileKindIcon(type: row.node.iconType)
                        .opacity(isGone ? 0.5 : 1)
                        .accessibilityLabel(row.node.kindName)
                    Text(row.node.name)
                        .lineLimit(1)
                        .foregroundStyle(isGone ? .secondary : .primary)
                        .help(isGone ? "Not on this Mac" : "")
                        .accessibilityValue(isGone ? "not on this Mac" : "")
                    Spacer()
                    if hasChangeColumn {
                        changeBadge(for: row.node.path)
                    }
                    // A synthesized top folder has no mtime: blank, not
                    // "—" — not applicable, where a file's unknown mtime
                    // keeps the dash, the app's unknown mark.
                    Group {
                        if row.node.isDirectory && row.node.mtime == nil {
                            Text(verbatim: "")
                        } else {
                            Text(Format.timestamp(row.node.mtime))
                        }
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                // The list's own drag, not `.onDrag`, and no gesture on the
                // row: a SwiftUI gesture claims every click inside what it
                // covers, so a click on a row's name or icon would never
                // select it.
                .itemProvider { listDragProvider(for: row.node) }
                .tag(row.id)
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
            .help("Drag an item to Finder to restore it there")
            .accessibilityIdentifier(AccessibilityID.RestorePane.tree)
            .dropDestination(for: URL.self) { urls, _ in
                showDropped(urls)
            }
            .focusOnClick($listIsFocused)
            // Double-click, the list's way: it expands a folder, as the
            // chevron does, and leaves a file alone. The list also sends
            // Return here — Return is spent in `handleKeyPress` first.
            .contextMenu(forSelectionType: String.self) { ids in
                restoreContextItem(ids) { ids.compactMap { tree.row(id: $0)?.node } }
                if ids.count == 1, let id = ids.first, let node = tree.row(id: id)?.node, !node.isDirectory {
                    // The tree's node is restic's own, size included.
                    previewItem { node }
                }
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first,
                      let node = tree.row(id: id)?.node, node.isDirectory
                else { return }
                expand(path: node.path)
            }
            .onKeyPress(.space, phases: .down) { press in
                previewer.space(press, start: previewable.map { node in { startPreview { node } } })
            }
            .onKeyPress(phases: .down) { press in
                // Left's parent may sit above the visible rows; the list
                // does not follow a selection it did not make itself.
                handleKeyPress(press) { proxy.scrollTo(FileTree.id(of: $0)) }
            }
            // Initial as well: the routed focus is set while the spinner stands
            // in for this list, so the list meets it on its first appearance.
            .onChange(of: revealPath, initial: true) { _, target in
                guard let target else { return }
                proxy.scrollTo(FileTree.id(of: target), anchor: .center)
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
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -2)
        .onDrag { dragProvider(for: row.node) }
        .accessibilityLabel(row.expanded ? "Collapse \(row.node.name)" : "Expand \(row.node.name)")
    }

    /// Back where they were or, choosing, through the destination sheet
    /// (`RestoreDestinationRequest.picked`).
    private func restore(_ picked: [RestoreSource], choosingDestination: Bool) {
        destinationRequest = RestoreDestinationRequest.picked(
            picked, repositoryID: repositoryID, model: model, choosingDestination: choosingDestination
        )
    }

    @ViewBuilder
    private func previewItem(_ node: @escaping @MainActor () async throws -> SnapshotNode) -> some View {
        if record != nil {
            Button("Preview") { startPreview(node) }
                .disabled(!model.isResticAvailable || previewer.isCopying)
        }
    }

    private func startPreview(_ node: @escaping @MainActor () async throws -> SnapshotNode) {
        guard let record else { return }
        previewer.start(model, repositoryID: repositoryID, snapshotID: record.id, node: node)
    }

    /// The one file selected in the tree, which Space looks at.
    private var previewable: SnapshotNode? {
        guard model.isResticAvailable, let node = selectedRow, !node.isDirectory else { return nil }
        return node
    }

    private var pickReport: PickReport {
        PickReport(isLoading: isLoadingTree, pick: pick)
    }

    private var presenceKey: PresenceKey {
        PresenceKey(rows: tree.rows.map(\.id), loaded: loadedSnapshotID, diskGeneration: diskWatch.diskGeneration)
    }

    /// Which of the tree's rows this Mac no longer holds, for a backup made
    /// here: off the main actor, one listing per folder (`DiskFolder.present`).
    private func readPresence() async {
        guard let record, loadedSnapshotID == record.id else { return }
        let local: [String] = tree.rows.compactMap { row in
            DiskFile.localPath(of: row.node.path, newestBackup: record, localHostname: model.localHostname)
        }
        let present = await Task.detached(priority: .userInitiated) { DiskFolder.present(local) }.value
        guard !Task.isCancelled else { return }
        notOnThisMac = Set(local.map { PathKey($0) }).subtracting(present)
    }

    /// What `onPick` is told: the one file selected, by the backup on
    /// screen.
    private var pick: RestorePanePick? {
        guard let node = selectedRow, !node.isDirectory, let loadedSnapshotID else { return nil }
        return RestorePanePick(path: node.path, backupID: loadedSnapshotID)
    }

    /// Right-click Restore and Restore To… on the clicked rows: the menu's
    /// own ids, not the ambient selection.
    @ViewBuilder
    private func restoreContextItem(_ ids: Set<String>, nodes: () -> [SnapshotNode]) -> some View {
        if let record, !ids.isEmpty {
            let clicked = nodes()
            if !clicked.isEmpty {
                let picked = clicked.map { RestoreSource($0, snapshotID: record.id, backupTime: record.time) }
                Button("Restore") { restore(picked, choosingDestination: false) }
                    .disabled(model.isRestoring)
                Button("Restore To…") { restore(picked, choosingDestination: true) }
                    .disabled(model.isRestoring)
            }
        }
    }

    /// What the pane restores, for File ▸ Restore and Restore To…: the
    /// selected items (`restoreSelection`). No
    /// whole-backup restore (the user's call: it rebuilt the full original
    /// paths under the landing and could not go back to the original
    /// location): selecting the tree's top rows, the backed-up folders,
    /// restores everything, Original location included.
    private func restore(record: Snapshot?) -> RestoreCommand {
        RestoreCommand(
            isEnabled: hasSelection && !model.isRestoring && record != nil,
            run: { restoreSelection(choosingDestination: $0) }
        )
    }

    /// The Backups tab's one bottom bar: the selection's Restore. Restore
    /// To… is the rows' menu, File ▸ Restore To… and the drag out to Finder,
    /// which is the tree's tooltip; the keep/replace decision is asked when
    /// something is in the way, not a permanent caption under every browse.
    private func footer(record: Snapshot?) -> some View {
        HStack(spacing: 12) {
            Spacer(minLength: 12)
            Button("Restore") { restoreSelection() }
                .accessibilityIdentifier(AccessibilityID.RestorePane.restore)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasSelection || model.isRestoring || record == nil)
                .help(selectedRow.map { !$0.isDirectory } == true
                    ? "Put the version selected below back where the file was (Return)"
                    : "Put the selected items back where they were, from this backup (Return)")
        }
        .padding(12)
    }

    private var hasSelection: Bool {
        !selectedNodes.isEmpty
    }

    /// The tree rows behind the current selection, in the list's order. Only
    /// rows on screen count — a row whose folder is folded away is not
    /// restored unseen.
    private var selectedNodes: [SnapshotNode] {
        guard !selection.isEmpty else { return [] }
        return tree.rows.filter { selection.contains($0.id) }.map(\.node)
    }

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
            if let change = changes[PathKey(path)] {
                Text(change.category.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .help(change.explanation)
                    .frame(width: 56, alignment: .leading)
            } else if let inside = changesInside[PathKey(path)], inside.total > 0 {
                // A folder the diff never names, whose subtree it does: the
                // count leads the expansion toward the leaves, so a
                // collapsed root does not read as unchanged.
                Text("\(Format.count(inside.total)) changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(insideHelp(inside))
                    .frame(width: 56, alignment: .leading)
            } else {
                Spacer().frame(width: 56)
            }
        }
    }

    private func insideHelp(_ inside: ChangesInside) -> String {
        "\(Format.plural(inside.total, "change")) inside this folder\(sinceBaseline): \(inside.summary)"
    }

    /// " since Oct 7, 2026 at 11:00 PM" — the same for every row, so it is
    /// formatted once per render, not once per folder with changes.
    private var sinceBaseline: String {
        comparison?.baseline.map { " since \(Format.timestamp($0.time))" } ?? ""
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
    /// posting `dragRestoreProvider`'s failure banner at each
    /// click — the pane already says why (record not found, or restic
    /// missing under its strip). The chevron's drag asks only when a drag
    /// starts, and keeps the banner.
    private func listDragProvider(for node: SnapshotNode) -> NSItemProvider? {
        guard model.canDragRestore(repositoryID: repositoryID) else { return nil }
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
        if let arrow, isPlain, selection.count > 1 {
            // Finder's outline with several rows selected: → opens every
            // selected folder and ← closes every open one; the selection
            // stays where it is.
            for node in selectedNodes where node.isDirectory {
                switch tree.arrowStep(arrow, from: node.path) {
                case .expand(let path), .collapse(let path): expand(path: path)
                case .selectParent, .stay: break
                }
            }
            return .handled
        }
        if let arrow, isPlain, selection.count == 1 {
            guard let selected = selection.first.flatMap({ tree.row(id: $0)?.node.path }) else { return .handled }
            switch tree.arrowStep(arrow, from: selected) {
            case .expand(let path), .collapse(let path):
                // The step already knows the direction; expand toggles.
                expand(path: path)
            case .selectParent(let path):
                selectParent(path, of: selected, reveal: reveal)
            case .stay:
                break
            }
            // Spent either way, as the native outline spends it.
            return .handled
        }
        // Return on a file, or on several rows, is the footer's Restore:
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
        let up = upStep
        return BrowserListGrammar.keyPress(
            press,
            selected: selectedRow,
            hasParent: up != nil,
            open: { expand(path: $0.path) },
            goUp: {
                guard let up else { return }
                currentPath = up.parent
                selectParent(up.parent, of: up.from, reveal: reveal)
            }
        )
    }

    /// Where ⌫ and ⌘↑ go: from the selected row — or, with none, the folder
    /// in focus — to the folder holding it, when that folder is a row of the
    /// tree. Going up selects that row, a step the eye can follow; a focus
    /// change alone shows nothing but a cleared selection.
    private var upStep: (from: String, parent: String)? {
        let selected = selection.first.flatMap { tree.row(id: $0)?.node.path }
        guard let from = selection.count == 1 ? selected : currentPath,
              let parent = BrowserListGrammar.parent(of: from),
              tree.node(at: parent) != nil
        else { return nil }
        return (from, parent)
    }

    /// The list applies a selection set in code only to rows it has
    /// realized, on or near the screen: selecting a parent scrolled out of
    /// view straight away leaves the child selected as well — two selected
    /// rows, and the next ↓ goes on from the child. So the child comes into
    /// view and is deselected in this turn, and the parent is selected and
    /// scrolled to in the next.
    private func selectParent(_ parent: String, of child: String, reveal: @escaping (String) -> Void) {
        reveal(child)
        selection = []
        Task {
            selection = [FileTree.id(of: parent)]
            reveal(parent)
        }
    }

    /// The selected record changed or the pane was just shown: rebuild the
    /// tree, walk the preserved folder's spine back open, then open the
    /// other roots, and load the change annotations.
    private func loadLevel() async {
        guard let record else {
            tree = FileTree(roots: [])
            comparison = nil
            return
        }
        // Show in Backups' focus folder when the route asked for this
        // record: walked open by the same spine a record switch re-walks. A
        // path outside the record's roots is dropped, not walked.
        let focus = router.takeRestoreFocus(repositoryID: repositoryID, snapshotID: record.id)
        if let focus, !Format.pathChain(of: focus, roots: record.paths).isEmpty {
            currentPath = focus
        }
        loadedSnapshotID = record.id
        let spine = currentPath.map { Format.pathChain(of: $0, roots: record.paths) } ?? []
        tree = FileTree(roots: record.paths.map(SnapshotNode.directory))

        isLoadingTree = true
        loadError = nil
        folderMissing = false

        // Changes against the previous backup — one restic diff, streamed.
        // A record switch during the diff must not install the old record's
        // change map into the new one's rows, nor its baseline into the new
        // one's header: `run` drops the marks of a cancelled load.
        await RestorePaneLoad.run(
            baseline: predecessor,
            compare: { baseline in
                await model.snapshotChanges(repositoryID: repositoryID, olderID: baseline.id, newerID: record.id)
            },
            listTree: { await openSpine(spine, focus: focus, record: record) },
            show: { marks in
                changes = marks.changes
                changesInside = marks.changesInside
                comparison = marks.comparison
            }
        )
    }

    private func openSpine(_ spine: [String], focus: String?, record: Snapshot) async {
        guard await walkOpen(spine, focus: focus, record: record) else { return }
        isLoadingTree = false
        // Not part of the walk: a root the user is not in must not become
        // the folder they were in, stop the walk with its failure, or hold
        // the walk's folder back behind its listing.
        for root in RestorePaneLoad.rootsBesideWalk(roots: record.paths, walk: spine) {
            guard let needed = tree.toggleExpanded(path: root) else { continue }
            fetchChildren(of: root, needed: needed, record: record)
        }
    }

    /// Re-opens the folder the user was in, or opens the tree to a dropped
    /// item, and selects and scrolls to `focus` when the walk reaches it.
    /// The first missing ancestor stops the walk: a listing that answers
    /// without it is as much an answer as a failed fetch, and the pane must
    /// say so rather than show a shallower tree with breadcrumbs claiming
    /// the deeper path. False when the walk stopped or was overtaken.
    private func walkOpen(_ spine: [String], focus: String?, record: Snapshot) async -> Bool {
        var deepest: String?
        for step in spine {
            guard tree.node(at: step) != nil else {
                guard !Task.isCancelled, loadedSnapshotID == record.id else { return false }
                folderMissing = true
                isLoadingTree = false
                return false
            }
            if let needed = tree.expand(path: step) {
                do {
                    let nodes = try await model.children(
                        repositoryID: repositoryID,
                        snapshotID: record.id,
                        path: needed
                    )
                    guard !Task.isCancelled, loadedSnapshotID == record.id else { return false }
                    tree.replaceChildren(of: needed, nodes: nodes)
                    readAhead(nodes, record: record)
                } catch {
                    // The folder is in the tree, so its listing failed:
                    // say why, not that the folder is missing.
                    guard !Task.isCancelled, loadedSnapshotID == record.id else { return false }
                    loadError = error.localizedDescription
                    isLoadingTree = false
                    return false
                }
            }
            deepest = step
        }
        if let deepest { currentPath = deepest }
        guard !Task.isCancelled, loadedSnapshotID == record.id else { return false }
        if let focus, deepest == focus {
            selection = [FileTree.id(of: focus)]
            revealPath = focus
        }
        return true
    }

    private func expand(path: String) {
        guard let needed = tree.toggleExpanded(path: path) else { return }
        guard let record else { return }
        // A focus change that keeps the row selected, as NSOutlineView's
        // does — not a deselect, which would send the next ↓
        // back to the top of the list.
        currentPath = path
        fetchChildren(of: path, needed: needed, record: record)
    }

    /// An opened folder's files, as many as one folder's worth of rows,
    /// read ahead (`AppModel.warmFileHistory`), so a click on one finds its
    /// versions' sizes and dates read. Only once the index has read every
    /// backup: until then the versions, and the backups they name, still
    /// move. The read-ahead is extra: when the index can't say, a click
    /// asks for its own file.
    private func readAhead(_ nodes: [SnapshotNode], record: Snapshot) {
        let chain = SnapshotIndex.chainKey(for: record)
        let files = nodes.lazy.filter { !$0.isDirectory }.prefix(Self.readAheadLimit).map {
            FileNode(repositoryID: repositoryID, chainKey: chain, path: $0.path, isDirectory: false)
        }
        guard !files.isEmpty else { return }
        Task {
            guard (try? await model.indexIsComplete(repositoryID: repositoryID)) == true else { return }
            model.warmFileHistory(Array(files))
        }
    }

    private static var readAheadLimit: Int { 200 }

    /// Lists `needed`, the folder `path`'s opening asked for, into the tree.
    private func fetchChildren(of path: String, needed: String, record: Snapshot) {
        // One fetch per directory at a time: a double-click racing itself
        // must not land two listings (the tree is replace-idempotent, but
        // skipping the duplicate spares a restic round trip).
        let fetchKey = FetchKey(snapshotID: record.id, path: needed)
        guard fetchTasks[fetchKey] == nil else { return }
        fetchTasks[fetchKey] = Task {
            defer { fetchTasks[fetchKey] = nil }
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
                readAhead(nodes, record: record)
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

    /// A single file: the version chosen in the versions pane under the
    /// tree, which opens on this backup's — this backup's file until the
    /// pane has read its versions. Otherwise the selected items, from this
    /// backup.
    private func restoreSelection(choosingDestination: Bool = false) {
        guard let record else { return }
        if let file = selectedRow, !file.isDirectory,
           let offer = chosenVersion.offer, PathKey(offer.path) == PathKey(file.path) {
            offer.run(choosingDestination)
            return
        }
        restore(
            selectedNodes.map { RestoreSource($0, snapshotID: record.id, backupTime: record.time) },
            choosingDestination: choosingDestination
        )
    }

    /// A Finder item dropped on the tree: the tree opens to it in this
    /// backup when it is inside the backed-up folders, keeping what is
    /// already open; anything else is refused.
    private func showDropped(_ urls: [URL]) -> Bool {
        guard let record, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
        let path = ResticPath.normalized(url.path)
        let spine = Format.pathChain(of: path, roots: record.paths)
        guard !spine.isEmpty else { return false }
        Task { _ = await walkOpen(spine, focus: path, record: record) }
        return true
    }
}

/// Shown while the comparison failed: what the Change column could not be
/// compared with, and why. Its own view because it reads the plans and the
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
        // The backup's name and moment are the window's title and subtitle;
        // this line says only why its Change column is not filled.
        VStack(alignment: .leading, spacing: 1) {
            if !heading.caption.isEmpty {
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
        let paths = lines.compactMap { run.unreadableItemPaths?[PathKey($0)] }
        return HStack(alignment: .top, spacing: 8) {
            // Beside words that say the same thing: decoration to VoiceOver.
            Image(systemName: RunRecord.Outcome.completedWithErrors.symbolName!)
                .foregroundStyle(StatusPalette.status(.completedWithErrors))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(unreadable > 0
                    ? "This backup is incomplete: \(Format.plural(unreadable, "item")) couldn’t be read when it was made."
                    : "This backup is incomplete: some files couldn’t be read when it was made.")
                    .font(.callout.weight(.medium))
                    // Not height-pinned, for BannerView's reason: the pane
                    // does not scroll, and a pinned text answers the split
                    // view's zero-width sizing query a character per line.
                    // Only the pane's minimum width keeps this one safe.
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let baseline, let path = run.unreadableItemPaths?[PathKey(line)],
                       heldBefore[PathKey(path)] != nil,
                       let page = model.page(ofBackup: baseline.id, in: repositoryID) {
                        // A row that goes somewhere: the backup before,
                        // which has it, open at the item — a file's
                        // versions under the tree.
                        Button {
                            router.showBackup(baseline.id, on: page, repositoryID: repositoryID, focusPath: path)
                        } label: {
                            Text(words(for: line, in: run))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                        .help("\(line)\nNot read by this backup — the backup of \(Format.timestamp(baseline.time)) has it. Show it there")
                    } else {
                        Text(words(for: line, in: run))
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
            .help("See this backup in Activity")
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
        .accessibilityElement(children: .contain)
    }

    private func words(for line: String, in run: RunRecord) -> String {
        let sources = run.planID.flatMap { model.plan(id: $0) }.map { [$0.path] } ?? []
        guard let words = RunRecordPresentation.unreadableItemWords(line: line, path: run.unreadableItemPaths?[PathKey(line)], sources: sources)
        else { return line }
        return "\(words.name) — \(words.reason) · \(words.location)"
    }
}

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
    let hasChangeColumn: Bool
    let changeHelp: String?
    /// The tree shows before its diff is in: until then a blank Change
    /// cell means "not compared yet", which the spinner says.
    let isComparing: Bool

    var body: some View {
        HStack(spacing: 6) {
            // The rows' depth indent: zero wide at the top level, but still
            // a slot the row's stack spaces.
            Spacer().frame(width: 0)
            Spacer().frame(width: 20)
            Spacer().frame(width: 16)
            Text("Name")
            Spacer(minLength: 12)
            if hasChangeColumn {
                HStack(spacing: 3) {
                    Text("Change")
                    if isComparing { ProgressView().controlSize(.mini) }
                }
                .frame(width: 56, alignment: .leading)
                .modifier(TileHelp(help: changeHelp))
            }
            Text("Date Modified")
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

private enum BrowserListGrammar {
    /// The ⌫ key as `onKeyPress` delivers it: U+007F, what AppKit's Delete
    /// key types. SwiftUI's `KeyEquivalent.delete` is U+0008, which ⌫ never
    /// produces, so only this constant matches the key.
    static let deleteKey = KeyEquivalent("\u{7F}")

    static func keyPress(
        _ press: KeyPress,
        selected: SnapshotNode?,
        hasParent: Bool,
        open: (SnapshotNode) -> Void,
        goUp: () -> Void
    ) -> KeyPress.Result {
        switch press.key {
        case .return:
            if let node = selected, node.isDirectory {
                open(node)
                return .handled
            }
            return .ignored
        case deleteKey:
            guard hasParent else { return .ignored }
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            guard hasParent else { return .ignored }
            goUp()
            return .handled
        default:
            return .ignored
        }
    }

    /// The parent of an absolute path for browser ascent: nil above a
    /// top-level item, which the caller renders as its pseudo-root.
    static func parent(of path: String) -> String? {
        let parent = ResticPath.parent(of: path)
        return parent == "/" ? nil : parent
    }
}

private struct FailureUnavailableView: View {
    let title: LocalizedStringKey
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).textSelection(.enabled)
        }
    }
}

/// A file picked in a backup's tree, by the backup it was picked in.
struct RestorePanePick: Equatable {
    let path: String
    let backupID: String
}

/// The pick as `onPick` hears it: only once the tree is read, so a record
/// switch does not close the versions under the tree while it loads.
private struct PickReport: Equatable {
    let isLoading: Bool
    let pick: RestorePanePick?
}

/// What the tree's look at this Mac is keyed by: the rows on screen, the
/// record they were built for and the disk's turn.
private struct PresenceKey: Equatable {
    let rows: [String]
    let loaded: String?
    let diskGeneration: UInt64
}
