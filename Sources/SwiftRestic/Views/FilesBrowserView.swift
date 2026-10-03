import SwiftUI

/// A page's Files view: one chain's folders and files across every backup —
/// a plan's — the tree on the leading side, and the folder or file selected
/// in it on the trailing side, by version (`FilesPaneView`). The tree starts
/// at the page's edge rather than under a repository and a plan, and its
/// divider drags: a deep folder keeps its names.
///
/// What is open and selected is the router's, per chain, so leaving the
/// page — for a backup's record, Activity, another plan — and coming back
/// finds the tree as it was left.
struct FilesBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
    /// The chain's roots (`FileNode.roots`).
    let roots: FileNode

    @FocusState private var treeIsFocused: Bool

    private var selected: FileNode? {
        router.filesSelection[roots]
    }

    /// The folder the chain's newest backup names first: where a first
    /// visit opens, so the pane has something to show from the first look.
    private var firstRoot: FileNode? {
        FilesTree.firstRoot(of: roots.chainKey, repositoryID: roots.repositoryID, in: model.snapshots(for: roots.repositoryID))
    }

    /// Every level the tree has on screen: the roots and the open folders
    /// under them.
    private var neededLevels: [FileNode] {
        filesTree.needed(under: roots, open: router.openFolders)
    }

    var body: some View {
        HSplitView {
            // The split opens each side at its minimum, whatever its ideal
            // (seen live), so the minimum is the tree's opening width.
            tree
                .frame(minWidth: 240, maxWidth: 520)
            pane
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        // The levels on screen, read and kept current; keyed by what is
        // open and the listings they were read under, so opening a folder
        // or a refresh restarts it.
        .task(id: FilesLoadKey(nodes: neededLevels, listings: model.snapshotsLoadedAt)) {
            await filesTree.keep(neededLevels, model: model)
        }
        .onChange(of: firstRoot, initial: true) {
            guard selected == nil, let firstRoot else { return }
            router.filesSelection[roots] = firstRoot
            router.openFolders.insert(firstRoot)
        }
    }

    private var tree: some View {
        List(selection: Binding(
            get: { router.filesSelection[roots] },
            set: { router.filesSelection[roots] = $0 }
        )) {
            ForEach(filesTree.rows(under: roots, open: router.openFolders)) { row in
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
                BackupsStatusRow(repositoryID: roots.repositoryID)
            } else {
                FilesStatusRow(node: node)
                    .padding(.leading, Self.indent(depth) + FilesTreeRow.foldWidth + 4)
            }
        }
    }

    @ViewBuilder
    private var pane: some View {
        if let selected {
            FilesPaneView(node: selected, onOpen: open)
                // Each item's version state is its own.
                .id(selected)
        } else {
            ContentUnavailableView(
                "Select a folder or file",
                systemImage: "folder",
                description: Text("A folder shows as any backup held it, a file as each content it had.")
            )
        }
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

    /// Spoken when it folds, as a disclosure row was: the fold is a button,
    /// whose changed value VoiceOver does not read out by itself.
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

/// What a Files tree's load task is keyed by: the levels on screen, and the
/// listings they must be current with.
struct FilesLoadKey: Equatable {
    let nodes: [FileNode]
    let listings: [UUID: Date]
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
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                Image(systemName: entry.node.isDirectory ? "folder" : "doc")
            }
            .foregroundStyle(entry.isInNewest ? .primary : .secondary)
            .help(help)
            .accessibilityLabel(entry.isInNewest ? title : "\(title), not in the newest backup")
            Spacer(minLength: 0)
        }
    }

    private var help: String {
        entry.isInNewest
            ? entry.node.path
            : "Not in this plan's newest backup — last backed up \(Format.timestamp(entry.newest.time))"
    }
}

/// What an open folder of a Files tree says while it lists nothing: still
/// reading, why it could not, or that it held nothing in any backup.
struct FilesStatusRow: View {
    @Environment(FilesTree.self) private var filesTree
    let node: FileNode

    var body: some View {
        switch filesTree.state(of: node) {
        case nil, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        case .loaded:
            Text("Empty folder")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
