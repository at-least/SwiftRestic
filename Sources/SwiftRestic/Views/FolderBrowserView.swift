import SwiftUI

struct FolderBrowserTarget: Identifiable {
    var repositoryID: UUID
    var planID: UUID
    var id: String { "\(repositoryID.uuidString)-\(planID.uuidString)" }
}

/// Browses by folder first, version second — the Arq/Time Machine order.
///
/// The snapshot-first browser answers "what is inside this snapshot"; this
/// answers "when did this folder look different". Each level is listed from
/// one snapshot, and the version picker above the list flips that snapshot
/// without losing the folder — the index answers which versions cover the
/// path, restic lists the level. Walking down re-derives the version list
/// for the deeper path, keeping the user's chosen snapshot when it still
/// covers it.
///
/// The index is a cache with a backfill: until it finishes, a version list
/// may be missing older entries. The browser degrades instead of lying —
/// it lists from the plan's newest snapshot and says so in the footnote.
struct FolderBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: FolderBrowserTarget

    /// `nil` = the pseudo-root that lists the plan's backed-up folder roots.
    @State private var currentPath: String?
    /// The versions the index knows for `currentPath`, newest first.
    @State private var versions: [IndexedSnapshot] = []
    /// The snapshot the list below is read from.
    @State private var chosen: IndexedSnapshot?
    @State private var nodes: [SnapshotNode] = []
    @State private var selection: SnapshotNode.ID?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var indexComplete = false
    @State private var showingSnapshotBrowser: SnapshotBrowserTarget?

    /// Both halves of what decides a (re)load: the folder and the time.
    private struct Level: Equatable {
        var path: String?
        var versionID: String?
    }

    private var level: Level {
        Level(path: currentPath, versionID: chosen?.id)
    }

    /// The plan's snapshots, newest first — the fallback listing source and
    /// the pseudo-root's contents.
    private var planSnapshots: [Snapshot] {
        model.snapshots(for: target.repositoryID, planID: target.planID)
    }

    private var chain: String {
        ResticService.planTag(target.planID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .task(id: level) { await load() }
        .sheet(item: $showingSnapshotBrowser) { snapshotTarget in
            SnapshotBrowserView(target: snapshotTarget)
                .environment(model)
        }
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
                Text("Folders over time")
                    .font(.headline)
                Text(currentPath ?? "Backed-up folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
            Spacer()
            versionPicker
        }
        .padding(12)
    }

    @ViewBuilder
    private var versionPicker: some View {
        if versions.isEmpty {
            Text("versions still being read")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Version", selection: $chosen) {
                ForEach(versions, id: \.id) { version in
                    Text(verbatim: "\(Format.timestamp(version.time))  ·  \(version.id.prefix(8))")
                        .tag(Optional(version))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340)
            .help("Which snapshot this folder is listed from")
        }
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
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .help("Return opens a folder; ⌘↑ or ⌫ goes up; double-click also opens")
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

            statusLine

            HStack {
                Button("Browse One Snapshot…") {
                    if let snapshot = planSnapshots.first {
                        showingSnapshotBrowser = SnapshotBrowserTarget(
                            repositoryID: target.repositoryID,
                            snapshot: snapshot
                        )
                    }
                }
                .disabled(planSnapshots.isEmpty)
                .help("The snapshot-first browser: drag out to Finder, restore the whole snapshot")
                Spacer()
                Button(model.isRestoring ? "Hide" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help(model.isRestoring ? "The restore keeps running" : "Close")
                Button("Restore Selected…") { restoreSelection() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedNode == nil || model.isRestoring || chosen == nil)
                    .help("Restore the selected item as of the chosen version (Return)")
            }
        }
        .padding(12)
    }

    /// What the footnote owes the user: whether the version lists here are
    /// complete, and where the complete tree lives while they are not.
    @ViewBuilder
    private var statusLine: some View {
        if indexComplete {
            Text("Every snapshot of this plan is indexed — the version lists above are complete.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Label(
                "The version index is still reading this repository — some older versions may be missing. Browse One Snapshot always shows a complete tree.",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .return:
            if let node = selectedNode, node.isDirectory {
                open(node)
                return .handled
            }
            return .ignored
        case .delete:
            guard currentPath != nil else { return .ignored }
            goUp()
            return .handled
        case .upArrow where press.modifiers.contains(.command):
            guard currentPath != nil else { return .ignored }
            goUp()
            return .handled
        default:
            return .ignored
        }
    }

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
        // Stop at the plan's own roots rather than walking up to "/".
        let roots = planSnapshots.first?.paths ?? []
        if roots.contains(currentPath) {
            self.currentPath = nil
        } else {
            let parent = (currentPath as NSString).deletingLastPathComponent
            self.currentPath = parent.isEmpty || parent == "/" ? nil : parent
        }
        selection = nil
    }

    private func load() async {
        loadError = nil
        indexComplete = await model.indexIsComplete(repositoryID: target.repositoryID)

        guard let currentPath else {
            // Pseudo-root: the plan's backed-up folder roots, presented as
            // directory entries. No single path, so no version list applies.
            nodes = planSnapshots.first?.paths.map(SnapshotNode.directory) ?? []
            versions = []
            chosen = planSnapshots.first.map(self.snapshotVersion)
            isLoading = false
            return
        }

        isLoading = true
        do {
            versions = await model.indexedVersions(ofPath: currentPath, repositoryID: target.repositoryID)
                .filter { $0.chain == chain }
            // Keeping the user's version across a walk down matters — flip
            // through time, then step inside, and you are still in the same
            // era. When it does not cover the deeper path, the newest wins.
            chosen = versions.preferredVersion(previousID: chosen?.id) ?? fallbackVersion

            guard let chosen else {
                // Nothing covers this path — either the index has not reached
                // it or the folder predates every indexed snapshot. The plan's
                // newest snapshot can still list it.
                if let fallback = fallbackVersion {
                    nodes = try await model.children(
                        repositoryID: target.repositoryID,
                        snapshotID: fallback.id,
                        path: currentPath
                    )
                } else {
                    nodes = []
                }
                guard !Task.isCancelled else { return }
                isLoading = false
                return
            }

            let loaded = try await model.children(
                repositoryID: target.repositoryID,
                snapshotID: chosen.id,
                path: currentPath
            )
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

    /// A stand-in version built from the model's own listing, for when the
    /// index has nothing on this path yet.
    private var fallbackVersion: IndexedSnapshot? {
        planSnapshots.first.map(self.snapshotVersion)
    }

    private func snapshotVersion(from snapshot: Snapshot) -> IndexedSnapshot {
        IndexedSnapshot(
            id: snapshot.id,
            chain: chain,
            seq: 0,
            time: snapshot.time,
            alive: true,
            coverage: .none
        )
    }

    private func restoreSelection() {
        guard let node = selectedNode, let chosen else { return }
        guard let destination = FilePicker.chooseDirectory(
            message: "Choose where to restore “\(node.name)” as of \(Format.timestamp(chosen.time)). Restoring overwrites existing files at the destination.",
            prompt: "Restore"
        ) else { return }
        model.restore(
            repositoryID: target.repositoryID,
            snapshotID: chosen.id,
            node: node,
            to: destination
        )
    }
}
