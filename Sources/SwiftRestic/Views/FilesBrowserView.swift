import AppKit
import SwiftUI

/// A plan's Files view: its folder as this Mac holds it now, the tree on the
/// leading side — each item beside what the plan's backups hold of it
/// (`FilesTree`) — and the folder or file selected in it on the trailing
/// side, by version (`FilesPaneView`): the way to a current file's past
/// versions. The tree starts at the page's edge rather than under a
/// repository and a plan, and its divider drags: a deep folder keeps its
/// names. When the plan's folder can't be read — its drive away, moved,
/// SwiftRestic kept out — the tab says why and points to the Backups tab.
///
/// While the page's search field — the toolbar's — holds a query, the
/// column lists the plan's items named like it instead of the tree — from
/// the index, items no longer on this Mac included — and a hit selects as a
/// tree row does, so its versions open beside it.
///
/// What is open, selected and searched for is the router's, per chain, so
/// leaving the page — for a backup's record, Activity, another plan — and
/// coming back finds the tree as it was left.
struct FilesBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
    /// The plan's roots (`FileNode.roots`).
    let roots: FileNode
    /// The plan's page, whose Backups tab the tab points to when the
    /// folder can't be read.
    let page: SidebarItem
    /// A search with no match offers Find Files over the whole repository,
    /// prefilled — other plans' backups included. The root presents it.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    @FocusState private var treeIsFocused: Bool
    @FocusState private var hitsAreFocused: Bool
    /// The latest answer to a search of this view, with the search it
    /// answers: one typed on another page, or before the last change to the
    /// query, is never shown for this one.
    @State private var searchAnswer: FilesSearchAnswer?
    /// The tree's width, dragged at its edge — the window's, kept across
    /// pages and tabs while it is open.
    @SceneStorage("FilesTreeWidth") private var treeWidth: Double = 280
    /// The view's own width, which bounds the drag: the pane keeps room for
    /// its version rows.
    @State private var width: CGFloat = 0
    /// The selected item while the tree has yet to bring it into view: set
    /// as the selection changes, spent once its row — or the "more items"
    /// row standing for it — is listed. A deep item a route selected (Show
    /// Versions, a capture's item) otherwise sat out of sight below.
    @State private var unrevealed: FileNode?
    /// The disk's turn the tab was shown in (`FilesTree.diskMayHaveChanged`):
    /// a request to show an item waits for the levels on its way to be read
    /// in it, so a folder last read away, or there, answers as it is now.
    @State private var shownTurn: UInt64?

    private var selected: FileNode? {
        router.filesSelection[roots]
    }

    /// The selection the tree and the search's hits share. A hit picked
    /// opens the folders above it, so the tree lists it when the search
    /// ends — Show Deleted Items too, when the tree lists it only as
    /// deleted (`reveal`).
    private var selection: Binding<FileNode?> {
        Binding(get: { router.filesSelection[roots] }, set: { item in
            router.filesSelection[roots] = item
            if let item, !query.isEmpty {
                router.openFolders(above: item, from: rootEntries.map(\.path))
                router.filesRevealRequest = item
            }
        })
    }

    /// The search as typed, trimmed; empty shows the tree.
    private var query: String {
        (router.filesSearchText[roots] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// What the chain's newest backup's own run could not read: an item
    /// that backup lacks for that reason says so.
    private var newestUnread: UnreadItems {
        model.snapshots(for: roots.repositoryID)
            .first { SnapshotIndex.chainKey(for: $0) == roots.chainKey }
            .map { model.unreadItems(inBackup: $0.id) } ?? UnreadItems()
    }

    /// The roots level's one folder — the plan's — once read.
    private var rootEntries: [FileNode] {
        guard case let .loaded(level)? = filesTree.state(of: roots) else { return [] }
        return level.entries.map(\.node)
    }

    /// Why the plan's folder can't be listed, when it can't: the root's own
    /// read — its drive away, nothing at its path — or its listing, refused.
    private var absence: FolderAbsence? {
        if case let .unavailable(absence, _)? = filesTree.state(of: roots) { return absence }
        if let root = rootEntries.first, case let .unavailable(absence, _)? = filesTree.state(of: root) { return absence }
        return nil
    }

    /// The plan's folder, as its path names it — what Reveal in Finder
    /// selects when the folder refuses SwiftRestic.
    private var planPath: String? {
        guard case let .plan(id) = page, let plan = model.plan(id: id) else { return nil }
        return ResticService.expandTilde(plan.path)
    }

    /// Every level the tree has on screen: the roots and the open folders
    /// under them, a deleted one's too while Show Deleted Items lists it.
    private var neededLevels: [FileNode] {
        filesTree.needed(under: roots, open: router.openFolders, showsDeleted: router.filesShowsDeletedItems)
    }

    /// What the router's request to show an item comes to now
    /// (`FilesTree.reveal`): nil with none, a wait until the tab's turn is
    /// known and the levels on the item's way are read in it.
    private var reveal: FilesTree.Reveal? {
        guard let item = router.filesRevealRequest else { return nil }
        guard let shownTurn else { return .wait }
        return FilesTree.reveal(item, under: roots, open: router.openFolders, states: filesTree.states, turn: shownTurn)
    }

    var body: some View {
        Group {
            if let absence {
                unavailable(absence)
            } else {
                // An HStack, not HSplitView: the split would not narrow the
                // pane below the width it first laid out at, so a wider tree
                // pushes the window's content past its edges — the sidebar
                // and the pane's buttons clip.
                HStack(spacing: 0) {
                    navigator
                        .frame(width: min(max(treeWidth, treeWidthBounds.lowerBound), treeWidthBounds.upperBound))
                    TreeEdge(width: $treeWidth, bounds: treeWidthBounds)
                    pane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The levels on screen, read and kept current; keyed by what is
        // open, the listings they were read under and the disk's turn, so
        // opening a folder, a refresh, the index taking it or the disk
        // maybe changing restarts it. Kept while a search lists hits — the
        // tree it ends on is read already — and while the folder can't be
        // read, so it is read again when that may have changed.
        .task(id: filesTree.loadKey(neededLevels, model: model)) {
            await filesTree.keep(neededLevels, model: model)
        }
        // The search, asked again under each listing, each one the index
        // takes and each turn of the disk, as the levels are.
        .task(id: FilesSearchKey(
            roots: roots,
            query: query,
            listedAt: model.snapshotsLoadedAt(for: roots.repositoryID),
            indexTaken: model.indexTakenGeneration[roots.repositoryID],
            diskGeneration: filesTree.diskGeneration
        )) {
            await search()
        }
        // A first visit opens and selects the plan's folder, so the pane has
        // something to show from the first look — and follows it when a
        // re-read moves it (`FilesTree.rootToSelect`).
        .onChange(of: rootEntries, initial: true) { old, new in
            guard let root = FilesTree.rootToSelect(selected: selected, old: old, new: new) else { return }
            router.filesSelection[roots] = root
            router.openFolders.insert(root)
        }
        // A request to show an item — Show Versions', a hit picked, one
        // opened from the pane — is spent once the tree can answer it: one
        // it lists only as deleted turns Show Deleted Items on, so it has a
        // row (the user's call), the View menu's tick saying so.
        .onChange(of: reveal, initial: true) { _, answer in
            guard let answer, answer != .wait else { return }
            router.filesRevealRequest = nil
            if answer == .showDeleted { router.filesShowsDeletedItems = true }
        }
        // The tree does not watch the folder: it is read again when the tab
        // shows, when SwiftRestic comes to the front — another app may have
        // changed the folder meanwhile — and when a volume comes or goes.
        .onAppear {
            filesTree.diskMayHaveChanged()
            shownTurn = filesTree.diskGeneration
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
    }

    /// The tab when the plan's folder can't be read: why, what to do about
    /// a refusal and the fix to press, and the way to what the backups hold
    /// of it — no tree of an older backup in its place (the user's call).
    private func unavailable(_ absence: FolderAbsence) -> some View {
        let remedy = absence.remedy(fullDiskAccess: model.fullDiskAccess)
        return ContentUnavailableView {
            Label(absence.title, systemImage: Self.symbol(of: absence))
        } description: {
            Text(verbatim: [
                absence.detail(fullDiskAccess: model.fullDiskAccess),
                remedy?.steps,
                "Its backups are on the Backups tab.",
            ].compactMap { $0 }.joined(separator: " "))
        } actions: {
            HStack {
                if let fix = remedy?.fix, let planPath {
                    FolderFixButton(fix: fix, path: planPath)
                }
                Button("Show Backups") { router.setTab(.backups, of: page) }
            }
        }
    }

    private static func symbol(of absence: FolderAbsence) -> String {
        switch absence {
        case .volumeAway: "externaldrive.badge.xmark"
        case .missing: "questionmark.folder"
        case .blockedByMacOS, .deniedByFilePermissions, .unreadable: "lock"
        }
    }

    /// The leading column: the tree, or the search's hits while the
    /// toolbar's field holds a query — one list at a time, sharing the
    /// selection.
    private var navigator: some View {
        Group {
            if query.isEmpty {
                tree
            } else {
                hits
            }
        }
        // The column's height whatever it shows: an empty state alone would
        // hug its text.
        .frame(maxHeight: .infinity)
    }

    private var tree: some View {
        VStack(spacing: 0) {
            treeList
            Divider()
            treeFooter
        }
    }

    /// The View menu's Show Deleted Items, on screen beside the tree it
    /// changes. Only under the tree: the search's hits list deleted items
    /// whatever it says.
    private var treeFooter: some View {
        @Bindable var router = router
        return Toggle("Show Deleted Items", isOn: $router.filesShowsDeletedItems)
            .toggleStyle(.checkbox)
            .help("Also list items deleted from this Mac that its backups still hold")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private var treeList: some View {
        let rows = filesTree.rows(under: roots, open: router.openFolders, showsDeleted: router.filesShowsDeletedItems)
        let unread = newestUnread
        return ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(rows) { row in
                    treeRow(row, unread: unread)
                }
            }
            .listStyle(.inset)
            .focusOnClick($treeIsFocused)
            // The keyboard an outline gives its disclosure rows: with a folder
            // selected, → opens it and ← closes it. Plain arrows only, the
            // restore pane's rule for its own folds.
            .onKeyPress(.rightArrow, phases: .down) { fold(open: true, press: $0) }
            .onKeyPress(.leftArrow, phases: .down) { fold(open: false, press: $0) }
            // Brought into view once, when its row is first there — the
            // levels above it may still be reading — and never again, so a
            // re-read does not pull the list back from where it was
            // scrolled. A click's own row is in view already. The tree a
            // search ends on is a new list, with the hit picked in the
            // search already listed: its first look counts as the row
            // arriving.
            .onChange(of: selected, initial: true) { _, item in unrevealed = item }
            .onChange(of: unrevealed.flatMap { FilesTree.row(showing: $0, in: rows) }, initial: true) { _, row in
                guard let row else { return }
                unrevealed = nil
                // A turn later: the row may join the list in this update.
                Task { @MainActor in proxy.scrollTo(row) }
            }
        }
    }

    /// The search's answer in the column: the hits, or why there are none.
    @ViewBuilder
    private var hits: some View {
        if let answer = searchAnswer, answer.roots == roots, answer.query == query {
            switch answer.outcome {
            case let .failed(message):
                // A broken index is its own answer: never a "no matches".
                ContentUnavailableView {
                    Label("Search failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message).textSelection(.enabled)
                }
            case let .hits(entries) where entries.isEmpty:
                // Not a dead end: other plans' backups, and — while the index
                // reads — the backups it has not reached, are Find Files'.
                ContentUnavailableView {
                    Label("No matches", systemImage: "magnifyingglass")
                } description: {
                    // Verbatim: a query is no Markdown — its asterisks would
                    // be eaten as emphasis.
                    Text(verbatim: answer.isComplete
                        ? "No name in these backups has a word starting with “\(query)”."
                        : FilesSearchAnswer.indexStillReading)
                } actions: {
                    Button("Search All Backups…") { onSearchAllBackups(roots.repositoryID, query) }
                        .help("Search every backup in this repository with Find Files, other plans' included")
                }
            case let .hits(entries):
                VStack(spacing: 0) {
                    List(selection: selection) {
                        ForEach(entries) { entry in
                            FilesSearchRow(entry: entry)
                                .tag(entry.node)
                        }
                    }
                    .listStyle(.inset)
                    .focusOnClick($hitsAreFocused)
                    .onKeyPress(.return, phases: .down) { endSearch($0) }
                    .onKeyPress(.escape, phases: .down) { endSearch($0) }
                    .help("Return or Esc ends the search and shows the selected item in the tree")
                    if let note = FilesSearchAnswer.note(isTruncated: answer.isTruncated, isComplete: answer.isComplete) {
                        Divider()
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Return or Esc in the hits: the search ends, and the tree it gives
    /// way to shows the selected hit — its folders were opened as it was
    /// picked.
    private func endSearch(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
        router.filesSearchText[roots] = nil
        return .handled
    }

    /// Answers the query, and again every `recheckInterval` while the index
    /// is still reading the repository — the tree's own rule — so hits from
    /// backups it reads meanwhile fill in. One read of the index, no restic,
    /// then one listing per hit's folder (`DiskFolder.present`): a hit no
    /// longer on this Mac, by its bytes as the tree's rows tell it, is
    /// dimmed.
    private func search() async {
        let roots = roots
        let query = query
        guard !query.isEmpty else { return }
        while !Task.isCancelled {
            // Asked before the search: a backup once read stays read, so an
            // index complete beforehand has read every backup the hits come
            // from.
            let complete = await model.indexIsComplete(repositoryID: roots.repositoryID)
            let outcome: FilesSearchAnswer.Outcome
            var isTruncated = false
            do {
                let found = try await model.searchIndex(
                    pattern: query, inChain: roots.chainKey, repositoryID: roots.repositoryID
                )
                let paths = found.hits.map(\.path)
                let present = await Task.detached(priority: .userInitiated) { DiskFolder.present(paths) }.value
                outcome = .hits(FilesSearchAnswer.entries(found.hits, under: roots, present: present))
                isTruncated = found.isTruncated
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            searchAnswer = FilesSearchAnswer(
                roots: roots, query: query, outcome: outcome, isComplete: complete, isTruncated: isTruncated
            )
            guard !complete, case .hits = outcome else { return }
            do {
                try await Task.sleep(for: FilesTree.recheckInterval)
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private func treeRow(_ row: FilesTree.Row, unread: UnreadItems) -> some View {
        switch row {
        case let .entry(entry, depth):
            FilesTreeRow(
                entry: entry,
                notRead: entry.standing == .notBackedUp ? unread.reason(for: entry.node.path) : nil,
                // The plan's folder by its name, as the sidebar names the
                // plan; its path is the window's subtitle.
                title: entry.node.name.isEmpty ? entry.node.path : entry.node.name,
                isExpanded: router.openFolders.contains(entry.node),
                onToggle: { toggle(entry.node) }
            )
            .padding(.leading, Self.indent(depth))
            .tag(entry.node)
        case let .more(folder, count, depth):
            // An action, not a place: it selects the folder whose rows it
            // stands for, and the pane lists them all.
            Button { router.filesSelection[roots] = folder } label: {
                Text("\(Format.plural(count, "more item"))…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, Self.indent(depth) + FilesTreeRow.foldWidth + 4)
            .help("Show everything in “\(folder.name)” in the pane")
        case let .status(node, depth):
            if node.isRoots {
                rootsStatus
            } else {
                FilesStatusRow(node: node)
                    .padding(.leading, Self.indent(depth) + FilesTreeRow.foldWidth + 4)
            }
        }
    }

    /// What the tree says while its root is not listed: "Reading…" while
    /// the plan's folder is looked at, a failed read with a Try Again that
    /// reads it again. A folder that can't be read is the whole tab's
    /// (`unavailable`).
    @ViewBuilder
    private var rootsStatus: some View {
        if case .failed? = filesTree.state(of: roots) {
            FilesStatusRow(node: roots)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        if let selected {
            FilesPaneView(node: selected, onOpen: open)
                // Each item's version state is its own, and Show Versions
                // opens it anew.
                .id(FilesPaneIdentity(node: selected, opening: router.filesPaneOpenings))
        } else {
            ContentUnavailableView(
                "Select a folder or file",
                systemImage: "folder",
                description: Text("A folder shows as any backup held it, a file as each content it had.")
            )
        }
    }

    /// How far the tree's edge drags: no narrower than a folder's name
    /// needs, no wider than leaves the pane its rows.
    private var treeWidthBounds: ClosedRange<Double> {
        let lower = 220.0
        return lower...max(lower, min(560, Double(width) - 380))
    }

    /// Each level one fold-step deeper: a row starts with its fold column,
    /// so a file's name lines up with a folder's.
    private static func indent(_ depth: Int) -> CGFloat {
        CGFloat(depth) * (FilesTreeRow.foldWidth + 4)
    }

    /// Opens an item of the selected folder's listing in the tree, at the
    /// backup the listing was read from: the folder opens so the item's row
    /// is there to select, and walking down keeps the era — Show Deleted
    /// Items too, when the tree lists it only as deleted (`reveal`).
    private func open(_ item: FileNode, versionID: String) {
        if let selected { router.openFolders.insert(selected) }
        router.filesVersionHint = versionID
        router.filesSelection[roots] = item
        router.filesRevealRequest = item
    }

    /// Spoken when it folds: the fold is a button, whose changed value
    /// VoiceOver does not read out by itself.
    private func toggle(_ node: FileNode) {
        let opened = router.openFolders.remove(node) == nil
        if opened { router.openFolders.insert(node) }
        AccessibilityNotification.Announcement("Contents of “\(node.name)” \(opened ? "expanded" : "collapsed")").post()
    }

    private func fold(open: Bool, press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
              let selected, selected.isDirectory
        else { return .ignored }
        if open != router.openFolders.contains(selected) { toggle(selected) }
        return .handled
    }
}

extension View {
    /// A page's Overview | Backups | Files — a group's Overview | Backups
    /// (`SidebarItem.pageTabs`) — in the middle of the window toolbar:
    /// Apple's guidance for switching a main window's view (the HIG's
    /// center area holds the common controls), clear of the trailing
    /// corner, where the search field sits.
    func pageTabPicker(_ selection: Binding<PageTab>, tabs: [PageTab]) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: selection) {
                    // The View menu's words too (⌘1–⌘3).
                    ForEach(tabs, id: \.self) { tab in
                        Text(tab.menuTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                // Each segment as wide as the three's were.
                .frame(width: 80 * CGFloat(tabs.count))
                .help(tabs.contains(.files)
                    ? "The overview; the backups, each one's files beside the list; or the plan's folder as this Mac holds it, each item by version"
                    : "The overview; or the backups, each one's files beside the list")
            }
        }
    }
}

extension View {
    /// A plan's page's search, in the window toolbar's trailing field — the
    /// HIG's place for it ("Put a search field at the trailing side of the
    /// toolbar for many common uses"). Its scope follows the tab: on Backups, the
    /// open backup; on Files and Overview, the page's files across every
    /// backup — typed on Overview, the page turns to Files, where the hits
    /// list. ⇧⌘F focuses it (`AppRouter.searchFocus`).
    func pageSearch(page: SidebarItem, roots: FileNode?, filesPrompt: String) -> some View {
        modifier(PageSearch(page: page, files: PageSearch.Files(roots: roots, prompt: filesPrompt)))
    }

    /// A group's page's search under Other backups, the same field: the
    /// open backup on either tab, the page having no Files tab — typed on
    /// Overview, the page turns to Backups, where its newest backup opens
    /// unless another was picked.
    func backupsPageSearch(page: SidebarItem) -> some View {
        modifier(PageSearch(page: page, files: nil))
    }
}

private struct PageSearch: ViewModifier {
    /// A plan's Files tab, what its field searches there.
    struct Files {
        /// The chain the tab lists; nil for a plan with no repository,
        /// which has nothing to search.
        let roots: FileNode?
        let prompt: String
    }

    @Environment(AppRouter.self) private var router
    let page: SidebarItem
    /// Nil on a page with no Files tab: a group's.
    let files: Files?
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .searchable(text: text, placement: .toolbar, prompt: Text(verbatim: prompt))
            .searchFocused($isFocused)
            .onChange(of: router.searchFocus, initial: true) { _, asked in
                guard asked == page else { return }
                router.searchFocus = nil
                // A turn later: ⇧⌘F may have switched the tab in this
                // update, and the field takes the focus once it is there.
                Task { @MainActor in isFocused = true }
            }
    }

    private var onBackups: Bool { files == nil || router.tab(of: page) == .backups }

    private var prompt: String { onBackups ? "Search this backup" : files?.prompt ?? "" }

    private var text: Binding<String> {
        Binding(
            get: {
                if onBackups { return router.backupsSearchText[page] ?? "" }
                return files?.roots.flatMap { router.filesSearchText[$0] } ?? ""
            },
            set: { newValue in
                if onBackups {
                    router.backupsSearchText[page] = newValue
                    if !newValue.isEmpty, router.tab(of: page) == .overview {
                        router.setTab(.backups, of: page)
                    }
                    return
                }
                guard let roots = files?.roots else { return }
                router.filesSearchText[roots] = newValue
                if !newValue.isEmpty, router.tab(of: page) == .overview {
                    router.setTab(.files, of: page)
                }
            }
        )
    }
}

/// A Files pane's identity: its item, and which Show Versions opened it.
private struct FilesPaneIdentity: Hashable {
    let node: FileNode
    let opening: Int
}

/// What a Files tab's search is keyed by: the chain, the query, the
/// listing it is read under and the one the index has taken, and the disk's
/// turn — so a refresh asks again, as the tree's levels are read again, and
/// a hit deleted meanwhile dims.
private struct FilesSearchKey: Equatable {
    let roots: FileNode
    let query: String
    let listedAt: Date?
    let indexTaken: UInt64?
    let diskGeneration: UInt64
}

/// One hit of a Files tab's search: the kind's icon and the name, over the
/// folder that holds it. An item no longer on this Mac is dimmed, with the
/// day it was last backed up — the tree row's facts, in the tree row's
/// words.
struct FilesSearchRow: View {
    let entry: FilesTree.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: entry.node.isDirectory ? "folder" : "doc")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((ResticPath.parent(of: entry.node.path) as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let tag = entry.tag {
                Text(tag)
                    .font(.caption)
                    .accessibilityLabel(entry.spokenStanding(notRead: nil) ?? tag)
            }
        }
        .foregroundStyle(entry.standing == .onDisk ? .primary : .secondary)
        .help(entry.help(notRead: nil))
        .accessibilityElement(children: .combine)
    }
}

/// A list's edge beside its pane — a Files tab's tree, a Backups tab's
/// list: a hairline with a wider grip that drags the list's width.
struct TreeEdge: View {
    @Binding var width: Double
    let bounds: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + drag.translation.width, bounds.lowerBound), bounds.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}

/// A fold's disclosure mark: chevron right when closed, down when open.
/// The row around it is the button.
struct FoldChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// One folder or file in a Files tree: a fold column (a chevron for a
/// folder, empty for a file, so names line up), the kind's icon and its
/// name. An item no backup of the plan holds is dimmed and says it is not
/// backed up; one only the backups hold, when shown, says when it was last
/// backed up.
struct FilesTreeRow: View {
    /// The fold column's width, a chevron's.
    static let foldWidth: CGFloat = 14

    let entry: FilesTree.Entry
    /// Why the chain's newest backup lacks it, when that backup's own run
    /// could not read it (`UnreadItems.reason`).
    let notRead: String?
    /// The name, or the path for a node with none.
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if entry.node.isDirectory {
                Button(action: onToggle) {
                    FoldChevron(isExpanded: isExpanded)
                        .frame(width: Self.foldWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide this folder's contents" : "Show this folder's contents")
                .accessibilityLabel("Contents of “\(title)”")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            } else {
                Color.clear
                    .frame(width: Self.foldWidth)
                    .accessibilityHidden(true)
            }
            if let tag = entry.tag {
                // The name is what identifies the row, so the tag yields
                // first: beside the whole name when both fit, else left to
                // the tooltip, the label and the pane, the name keeping the
                // room — and truncating only past it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        nameLabel.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        tagLabel(tag)
                    }
                    HStack(spacing: 4) {
                        nameLabel.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 4) {
                        nameLabel
                        Spacer(minLength: 0)
                    }
                }
            } else {
                nameLabel
                Spacer(minLength: 0)
            }
        }
    }

    private var nameLabel: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: entry.node.isDirectory ? "folder" : "doc")
        }
        .foregroundStyle(entry.standing == .onDisk ? .primary : .secondary)
        .help(entry.help(notRead: notRead))
        .accessibilityLabel([title, entry.spokenStanding(notRead: notRead)].compactMap { $0 }.joined(separator: ", "))
    }

    /// What made it dim, on the row, without a hover. VoiceOver has it in
    /// the label.
    private func tagLabel(_ tag: String) -> some View {
        Text(tag)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// What an open folder of a Files tree says while it lists nothing: still
/// reading, why it could not — with the fix to press when SwiftRestic is
/// refused, else Try Again — or that it holds nothing.
struct FilesStatusRow: View {
    @Environment(AppModel.self) private var model
    @Environment(FilesTree.self) private var filesTree
    let node: FileNode

    var body: some View {
        switch filesTree.state(of: node) {
        case let .failed(message):
            problem(Format.firstSentence(message), help: message, reason: nil, fix: nil)
        case let .unavailable(absence, _):
            let reason = absence.detail(fullDiskAccess: model.fullDiskAccess)
            let remedy = absence.remedy(fullDiskAccess: model.fullDiskAccess)
            problem(
                absence.title,
                help: [reason, remedy?.steps].compactMap { $0 }.joined(separator: " "),
                reason: remedy == nil ? nil : reason,
                fix: remedy?.fix
            )
        case .loaded:
            Text("Empty folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The headline, the reason under it when steps follow — the steps in
    /// the tooltip, the column being narrow — and the fix, or Try Again.
    /// A fix needs no Try Again: the tree is read again when SwiftRestic
    /// comes back to the front from System Settings or Finder.
    private func problem(_ words: String, help: String, reason: String?, fix: FolderAbsence.Remedy.Fix?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .imageScale(.small)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
                Text(words)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(help)
            }
            .font(.caption)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .help(help)
            }
            if let fix {
                FolderFixButton(fix: fix, path: node.path)
                    .controlSize(.small)
            } else {
                Button("Try Again") { filesTree.reread(node) }
                    .controlSize(.small)
            }
        }
    }
}

/// The fix a folder that refuses SwiftRestic offers
/// (`FolderAbsence.Remedy`): System Settings' Full Disk Access list, or the
/// folder selected in Finder, where File › Get Info shows its permissions.
struct FolderFixButton: View {
    let fix: FolderAbsence.Remedy.Fix
    let path: String

    var body: some View {
        switch fix {
        case .openFullDiskAccessSettings:
            FullDiskAccessButton()
        case .revealInFinder:
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .help("Select it in Finder, where File › Get Info shows its permissions")
        }
    }
}
