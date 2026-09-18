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
    /// The version the listing below (or the fetch in flight for it) belongs
    /// to. `load()` records the version it is about to publish, so its own
    /// picker handoff is never mistaken for a user flip; `fetchNodes` records
    /// the version it fetches, so two racing fetches cannot both write.
    @State private var listingVersionID: String?

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
        // The reload key is the folder alone. Keying on the version as well
        // made `load`'s own walk-down handoff — publishing the version it had
        // just decided on — cancel the very fetch it had started and re-run
        // the whole load: a duplicated index query and one restic `ls`
        // spawned and thrown away, on every step into a folder whose
        // preserved version did not cover it. The picker's own flips are
        // handled by the `onChange` below instead.
        .task(id: currentPath) { await load() }
        .onChange(of: chosen?.id) { _, newID in
            guard let newID, let path = currentPath else { return }
            // Recorded synchronously, before the fetch task can even start:
            // two flips delivered in the same update lot must each count, or
            // the second one reads as this view's own handoff and is
            // swallowed — leaving the first fetch to lose its race with a
            // spinner it can never clear.
            guard newID != listingVersionID else { return }
            listingVersionID = newID
            Task { await fetchNodes(versionID: newID, path: path) }
        }
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
                if let currentPath {
                    // Jump between levels without walking Back through each.
                    PathBreadcrumb(path: currentPath, roots: planSnapshots.first?.paths ?? []) { target in
                        self.currentPath = target
                        selection = nil
                    }
                } else {
                    Text("Backed-up folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            versionPicker
        }
        .padding(12)
    }

    @ViewBuilder
    private var versionPicker: some View {
        if currentPath != nil {
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
                    showingSnapshotBrowser = snapshotBrowserTarget
                }
                .disabled(snapshotBrowserTarget == nil)
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
            Text("Every snapshot in this repository is indexed — the version lists above are complete.")
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

    /// The snapshot-first escape hatch, opened at the version the user is
    /// reading — not discarded to the newest.
    private var snapshotBrowserTarget: SnapshotBrowserTarget? {
        let snapshot = planSnapshots.first { $0.id == chosen?.id } ?? planSnapshots.first
        return snapshot.map {
            SnapshotBrowserTarget(repositoryID: target.repositoryID, snapshot: $0)
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

        // Every await is followed by a cancellation guard before any state
        // write. A newer level owns the view the moment it is opened; a stale
        // load that wrote `versions` or `chosen` after losing would clobber
        // the newer folder's list.
        let complete = await model.indexIsComplete(repositoryID: target.repositoryID)
        guard !Task.isCancelled else { return }
        indexComplete = complete

        guard let currentPath else {
            // Pseudo-root: the plan's backed-up folder roots, presented as
            // directory entries. No single path, so no version list applies.
            let rootVersion = planSnapshots.first.map(snapshotVersion(from:))
            listingVersionID = rootVersion?.id
            nodes = planSnapshots.first?.paths.map(SnapshotNode.directory) ?? []
            versions = []
            chosen = rootVersion
            isLoading = false
            return
        }

        isLoading = true
        let loadedVersions = await model.indexedVersions(ofPath: currentPath, repositoryID: target.repositoryID)
            .filter { $0.chain == chain }
        // Keeping the user's version across a walk down matters — flip
        // through time, then step inside, and you are still in the same
        // era. When it does not cover the deeper path, the newest wins.
        let nextChosen = loadedVersions.preferredVersion(previousID: chosen?.id) ?? fallbackVersion
        guard !Task.isCancelled else { return }
        // Recorded before `chosen` moves: the picker handoff must read as
        // this load's own doing, not as a flip asking for a refetch.
        listingVersionID = nextChosen?.id
        versions = loadedVersions
        chosen = nextChosen

        // Both routes to a version come up empty only when the plan has
        // no snapshots at all — then there is nothing to list from.
        guard let nextChosen else {
            nodes = []
            isLoading = false
            return
        }

        await fetchNodes(versionID: nextChosen.id, path: currentPath)
    }

    /// The one writer of `nodes`: the folder load and an idle picker flip
    /// both land here, and every write is guarded on still owning the view —
    /// a slower older fetch (a flip during a load, a walk away mid-fetch)
    /// must not overwrite the version or the folder the user is reading now.
    /// The caller records `listingVersionID` before starting this; the fetch
    /// itself never does, so the field always names the newest ask.
    private func fetchNodes(versionID: String, path: String) async {
        isLoading = true
        loadError = nil
        do {
            let loaded = try await model.children(
                repositoryID: target.repositoryID,
                snapshotID: versionID,
                path: path
            )
            guard currentPath == path, chosen?.id == versionID else {
                clearLoadingIfSuperseded(versionID: versionID, path: path)
                return
            }
            nodes = loaded
            loadError = nil
            isLoading = false
        } catch {
            guard currentPath == path, chosen?.id == versionID else {
                clearLoadingIfSuperseded(versionID: versionID, path: path)
                return
            }
            nodes = []
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    /// A fetch that lost the view to a newer pick or a walk must not write —
    /// but if no newer fetch has taken over, it is also the one that started
    /// the spinner, so it stops it. With the synchronous handoff in
    /// `onChange` the newest fetch always clears the flag itself; this is the
    /// belt to that brace.
    private func clearLoadingIfSuperseded(versionID: String, path: String) {
        if listingVersionID == versionID, currentPath == path {
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
