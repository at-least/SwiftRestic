import SwiftUI
import UniformTypeIdentifiers

/// The pane for a folder or file picked in a Files tab's tree: what it is
/// and where it lives — and when it was last backed up: always for a folder,
/// for a file once the newest backup has dropped it or this Mac no longer
/// holds it — then a file by each
/// content it had (`FileVersionsView`), a folder by its way back
/// (`FolderPaneActions`), or, for an item on this Mac no backup holds, that it
/// is not backed up. A folder at any other moment is the Backups tab's.
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
    let node: FileNode

    /// The backups of the chain holding the item, newest first.
    @State private var versions: [IndexVersion] = []
    /// A file's contents through those backups, newest first.
    @State private var contentVersions: [ContentVersion] = []
    /// The version the file is shown at, by its newest backup; nil for the
    /// newest.
    @State private var chosenID: String?
    @State private var didOpen = false
    @State private var loadError: String?
    @State private var indexComplete = true
    /// Whether this Mac holds the item now, by one `lstat`; nil until read.
    @State private var isOnDisk: Bool?
    /// A file's copy on this Mac beside its versions, from the versions
    /// view (`FileVersionsView.diskLine`).
    @State private var diskLine: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                FilesPaneHeader(
                    node: node,
                    newestHolder: versions.first,
                    chainNewest: chainNewest,
                    notRead: notRead,
                    isOnDisk: isOnDisk,
                    diskLine: diskLine
                )
                if !indexComplete {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(FilesSearchAnswer.indexStillReading)
                    }
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

    private var chainNewest: Snapshot? {
        model.newestSnapshot(inChain: node.chainKey, repositoryID: node.repositoryID)
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
            IndexFailureView(title: "Couldn’t read its backups", message: loadError, repositoryID: node.repositoryID)
        } else if !didOpen {
            // The first read only: a re-read while the index has not
            // reached the item yet keeps the empty state up rather than
            // swapping it for this every recheck.
            ProgressView("Reading…")
        } else if isNotBackedUp {
            ContentUnavailableView(
                "Not backed up",
                systemImage: "clock.arrow.circlepath",
                description: Text(verbatim: FilesTree.Entry.notBackedUpReason(notRead: notRead) + ".")
            )
        } else if node.isDirectory {
            FolderPaneActions(node: node, newest: versions.first)
        } else {
            FileVersionsView(
                node: node, versions: contentVersions, chosenID: choice,
                diskPath: DiskFile.localPath(
                    of: node.path, newestBackup: chainNewest, localHostname: model.localHostname
                ),
                diskLine: $diskLine
            )
        }
    }

    /// The version the user picks, remembered for coming back to the file —
    /// the newest as nothing, so a backup made meanwhile is what the pane
    /// opens at then. Only a pick is: where the pane opened is not.
    private var choice: Binding<String?> {
        Binding(get: { chosenID }, set: { id in
            chosenID = id
            router.filesChosenVersion[node] = id == contentVersions.first?.id ? nil : id
        })
    }

    private func load() async {
        do {
            indexComplete = try await model.indexIsComplete(repositoryID: node.repositoryID)
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
            // Where the pane opens, settled on the first read: the version
            // the file was left at, or Show Versions named. The newest as
            // nothing: an open pane follows a newer backup.
            if !didOpen {
                didOpen = true
                let opening = contents.version(holding: router.filesChosenVersion[node])?.id
                chosenID = opening == contents.first?.id ? nil : opening
            }
        } catch {
            guard !Task.isCancelled else { return }
            versions = []
            contentVersions = []
            loadError = error.localizedDescription
        }
    }
}

/// A folder's way back, by the newest backup holding it — this Mac's copy gone
/// or not: the whole folder's restore, and the backup itself open at the
/// folder, for any other moment or a part of it. When that backup was is the
/// header's line.
private struct FolderPaneActions: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode
    let newest: IndexVersion?

    @State private var destinationRequest: RestoreDestinationRequest?

    var body: some View {
        VStack(spacing: 0) {
            if newest == nil {
                // Saying why is the pane's banner's job, while the index reads.
                NoBackupHoldsItYet()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
            Divider()
            HStack {
                Button("Show in Backups") { showInBackups() }
                    .disabled(newest == nil)
                    .help("Open the newest backup at this folder on the Backups tab")
                Spacer()
                Button("Restore To…") { restoreFolder(choosingDestination: true) }
                    .accessibilityIdentifier(AccessibilityID.FilesPane.restoreTo)
                    .disabled(newest == nil || model.isRestoring)
                    .help("Restore this whole folder as of the newest backup to a folder you choose")
                Button("Restore") { restoreFolder() }
                    .accessibilityIdentifier(AccessibilityID.FilesPane.restore)
                    .buttonStyle(.borderedProminent)
                    .disabled(newest == nil || model.isRestoring)
                    .help("Put this whole folder back as of the newest backup")
            }
            .padding(12)
        }
        .restoreCommand(RestoreCommand(
            isEnabled: newest != nil && !model.isRestoring,
            run: { restoreFolder() }
        ))
        .restoreFlow($destinationRequest)
    }

    private func showInBackups() {
        guard let newest, let page = model.page(ofBackup: newest.id, in: node.repositoryID) else { return }
        router.showBackup(newest.id, on: page, repositoryID: node.repositoryID, focusPath: node.path)
    }

    /// By its path, its kind in that backup read before it restores: the
    /// backup may hold the path as a file (`RestoreSource.node`).
    private func restoreFolder(choosingDestination: Bool = false) {
        guard let newest else { return }
        destinationRequest = RestoreDestinationRequest.picked(
            [RestoreSource(
                name: node.name, path: node.path, isDirectory: true,
                snapshotID: newest.id, backupTime: newest.time, node: nil
            )],
            repositoryID: node.repositoryID,
            model: model,
            choosingDestination: choosingDestination
        )
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

/// The pane's identity block: the kind's icon, the name, its path and, for a
/// folder or an item the chain's newest backup no longer holds, when it was
/// last backed up: the one fact of its standing the rows below do not
/// already say — and, for a file, its copy on this Mac beside its versions.
/// How many backups and versions hold it are the rows themselves.
private struct FilesPaneHeader: View {
    let node: FileNode
    let newestHolder: IndexVersion?
    let chainNewest: Snapshot?
    /// Why the chain's newest backup lacks it, when that backup's own run
    /// could not read it (`UnreadItems.reason`).
    let notRead: String?
    /// Whether this Mac holds it now; nil until read.
    let isOnDisk: Bool?
    /// A file's copy on this Mac beside its versions (`DiskFile.line`).
    let diskLine: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            FileKindIcon(type: .backedUp(name: node.name, isDirectory: node.isDirectory), size: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The item's own path, not its parent's: a plan's root would
                // read as a bare "~". A link only while this Mac holds it.
                let location = (node.path as NSString).abbreviatingWithTildeInPath
                if isOnDisk == true {
                    Button(location) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .help(node.path)
                    .accessibilityLabel("\(location), Show in Finder")
                } else {
                    Text(location)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(node.path)
                }
                if let standing {
                    Text(standing)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let diskLine {
                    Text(diskLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(diskLine)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// For a folder this Mac no longer holds, when it was last backed up —
    /// a deleted row's tooltip, in the same words; a file's disk line says
    /// "Not on this Mac" already. For an item the chain's
    /// newest backup lacks, when it was last backed up and, when that
    /// backup could not read it, why. Any other folder: when it was last
    /// backed up, a file's rows saying that already.
    private var standing: String? {
        guard let newestHolder else { return nil }
        if node.isDirectory, isOnDisk == false {
            return FilesTree.Entry.deleted(lastBackedUp: newestHolder.time)
        }
        if let chainNewest, newestHolder.id != chainNewest.id {
            return FilesTree.Entry.standing(notRead: notRead, lastBackedUp: newestHolder.time)
        }
        return node.isDirectory ? "Last backed up \(Format.timestamp(newestHolder.time))" : nil
    }
}
