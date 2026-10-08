import SwiftUI

/// A folder of the Files view, by version: the backups holding it in a
/// picker — newest first, from the index — what changed in it since the
/// backup before (from the index, no restic), and the folder as the chosen
/// backup held it, listed by restic or the browse cache, each item marked
/// with how it changed. The tree walks the folders; this flips them
/// through time.
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
    /// What changed in the folder since the backup before the chosen one
    /// that holds it; nil while unread, when there is no backup before, or
    /// when the index has not read both.
    @State private var changes: FolderChanges?
    @State private var changesError: String?
    /// The restore waiting in the destination sheet.
    @State private var destinationRequest: RestoreDestinationRequest?
    @FocusState private var listIsFocused: Bool

    private var chosen: IndexVersion? {
        versions.first { $0.id == chosenID } ?? versions.first
    }

    /// The backup before the chosen one that holds the folder — what its
    /// changes count from.
    private var previous: IndexVersion? {
        guard let chosen, let index = versions.firstIndex(of: chosen), index + 1 < versions.count else { return nil }
        return versions[index + 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                picker
                changeSummary
            }
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
        // So do its changes, which a re-read of the holders can also move.
        .task(id: [chosen?.id, previous?.id]) { await readChanges() }
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
                // the restore sheet and Show in Backups carry. A history
                // past one month is grouped by month, the Compare sheet's
                // landmarks, so a year of backups is not one flat scroll.
                if let months = DiffCandidateGrouping.landmarks(in: versions, time: \.time) {
                    ForEach(months, id: \.label) { month in
                        Section(month.label) {
                            ForEach(month.items, id: \.id) { version in
                                Text(verbatim: Format.timestamp(version.time))
                                    .tag(Optional(version.id))
                            }
                        }
                    }
                } else {
                    ForEach(versions, id: \.id) { version in
                        Text(verbatim: Format.timestamp(version.time))
                            .tag(Optional(version.id))
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340)
            .disabled(versions.isEmpty)
            .help("Which backup the folder is listed from")
            Spacer()
        }
    }

    /// What changed in the folder itself since the backup before — the gone
    /// items by name, since the listing below is the chosen backup's — or,
    /// when the index cannot say, why. Nothing for the oldest backup holding
    /// it, nor while the index has yet to read both.
    @ViewBuilder
    private var changeSummary: some View {
        if let changesError {
            Label("Could not compare with the backup before", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(changesError)
        } else if let changes, let previous {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: changes.summary(since: previous.time))
                    .help("Compared with the backup before that holds this folder — what changed inside its folders is theirs to say, and a change of a file's dates or permissions alone is not counted")
                // Each name opens the item in the tree at the backup
                // before, which has it.
                if let removed = changes.removedNames {
                    RemovedNamesLine(names: RemovedNames(changes.removedItems), help: removed, before: previous.time) { item in
                        onOpen(
                            FileNode(repositoryID: node.repositoryID, chainKey: node.chainKey, path: item.path, isDirectory: item.isDirectory),
                            previous.id
                        )
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
            // Saying why is the pane's banner's job, while the index reads.
            ContentUnavailableView("No backup holds it yet", systemImage: "clock.arrow.circlepath")
        } else if nodes.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            // No gesture on the row — the list's own drag and double-click
            // handle it, the Restore pane's rule: a gesture would claim every
            // click on a name or icon.
            List(nodes, selection: $selection) { child in
                SnapshotNodeRow(node: child, change: changes?.marks[PathKey(child.path)])
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
                // By the rows selected in this listing, not the ids kept
                // across a flip: while a backup's listing is read, or after
                // its read failed, none are, and the button is the folder's.
                Button(selectedNodes.isEmpty ? "Restore Folder…" : "Restore…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || model.isRestoring)
                    .help(selectedNodes.isEmpty
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

    /// The folder's changes from the backup before to the chosen one, from
    /// the index — one read, no restic.
    private func readChanges() async {
        guard let chosen, let previous else {
            changes = nil
            changesError = nil
            return
        }
        do {
            let read = try await model.indexedChanges(
                underPath: node.path, inChain: node.chainKey,
                from: previous.id, to: chosen.id, repositoryID: node.repositoryID
            )
            guard !Task.isCancelled else { return }
            changes = read
            changesError = nil
        } catch {
            guard !Task.isCancelled else { return }
            changes = nil
            changesError = error.localizedDescription
        }
    }

    /// The listing at the chosen backup. Only the newest ask writes: a flip
    /// while a read is in flight cancels it with the task. The last
    /// backup's rows go as the flip starts: under the new backup's picker
    /// and its change marks they would read as that backup's, and Return
    /// would restore them from it. The selection's ids stay, to keep the
    /// rows the new listing still holds.
    private func fetch() async {
        nodes = []
        guard let version = chosen else { return }
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
    /// of the chosen backup (`RestoreDestinationRequest.picked`'s rule).
    private func restoreSelection() {
        guard let chosen else { return }
        let picked = selectedNodes.isEmpty
            ? [SnapshotNode(name: node.name, type: .dir, path: node.path)]
            : selectedNodes
        destinationRequest = RestoreDestinationRequest.picked(
            picked.map { RestoreSource($0, snapshotID: chosen.id, backupTime: chosen.time) },
            repositoryID: node.repositoryID,
            model: model
        )
    }
}
