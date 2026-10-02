import SwiftUI

struct FolderBrowserTarget: Identifiable {
    var repositoryID: UUID
    var planID: UUID
    var id: String { "\(repositoryID.uuidString)-\(planID.uuidString)" }
}

/// Browses by folder first, version second — the Arq/Time Machine order.
///
/// The snapshot-first browser — the Restore pane — answers "what is inside
/// this snapshot"; this answers "when did this folder look different". Each
/// level is listed from one snapshot, and the version picker above the list
/// flips that snapshot without losing the folder — the index answers which
/// versions cover the path, restic lists the level. Walking down re-derives
/// the version list for the deeper path, keeping the user's chosen snapshot
/// when it still covers it.
///
/// The index is a cache with a backfill: until it finishes, a version list
/// may be missing older entries. The browser degrades instead of lying —
/// it lists from the plan's newest snapshot and says so in the footnote.
struct FolderBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let target: FolderBrowserTarget
    /// Hands the version and folder being read to the Restore pane. The
    /// host routes; this sheet only closes first.
    let onShowInRestore: (_ snapshotID: String, _ folder: String?) -> Void

    /// `nil` = the pseudo-root that lists the plan's backed-up folder roots.
    @State private var currentPath: String?
    /// The versions the index knows for `currentPath`, newest first.
    @State private var versions: [IndexVersion] = []
    /// The snapshot the list below is read from.
    @State private var chosen: IndexVersion?
    @State private var nodes: [SnapshotNode] = []
    @State private var selection: SnapshotNode.ID?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var indexComplete = false
    /// The version the listing below (or the fetch in flight for it) belongs
    /// to. `load()` records the version it is about to publish, so its own
    /// picker handoff is never mistaken for a user flip; `fetchNodes` records
    /// the version it fetches, so two racing fetches cannot both write.
    @State private var listingVersionID: String?
    /// The restore waiting in the destination sheet, over this one.
    @State private var destinationRequest: RestoreDestinationRequest?

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
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
        // The reload key is the folder alone. Keying on the version as well
        // made `load`'s own walk-down handoff — publishing the version it had
        // just decided on — cancel the very fetch it had started and re-run
        // the whole load: a duplicated index query and one restic `ls`
        // spawned and thrown away, on every step into a folder whose
        // preserved version did not cover it. The picker's own flips are
        // handled by the task below instead.
        .task(id: currentPath) { await load() }
        // A picker flip re-lists from the chosen version. Keyed on the
        // version so the modifier owns the fetch's cancellation: a later flip
        // or the sheet closing stops the previous fetch and its restic child
        // instead of orphaning them after dismissal. The synchronous
        // `listingVersionID` handoff still separates `load`'s own walk-down
        // (recorded before `chosen` moves) from a user's flip.
        .task(id: chosen?.id) {
            guard let newID = chosen?.id, let path = currentPath else { return }
            guard newID != listingVersionID else { return }
            listingVersionID = newID
            await fetchNodes(versionID: newID, path: path)
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
            // No gesture on the row: a SwiftUI gesture on a List row claims
            // every click inside what it covers, so a click on a name or
            // icon never selected the row — and with the old contentShape a
            // click anywhere on it, leaving Restore Selected… disabled
            // (measured with HID-level clicks on macOS 26). Double-click is
            // the list's own primary action, as in the Restore pane.
            List(nodes, selection: $selection) { node in
                SnapshotNodeRow(node: node)
                    .tag(node.id)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: SnapshotNode.ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first,
                      let node = nodes.first(where: { $0.id == id })
                else { return }
                open(node)
            }
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .help("Return opens a folder; ⌘↑ or ⌫ goes up; double-click also opens")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            RestoreProgressStrip()

            statusLine

            HStack {
                Button("Show in Restore") {
                    guard let record = restoreRecord else { return }
                    // Read before the sheet goes: the pane opens this folder.
                    let folder = currentPath
                    dismiss()
                    onShowInRestore(record.id, folder)
                }
                .disabled(restoreRecord == nil)
                .help("Open this version in the Restore pane at this folder — drag to Finder, see what changed, or restore the whole backup")
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
                "The version index is still reading this repository — some older versions may be missing. Show in Restore always shows a complete tree.",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The snapshot-first escape hatch, opened at the version the user is
    /// reading — not discarded to the newest.
    private var restoreRecord: Snapshot? {
        planSnapshots.first { $0.id == chosen?.id } ?? planSnapshots.first
    }

    // MARK: - Actions

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        // Return on a file is Restore Selected…, under the button's own
        // gate: left unhandled, the list hands Return to its double-click
        // action and the default button never sees it (the Restore pane
        // measured this on a probe).
        if press.key == .return,
           press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
           let node = selectedNode, !node.isDirectory {
            guard !model.isRestoring, chosen != nil else { return .ignored }
            restoreSelection()
            return .handled
        }
        return BrowserListGrammar.keyPress(
            press,
            selected: selectedNode,
            hasParent: currentPath != nil,
            open: { open($0) },
            goUp: { goUp() }
        )
    }

    private var selectedNode: SnapshotNode? {
        guard let selection else { return nil }
        return nodes.first { $0.id == selection }
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
            self.currentPath = BrowserListGrammar.parent(of: currentPath)
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
        let loadedVersions = await model.indexedVersions(
            ofPath: currentPath, inChain: chain, repositoryID: target.repositoryID
        )
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
    private var fallbackVersion: IndexVersion? {
        planSnapshots.first.map(self.snapshotVersion)
    }

    private func snapshotVersion(from snapshot: Snapshot) -> IndexVersion {
        IndexVersion(id: snapshot.id, time: snapshot.time)
    }

    private func restoreSelection() {
        guard let node = selectedNode, let chosen else { return }
        let repositoryID = target.repositoryID
        destinationRequest = RestoreDestinationRequest(
            subject: .item(name: node.name, path: node.path, isDirectory: node.isDirectory),
            backupTime: chosen.time,
            snapshotShortID: String(chosen.id.prefix(8))
        ) { directories, overwrite in
            model.restore(
                repositoryID: repositoryID,
                snapshotID: chosen.id,
                node: node,
                to: directories[0],
                overwrite: overwrite
            )
        }
    }
}
