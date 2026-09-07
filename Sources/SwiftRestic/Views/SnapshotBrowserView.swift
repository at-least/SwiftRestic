import SwiftUI

struct SnapshotBrowserTarget: Identifiable {
    var repositoryID: UUID
    var snapshot: Snapshot
    var id: String { "\(repositoryID.uuidString)-\(snapshot.id)" }
}

/// Browses the contents of one snapshot, one directory at a time.
///
/// `restic ls <id>` on its own walks the entire tree, which is unusable for a
/// browser, so each level is fetched on demand with an explicit directory path.
struct SnapshotBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: SnapshotBrowserTarget

    /// `nil` = the pseudo-root that lists the snapshot's backed-up paths.
    @State private var currentPath: String?
    @State private var nodes: [SnapshotNode] = []
    @State private var selection: SnapshotNode.ID?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: currentPath) { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                goUp()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPath == nil)
            .help("Go up")

            VStack(alignment: .leading, spacing: 1) {
                Text(target.snapshot.time.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(currentPath ?? "Backed-up folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(target.snapshot.shortID)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    @ViewBuilder
    private var body_: some View {
        if isLoading {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            ContentUnavailableView {
                Label("Could not read this folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if nodes.isEmpty {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            List(nodes, selection: $selection) { node in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(node.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(node.name)
                        .lineLimit(1)
                    Spacer()
                    if !node.isDirectory {
                        Text(Format.bytes(node.size))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(Format.timestamp(node.mtime))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 140, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(node) }
                .tag(node.id)
            }
            .listStyle(.inset)
        }
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

            Text("Restoring overwrites existing files at the destination.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Restore Entire Snapshot…") { restoreWholeSnapshot() }
                    .disabled(model.isRestoring)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore Selected…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedNode == nil || model.isRestoring)
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private var selectedNode: SnapshotNode? {
        guard let selection else { return nil }
        return nodes.first { $0.id == selection }
    }

    private func icon(for node: SnapshotNode) -> String {
        switch node.type {
        case .dir: "folder.fill"
        case .symlink: "arrow.turn.up.right"
        case .file: "doc"
        default: "questionmark.square.dashed"
        }
    }

    private func open(_ node: SnapshotNode) {
        guard node.isDirectory else { return }
        currentPath = node.path
        selection = nil
    }

    private func goUp() {
        guard let currentPath else { return }
        // Stop at the snapshot's own roots rather than walking up to "/".
        if target.snapshot.paths.contains(currentPath) {
            self.currentPath = nil
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            self.currentPath = parent.isEmpty || parent == "/" ? nil : parent
        }
        selection = nil
    }

    private func load() async {
        loadError = nil
        guard let currentPath else {
            // Pseudo-root: present each backed-up path as a directory entry.
            // The listing is built on the spot, so this path is never busy —
            // and since a cancelled predecessor skips its own cleanup below,
            // the spinner has to be cleared here.
            nodes = target.snapshot.paths.map { path in
                SnapshotNode.directory(path: path)
            }
            isLoading = false
            return
        }
        isLoading = true
        do {
            let loaded = try await model.children(
                repositoryID: target.repositoryID,
                snapshotID: target.snapshot.id,
                path: currentPath
            )
            // `.task(id: currentPath)` cancels this load the moment another
            // directory is opened, and restic reports that as an error. The
            // newer load owns the view state from then on — writing here would
            // clobber its results and leave our "cancelled" over them.
            guard !Task.isCancelled else { return }
            nodes = loaded
            loadError = nil
            isLoading = false
        } catch {
            guard !Task.isCancelled else { return }
            nodes = []
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func restoreSelection() {
        guard let node = selectedNode else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(node.name)”",
            prompt: "Restore"
        ) else { return }
        model.restore(
            repositoryID: target.repositoryID,
            snapshotID: target.snapshot.id,
            node: node,
            to: destination
        )
    }

    private func restoreWholeSnapshot() {
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore the whole snapshot",
            prompt: "Restore"
        ) else { return }
        // A whole-snapshot restore keeps the original absolute layout, so it goes
        // through the dedicated call rather than the per-node one.
        model.restoreWholeSnapshot(
            repositoryID: target.repositoryID,
            snapshotID: target.snapshot.id,
            to: destination
        )
    }
}

extension SnapshotNode {
    /// Synthesises a directory node for a path restic never handed us as JSON —
    /// used for the snapshot's own root paths at the top of the browser.
    static func directory(path: String) -> SnapshotNode {
        let name = (path as NSString).lastPathComponent
        return SnapshotNode(name: name.isEmpty ? path : name, type: .dir, path: path)
    }
}
