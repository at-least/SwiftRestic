import SwiftUI

/// The pane for a folder or file picked in a Files tab's tree: what it is,
/// where it lives and where it stands in its chain's history, then the item
/// by version — a folder as any backup holding it held it
/// (`FolderVersionsView`), a file as each content it had
/// (`FileVersionsView`).
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode
    /// Opens an item of a folder's listing in the tree, at the backup the
    /// listing was read from.
    let onOpen: (FileNode, _ versionID: String) -> Void

    /// The backups of the chain holding the item, newest first.
    @State private var versions: [IndexVersion] = []
    /// A file's contents through those backups, newest first.
    @State private var contentVersions: [ContentVersion] = []
    /// The backup the item is shown at — for a file, its version's newest —
    /// nil for the newest.
    @State private var chosenID: String?
    /// Whether the first read has settled where the pane opens.
    @State private var didOpen = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var indexComplete = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                FilesPaneHeader(
                    node: node, versions: versions,
                    versionCount: node.isDirectory ? nil : contentVersions.count,
                    chainNewest: chainNewest
                )
                if !indexComplete {
                    Label(
                        "The index is still reading this repository — older backups may be missing.",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Read under each listing, and again every `recheckInterval` while
        // the index is still reading the repository — the tree's own
        // rule, so the pane fills in as the tree does.
        .task(id: FilesPaneLoadKey(
            node: node,
            listedAt: model.snapshotsLoadedAt(for: node.repositoryID),
            indexTaken: model.indexTakenGeneration[node.repositoryID]
        )) {
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
    private var content: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Could not read its backups", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if isLoading, versions.isEmpty {
            ProgressView("Reading…")
        } else if node.isDirectory {
            FolderVersionsView(node: node, versions: versions, chosenID: choice, onOpen: onOpen)
        } else {
            FileVersionsView(node: node, versions: contentVersions, chosenID: choice)
        }
    }

    /// The backup the user picks, remembered for coming back to the item —
    /// the newest as nothing, so a backup made meanwhile is what the pane
    /// opens at then. Only a pick is: where the pane opened is not.
    private var choice: Binding<String?> {
        Binding(get: { chosenID }, set: { id in
            chosenID = id
            let newest = node.isDirectory ? versions.first?.id : contentVersions.first?.id
            router.filesChosenVersion[node] = id == newest ? nil : id
        })
    }

    private func load() async {
        isLoading = true
        indexComplete = await model.indexIsComplete(repositoryID: node.repositoryID)
        do {
            // A file's backups are its versions' together, so one read
            // answers both; a folder has no content versions.
            let contents = node.isDirectory ? [] : try await model.indexedContentVersions(
                ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
            )
            let loaded = node.isDirectory ? try await model.indexedHolders(
                ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
            ) : contents.flatMap(\.snapshots)
            guard !Task.isCancelled else { return }
            versions = loaded
            contentVersions = contents
            loadError = nil
            // Where the pane opens, settled on the first read: the time
            // the user was reading one level up (or Show Versions named),
            // when this item existed then — walking down keeps the era —
            // else the backup this item was last left at.
            let hint = router.takeFilesVersionHint()
            if !didOpen {
                didOpen = true
                let remembered = router.filesChosenVersion[node]
                let opening = node.isDirectory
                    ? loaded.preferredVersion(previousID: hint, rememberedID: remembered)?.id
                    : contents.preferredVersion(previousID: hint, rememberedID: remembered)?.id
                // The newest as nothing: an open pane follows a newer backup.
                let newest = node.isDirectory ? loaded.first?.id : contents.first?.id
                chosenID = opening == newest ? nil : opening
            }
        } catch {
            guard !Task.isCancelled else { return }
            versions = []
            contentVersions = []
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

/// What the pane's load is keyed by: the item, the listing it is read
/// under, and the listing the index has taken — so a refresh reads it again,
/// and so does the index taking that refresh's listing a moment later.
private struct FilesPaneLoadKey: Equatable {
    let node: FileNode
    let listedAt: Date?
    let indexTaken: UInt64?
}

/// The pane's identity block: the kind's icon, the name, the whole path —
/// selectable, the one exact identifier — and one line of where it stands
/// in its chain's history.
struct FilesPaneHeader: View {
    @Environment(\.now) private var now
    let node: FileNode
    /// The backups holding it, newest first.
    let versions: [IndexVersion]
    /// A file's number of content versions; nil for a folder.
    let versionCount: Int?
    let chainNewest: Snapshot?

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

    /// "In 214 backups · newest 1 hour ago" — for a file, "3 versions in
    /// 214 backups" — or, for an item the chain's newest backup lacks, when
    /// it was last backed up.
    private var standing: String? {
        guard let newest = versions.first else { return nil }
        if let chainNewest, newest.id != chainNewest.id {
            return "Not in the newest backup — last backed up \(Format.timestamp(newest.time))"
        }
        let held = Format.plural(versions.count, "backup")
        let span = versionCount.map { "\(Format.plural($0, "version")) in \(held)" } ?? "In \(held)"
        return "\(span) · newest \(Format.ago(newest.time, now: now))"
    }
}
