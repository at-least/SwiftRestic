import SwiftUI

/// The pane for a folder or file picked in a Files tab's tree: what it is
/// and where it lives — and when it was last backed up, once the newest
/// backup has dropped it or this Mac no longer holds it — then the item by
/// version — a folder as any backup holding it held it
/// (`FolderVersionsView`), a file as each content it had
/// (`FileVersionsView`) — or, for an item on this Mac no backup holds, that
/// it is not backed up.
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
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
    @State private var loadError: String?
    @State private var indexComplete = true
    /// Whether this Mac holds the item now, by one `lstat`; nil until read.
    @State private var isOnDisk: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                FilesPaneHeader(
                    node: node,
                    newestHolder: versions.first,
                    chainNewest: chainNewest,
                    notRead: notRead,
                    isOnDisk: isOnDisk
                )
                if !indexComplete {
                    Label(FilesSearchAnswer.indexStillReading, systemImage: "clock.arrow.circlepath")
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
        // Read under each listing and each turn of the disk, and again
        // every `recheckInterval` while the index is still reading the
        // repository — the tree's own rule, so the pane fills in as the
        // tree does.
        .task(id: FilesPaneLoadKey(
            node: node,
            listedAt: model.snapshotsLoadedAt(for: node.repositoryID),
            indexTaken: model.indexTakenGeneration[node.repositoryID],
            diskGeneration: filesTree.diskGeneration
        )) {
            while !Task.isCancelled {
                let path = node.path
                isOnDisk = await Task.detached(priority: .userInitiated) { DiskFolder.exists(path) }.value
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

    /// Why the chain's newest backup lacks the item, when that backup's own
    /// run could not read it (`UnreadItems.reason`).
    private var notRead: String? {
        chainNewest.flatMap { model.unreadItems(inBackup: $0.id).reason(for: node.path) }
    }

    /// An item on this Mac no backup of the plan holds, by the index once it
    /// has read every backup — the tree's `notBackedUp`.
    private var isNotBackedUp: Bool {
        isOnDisk == true && indexComplete && (node.isDirectory ? versions.isEmpty : contentVersions.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView {
                Label("Could not read its backups", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError).textSelection(.enabled)
            }
        } else if !didOpen {
            // The first read only: a re-read while the index has not
            // reached the item yet keeps the empty state up rather than
            // swapping it for this every recheck.
            ProgressView("Reading…")
        } else if isNotBackedUp {
            ContentUnavailableView(
                "Not backed up",
                systemImage: "clock.arrow.circlepath",
                description: Text(verbatim: FilesTree.Entry.notBackedUpReason(notRead: notRead))
            )
        } else if node.isDirectory {
            FolderVersionsView(node: node, versions: versions, chosenID: choice, onOpen: onOpen)
        } else {
            FileVersionsView(
                node: node, versions: contentVersions, chosenID: choice,
                diskPath: DiskFile.localPath(
                    of: node.path, newestBackup: chainNewest, localHostname: model.localHostname
                )
            )
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
    }
}

/// What the pane's load is keyed by: the item, the listing it is read
/// under, the listing the index has taken and the disk's turn — so a
/// refresh reads it again, and so does the index taking that refresh's
/// listing a moment later, and the disk maybe changing.
private struct FilesPaneLoadKey: Equatable {
    let node: FileNode
    let listedAt: Date?
    let indexTaken: UInt64?
    let diskGeneration: UInt64
}

/// The pane's identity block: the kind's icon, the name, the whole path —
/// selectable, the one exact identifier — and, for a folder no longer on
/// this Mac or an item the chain's newest backup no longer holds, when it
/// was last backed up: the one fact of its standing the rows below do not
/// already say. How many backups and versions hold it are the rows
/// themselves; a file's own line says whether this Mac has it.
struct FilesPaneHeader: View {
    let node: FileNode
    /// The newest backup holding it.
    let newestHolder: IndexVersion?
    let chainNewest: Snapshot?
    /// Why the chain's newest backup lacks it, when that backup's own run
    /// could not read it (`UnreadItems.reason`).
    let notRead: String?
    /// Whether this Mac holds it now; nil until read.
    let isOnDisk: Bool?

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

    /// For a folder this Mac no longer holds, when it was last backed up —
    /// a deleted row's tooltip, in the same words; a file's line over its
    /// versions says "Not on this Mac" already. For an item the chain's
    /// newest backup lacks, when it was last backed up and, when that
    /// backup could not read it, why.
    private var standing: String? {
        if node.isDirectory, isOnDisk == false, let newestHolder {
            return FilesTree.Entry.deleted(lastBackedUp: newestHolder.time)
        }
        guard let newestHolder, let chainNewest, newestHolder.id != chainNewest.id else { return nil }
        return FilesTree.Entry.standing(notRead: notRead, lastBackedUp: newestHolder.time)
    }
}
