import SwiftUI

/// The pane for a folder or file picked in the Files view: what it is, where
/// it lives, and the backups that hold it — newest first, from the index —
/// with Show in Backups for the one selected, which opens that backup at
/// that place in the Backups view.
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode

    /// The backups of the chain holding the item, newest first.
    @State private var versions: [IndexVersion] = []
    @State private var selectedVersion: String?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var indexComplete = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilesPaneHeader(node: node, versions: versions, chainNewest: chainNewest, isLoading: isLoading)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            versionList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(node.isRoots ? "Files" : node.name)
        // Read under each listing, and again every `recheckInterval` while
        // the index is still reading the repository — the sidebar's tree
        // rule, so the pane fills in as the tree does.
        .task(id: FilesPaneLoadKey(node: node, listedAt: model.snapshotsLoadedAt(for: node.repositoryID))) {
            while !Task.isCancelled {
                await load()
                guard !indexComplete else { return }
                do {
                    try await Task.sleep(for: FilesTree.recheckInterval)
                } catch {
                    return
                }
            }
        }
    }

    /// The chain's newest backup, from the repository's listing.
    private var chainNewest: Snapshot? {
        model.snapshots(for: node.repositoryID).first { SnapshotIndex.chainKey(for: $0) == node.chainKey }
    }

    @ViewBuilder
    private var versionList: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Could not read its backups", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if isLoading, versions.isEmpty {
            ProgressView("Reading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if versions.isEmpty {
            ContentUnavailableView(
                "No backups hold it yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("The index is still reading this repository's backups.")
            )
        } else {
            List(versions, id: \.id, selection: $selectedVersion) { version in
                HStack {
                    Text(Format.timestamp(version.time))
                    Spacer()
                    Text(version.id.prefix(8))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                .tag(version.id)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                guard ids.count == 1, let id = ids.first, let version = versions.first(where: { $0.id == id }) else { return }
                showInBackups(version)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !indexComplete {
                Label(
                    "The index is still reading this repository — older backups may be missing.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show in Backups") {
                if let version = shownVersion { showInBackups(version) }
            }
            .disabled(shownVersion == nil)
            .help("Open this backup in the Backups view, at this item — drag to Finder, see what changed, or restore the whole backup")
        }
        .padding(12)
    }

    /// The selected backup, or the newest when none is selected.
    private var shownVersion: IndexVersion? {
        versions.first { $0.id == selectedVersion } ?? versions.first
    }

    /// The Backups view at that backup, its tree opened at the item's
    /// folder: the folder itself, or the one holding the file.
    private func showInBackups(_ version: IndexVersion) {
        router.sidebarMode = .backups
        router.showRestore(
            repositoryID: node.repositoryID,
            snapshotID: version.id,
            focusPath: node.isDirectory ? node.path : ResticPath.parent(of: node.path)
        )
    }

    private func load() async {
        isLoading = true
        indexComplete = await model.indexIsComplete(repositoryID: node.repositoryID)
        do {
            let loaded = try await model.indexedHolders(
                ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
            )
            guard !Task.isCancelled else { return }
            versions = loaded
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            versions = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

/// What the pane's load is keyed by: the item, and the listing it is read
/// under, so a refresh reads it again.
private struct FilesPaneLoadKey: Equatable {
    let node: FileNode
    let listedAt: Date?
}

/// The pane's identity block: the kind's icon, the name, the whole path —
/// selectable, the one exact identifier — and one line of where it stands
/// in its chain's history.
struct FilesPaneHeader: View {
    @Environment(\.now) private var now
    let node: FileNode
    /// The backups holding it, newest first.
    let versions: [IndexVersion]
    let chainNewest: Snapshot?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(node.isDirectory ? Theme.tint : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text((node.path as NSString).abbreviatingWithTildeInPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help(node.path)
                if let standing {
                    Text(standing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "In 214 backups · newest 1 hour ago", or, for an item the chain's
    /// newest backup lacks, when it was last backed up.
    private var standing: String? {
        guard let newest = versions.first else { return nil }
        if let chainNewest, newest.id != chainNewest.id {
            return "Not in the newest backup — last backed up \(Format.timestamp(newest.time))"
        }
        return "In \(Format.plural(versions.count, "backup")) · newest \(Format.ago(newest.time, now: now))"
    }
}
