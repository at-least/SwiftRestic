import SwiftUI

/// A page's Files view: one chain's folders and files across every backup —
/// a plan's, or a group's under Other backups — the tree on the leading
/// side, and the folder or file selected
/// in it on the trailing side, by version (`FilesPaneView`). The tree starts
/// at the page's edge rather than under a repository and a plan, and its
/// divider drags: a deep folder keeps its names.
///
/// A search field heads the tree: while it holds a query, the column lists
/// the chain's items named like it instead — from the index, items the
/// newest backup no longer holds included — and a hit selects as a tree row
/// does, so its versions open beside it.
///
/// What is open, selected and searched for is the router's, per chain, so
/// leaving the page — for a backup's record, Activity, another plan — and
/// coming back finds the tree as it was left.
struct FilesBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
    /// The chain's roots (`FileNode.roots`).
    let roots: FileNode
    /// The search field's prompt: what it searches, a plan's files or a
    /// group's.
    let searchPrompt: String
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

    private var selected: FileNode? {
        router.filesSelection[roots]
    }

    /// The selection the tree and the search's hits share. A hit picked
    /// opens the folders above it, so the tree lists it when the search
    /// ends.
    private var selection: Binding<FileNode?> {
        Binding(get: { router.filesSelection[roots] }, set: { item in
            router.filesSelection[roots] = item
            if let item, !query.isEmpty {
                router.openFolders(above: item, from: rootEntries.map(\.path))
            }
        })
    }

    /// The search as typed, trimmed; empty shows the tree.
    private var query: String {
        (router.filesSearchText[roots] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The roots level's folders, once read.
    private var rootEntries: [FileNode] {
        guard case let .loaded(level)? = filesTree.state(of: roots) else { return [] }
        return level.entries.map(\.node)
    }

    /// Every level the tree has on screen: the roots and the open folders
    /// under them.
    private var neededLevels: [FileNode] {
        filesTree.needed(under: roots, open: router.openFolders)
    }

    var body: some View {
        // An HStack, not HSplitView: the split would not narrow the pane
        // below the width it first laid out at, so a wider tree pushes the
        // window's content past its edges — the sidebar and the pane's
        // buttons clip.
        HStack(spacing: 0) {
            navigator
                .frame(width: min(max(treeWidth, treeWidthBounds.lowerBound), treeWidthBounds.upperBound))
            TreeEdge(width: $treeWidth, bounds: treeWidthBounds)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The levels on screen, read and kept current; keyed by what is
        // open and the listings they were read under, so opening a folder,
        // a refresh or the index taking it restarts it. Kept while a search
        // lists hits: the tree it ends on is read already.
        .task(id: filesTree.loadKey(neededLevels, model: model)) {
            await filesTree.keep(neededLevels, model: model)
        }
        // The search, asked again under each listing and each one the index
        // takes, as the levels are.
        .task(id: FilesSearchKey(
            roots: roots,
            query: query,
            listedAt: model.snapshotsLoadedAt(for: roots.repositoryID),
            indexTaken: model.indexTakenGeneration[roots.repositoryID]
        )) {
            await search()
        }
        // A first visit opens and selects the first root, so the pane has
        // something to show from the first look — and follows it when a
        // re-read moves it (`FilesTree.rootToSelect`).
        .onChange(of: rootEntries, initial: true) { old, new in
            guard let root = FilesTree.rootToSelect(selected: selected, old: old, new: new) else { return }
            router.filesSelection[roots] = root
            router.openFolders.insert(root)
        }
    }

    /// The leading column: the search field over the tree, or over the
    /// search's hits while it holds a query — one list at a time, sharing
    /// the selection.
    private var navigator: some View {
        VStack(spacing: 0) {
            SearchField(
                placeholder: searchPrompt,
                text: Binding(
                    get: { router.filesSearchText[roots] ?? "" },
                    set: { router.filesSearchText[roots] = $0 }
                ),
                takesFocus: router.filesSearchFocus == roots,
                onFocus: { router.filesSearchFocus = nil }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            Group {
                if query.isEmpty {
                    tree
                } else {
                    hits
                }
            }
            // The column's height whatever it shows: an empty state alone
            // would hug its text, and the field above it would float down to
            // the middle.
            .frame(maxHeight: .infinity)
        }
    }

    private var tree: some View {
        let rows = filesTree.rows(under: roots, open: router.openFolders)
        return ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(rows) { row in
                    treeRow(row)
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
    /// backups it reads meanwhile fill in. One read of the index, no restic.
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
                outcome = .hits(FilesSearchAnswer.entries(found.hits, under: roots))
                isTruncated = found.isTruncated
            } catch {
                outcome = .failed((error as? ResticError)?.errorDescription ?? error.localizedDescription)
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
    private func treeRow(_ row: FilesTree.Row) -> some View {
        switch row {
        case let .entry(entry, depth):
            FilesTreeRow(
                entry: entry,
                title: depth == 0 ? (entry.node.path as NSString).abbreviatingWithTildeInPath : entry.node.name,
                isExpanded: router.openFolders.contains(entry.node),
                onToggle: { toggle(entry.node) }
            )
            .padding(.leading, Self.indent(depth))
            .tag(entry.node)
        case let .more(folder, count, depth):
            // An action, not a place: it selects the folder whose rows it
            // stands for, and the pane lists them all.
            Button { router.filesSelection[roots] = folder } label: {
                Text("\(Format.count(count)) more items…")
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

    /// What the tree says while its roots list nothing: the listing's own
    /// row while the repository's listing is unread or holds no backup of
    /// the chain — "No backups yet" only then — and "Reading…" while the
    /// roots of a chain the listing does hold are read, a first backup's
    /// re-read included (the empty level stays on screen meanwhile); a
    /// failed roots read says so, with a Try Again that reads it again.
    @ViewBuilder
    private var rootsStatus: some View {
        let listed = model.snapshotListingOutcome(for: roots.repositoryID) == .loaded
        let holdsChain = model.snapshots(for: roots.repositoryID).contains {
            SnapshotIndex.chainKey(for: $0) == roots.chainKey
        }
        if case .failed? = filesTree.state(of: roots) {
            FilesStatusRow(node: roots)
        } else if listed, holdsChain {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            BackupsStatusRow(repositoryID: roots.repositoryID)
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
    /// is there to select, and walking down keeps the era.
    private func open(_ item: FileNode, versionID: String) {
        if let selected { router.openFolders.insert(selected) }
        router.filesVersionHint = versionID
        router.filesSelection[roots] = item
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
    /// A page's Overview | Files, in the window toolbar: Apple's guidance
    /// for switching a main window's view, and where Activity's All runs |
    /// Problems already sits.
    func pageTabPicker(_ selection: Binding<PageTab>) -> some View {
        toolbar {
            ToolbarItem {
                Picker("View", selection: selection) {
                    Text("Overview").tag(PageTab.overview)
                    Text("Files").tag(PageTab.files)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .help("The overview, or the folders and files across every backup, each by version")
            }
        }
    }
}

/// A Files pane's identity: its item, and which Show Versions opened it.
private struct FilesPaneIdentity: Hashable {
    let node: FileNode
    let opening: Int
}

/// What a Files tab's search is keyed by: the chain, the query, and the
/// listing it is read under and the one the index has taken — so a refresh
/// asks again, as the tree's levels are read again.
private struct FilesSearchKey: Equatable {
    let roots: FileNode
    let query: String
    let listedAt: Date?
    let indexTaken: UInt64?
}

/// One hit of a Files tab's search: the kind's icon and the name, over the
/// folder that holds it. An item the chain's newest backup no longer holds
/// is dimmed, with the day it was last backed up — the tree row's facts,
/// in the tree row's words.
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
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if !entry.isInNewest {
                Text(Format.until(entry.newest.time))
                    .font(.caption)
                    .accessibilityLabel("not in the newest backup, last backed up \(Format.timestamp(entry.newest.time))")
            }
        }
        .foregroundStyle(entry.isInNewest ? .primary : .secondary)
        .help(FilesTreeRow.help(for: entry))
        .accessibilityElement(children: .combine)
    }
}

/// The tree's edge: a hairline with a wider grip that drags the tree's width.
private struct TreeEdge: View {
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

/// One folder or file in a Files tree: a fold column (a chevron for a
/// folder, empty for a file, so names line up), the kind's icon and its
/// name. An item the chain's newest backup no longer holds is dimmed, and
/// says when it was last backed up.
struct FilesTreeRow: View {
    /// The fold column's width, a chevron's.
    static let foldWidth: CGFloat = 14

    let entry: FilesTree.Entry
    /// The name, or for a root its whole path, tilde-abbreviated.
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
            if entry.isInNewest {
                nameLabel
                Spacer(minLength: 0)
            } else {
                // The name is what identifies the row, so the day yields
                // first: beside the whole name when both fit, else left to
                // the tooltip, the label and the pane's line, the name
                // keeping the room — and truncating only past it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        nameLabel.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        dayTag
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
        .foregroundStyle(entry.isInNewest ? .primary : .secondary)
        .help(Self.help(for: entry))
        .accessibilityLabel(entry.isInNewest
            ? title
            : "\(title), not in the newest backup, last backed up \(Format.timestamp(entry.newest.time))")
    }

    /// The day it was last backed up, on the row: what made it dim,
    /// without a hover. VoiceOver has it in the label.
    private var dayTag: some View {
        Text(Format.until(entry.newest.time))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    /// The row's tooltip — a search's hit row wears it too: the item's
    /// whole path, or for one the newest backup no longer holds, when it
    /// was last backed up.
    static func help(for entry: FilesTree.Entry) -> String {
        entry.isInNewest
            ? entry.node.path
            : "Not in the newest backup — last backed up \(Format.timestamp(entry.newest.time))"
    }
}

/// What an open folder of a Files tree says while it lists nothing: still
/// reading, why it could not, or that it held nothing in any backup.
struct FilesStatusRow: View {
    @Environment(FilesTree.self) private var filesTree
    let node: FileNode

    var body: some View {
        switch filesTree.state(of: node) {
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                        .foregroundStyle(Theme.warning)
                        .accessibilityHidden(true)
                    Text(Format.firstSentence(message))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(message)
                }
                .font(.caption)
                Button("Try Again") { filesTree.reread(node) }
                    .controlSize(.small)
            }
        case let .loaded(level) where !level.isFallback:
            Text("Empty folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil, .loading, .loaded:
            // Still reading, or a fallback level: the index holds nothing
            // under it yet and the newest backup's listing had nothing at
            // this path either (a relative backup before the index has read
            // it, say). The next read may fill it, so it is not called empty.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
