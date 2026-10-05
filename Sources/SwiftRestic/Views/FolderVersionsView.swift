import SwiftUI

/// A folder of the Files view, by version: the backups that hold it in a
/// picker — newest first, from the index — and the folder as the chosen one
/// held it, listed by restic (or the browse cache): the tree walks the
/// folders, this flips them through time.
///
/// Items select several at a time, as in the Restore pane, and restore
/// together through the destination sheet, or drag to Finder one by one; a
/// double-click opens one in the tree, keeping the chosen time when the
/// item exists then, so walking down stays in the same era.
struct FolderVersionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode
    /// The backups holding the folder, newest first.
    let versions: [IndexVersion]
    /// The backup the pane opened at, when it has one to keep.
    @Binding var chosenID: String?
    /// Opens an item of the listing in the tree, at the chosen backup.
    let onOpen: (FileNode, _ versionID: String) -> Void

    @State private var nodes: [SnapshotNode] = []
    @State private var selection = Set<SnapshotNode.ID>()
    @State private var isLoading = false
    @State private var loadError: String?
    /// The restore waiting in the destination sheet.
    @State private var destinationRequest: RestoreDestinationRequest?
    @FocusState private var listIsFocused: Bool

    private var chosen: IndexVersion? {
        versions.first { $0.id == chosenID } ?? versions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            picker
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            listing
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // The listing belongs to one backup: a flip reads the folder again.
        .task(id: chosen?.id) { await fetch() }
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
    }

    @ViewBuilder
    private var picker: some View {
        HStack(spacing: 8) {
            Text("As backed up")
                .foregroundStyle(.secondary)
            Picker("As backed up", selection: Binding(
                get: { chosen?.id },
                set: { chosenID = $0 }
            )) {
                // The moment alone: the short ID is restic's handle, which
                // the restore sheet and Show in Backups carry.
                ForEach(versions, id: \.id) { version in
                    Text(verbatim: Format.timestamp(version.time))
                        .tag(Optional(version.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340)
            .disabled(versions.isEmpty)
            .help("Which backup the folder is listed from")
            Spacer()
        }
    }

    @ViewBuilder
    private var listing: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Could not read this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if isLoading, nodes.isEmpty {
            ProgressView("Reading…")
        } else if chosen == nil {
            // Why is the pane's banner's to say, while the index reads.
            ContentUnavailableView("No backup holds it yet", systemImage: "clock.arrow.circlepath")
        } else if nodes.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            // No gesture on the row: the list's own drag and double-click,
            // the Restore pane's measured rule — a gesture would claim every
            // click on a name or icon.
            List(nodes, selection: $selection) { child in
                SnapshotNodeRow(node: child)
                    .itemProvider { dragProvider(for: child) }
                    .tag(child.id)
            }
            .listStyle(.inset)
            .focusOnClick($listIsFocused)
            .contextMenu(forSelectionType: SnapshotNode.ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first, let child = nodes.first(where: { $0.id == id }) else { return }
                open(child)
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return .ignored }
                if selectedNodes.count == 1, let child = selectedNodes.first, child.isDirectory {
                    open(child)
                    return .handled
                }
                guard !selectedNodes.isEmpty, !model.isRestoring else { return .ignored }
                restoreSelection()
                return .handled
            }
            .help("Double-click or Return opens a folder in the tree; Return on files restores them; ⌘- or ⇧-click selects several items; drag an item to Finder to restore it there")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            RestoreProgressStrip()
            HStack {
                Button("Show in Backups") {
                    guard let chosen else { return }
                    router.showRestore(repositoryID: node.repositoryID, snapshotID: chosen.id, focusPath: node.path)
                }
                .disabled(chosen == nil)
                .help("Open this backup at this folder, in the sidebar's list of backups — see what changed, search it, or restore the whole backup")
                Spacer()
                Button(selection.isEmpty ? "Restore Folder…" : "Restore…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || model.isRestoring)
                    .help(selection.isEmpty
                        ? "Restore this whole folder as of the chosen backup"
                        : "Restore the selected items as of the chosen backup (Return)")
            }
        }
        .padding(12)
    }

    private var selectedNodes: [SnapshotNode] {
        nodes.filter { selection.contains($0.id) }
    }

    private func open(_ child: SnapshotNode) {
        guard let chosen else { return }
        onOpen(
            FileNode(repositoryID: node.repositoryID, chainKey: node.chainKey, path: child.path, isDirectory: child.isDirectory),
            chosen.id
        )
    }

    /// The list asks on every mouse-down on a row, so a drag that can never
    /// land offers nothing rather than posting its "Cannot drag" banner at
    /// each click (the Restore pane's rule).
    private func dragProvider(for child: SnapshotNode) -> NSItemProvider? {
        guard let chosen, model.repository(id: node.repositoryID) != nil, model.isResticAvailable else { return nil }
        return model.dragRestoreProvider(repositoryID: node.repositoryID, snapshotID: chosen.id, node: child)
    }

    /// The listing at the chosen backup. Only the newest ask writes: a flip
    /// while a read is in flight cancels it with the task.
    private func fetch() async {
        guard let version = chosen else {
            nodes = []
            return
        }
        isLoading = true
        do {
            let loaded = try await model.children(repositoryID: node.repositoryID, snapshotID: version.id, path: node.path)
            guard !Task.isCancelled else { return }
            nodes = loaded
            loadError = nil
            selection = selection.filter { id in loaded.contains { $0.id == id } }
        } catch {
            guard !Task.isCancelled else { return }
            nodes = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// The selected items, or with nothing selected the folder itself, as
    /// of the chosen backup: one item the way one always goes, several
    /// together less any inside another selected folder (the Restore pane's
    /// rule and wording).
    private func restoreSelection() {
        guard let chosen else { return }
        let repositoryID = node.repositoryID
        let shortID = String(chosen.id.prefix(8))
        let picked = selection.isEmpty
            ? [SnapshotNode(name: node.name, type: .dir, path: node.path)]
            : selectedNodes
        let items = RestoreBatch.covering(picked)
        let note = RestoreBatch.coveredNote(RestoreBatch.covered(picked))
        guard let first = items.first else { return }
        guard items.count > 1 else {
            destinationRequest = RestoreDestinationRequest(
                subject: .item(name: first.name, path: first.path, isDirectory: first.isDirectory),
                selectionNote: note,
                backupTime: chosen.time,
                snapshotShortID: shortID
            ) { directories, overwrite in
                model.restore(repositoryID: repositoryID, snapshotID: chosen.id, node: first, to: directories[0], overwrite: overwrite)
            }
            return
        }
        destinationRequest = RestoreDestinationRequest(
            subject: .items(items.map { RestoreItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }),
            selectionNote: note,
            backupTime: chosen.time,
            snapshotShortID: shortID
        ) { directories, overwrite in
            model.restore(
                repositoryID: repositoryID,
                snapshotID: chosen.id,
                items: zip(items, directories).map { (node: $0, directory: $1) },
                overwrite: overwrite
            )
        }
    }
}
