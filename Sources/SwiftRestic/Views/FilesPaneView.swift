import SwiftUI
import UniformTypeIdentifiers

/// The pane under a Backups tab's tree for the file picked in the tree: its
/// header (`FilesPaneHeader`), then its versions (`FileVersionsView`) or,
/// for a file on this Mac no backup holds, that it is not backed up.
struct FilesPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(DiskWatch.self) private var diskWatch
    let node: FileNode
    let chosenVersion: ChosenVersionRestore

    /// The file's contents through the chain's backups, newest first.
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
                    newestHolder: contentVersions.first?.snapshots.first,
                    chainNewest: chainNewest,
                    notRead: notRead,
                    isOnDisk: isOnDisk,
                    diskLine: diskLine
                )
                if !indexComplete {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(IndexWords.stillReading)
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
            diskGeneration: diskWatch.diskGeneration
        )) {
            while !Task.isCancelled {
                let path = node.path
                isOnDisk = await Task.detached(priority: .userInitiated) { DiskFolder.exists(path) }.value
                await load()
                guard !indexComplete else { return }
                do {
                    try await Task.sleep(for: DiskWatch.recheckInterval)
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

    /// A file on this Mac no backup of the plan holds, by the index once it
    /// has read every backup.
    private var isNotBackedUp: Bool {
        isOnDisk == true && indexComplete && contentVersions.isEmpty
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
                description: Text(verbatim: FileStandingWords.notBackedUpReason(notRead: notRead) + ".")
            )
        } else {
            FileVersionsView(
                node: node, versions: contentVersions, chosenID: choice, chosenVersion: chosenVersion,
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
            let contents = try await model.indexedContentVersions(
                ofPath: node.path, inChain: node.chainKey, repositoryID: node.repositoryID
            )
            guard !Task.isCancelled else { return }
            contentVersions = contents
            loadError = nil
            // Where the pane opens, settled on the first read: the version
            // the file was left at, or the backup it was picked in. The newest as
            // nothing: an open pane follows a newer backup.
            if !didOpen {
                didOpen = true
                let opening = contents.version(holding: router.filesChosenVersion[node])?.id
                chosenID = opening == contents.first?.id ? nil : opening
            }
        } catch {
            guard !Task.isCancelled else { return }
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

/// The pane's subtitle: the file's path and, for a file the chain's newest
/// backup no longer holds, when it was last backed up — the one fact of its
/// standing the rows below do not already say — and its copy on this Mac
/// beside its versions. Its icon and name are the tree's selected row
/// above. How many backups and versions hold it are the rows themselves.
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
            VStack(alignment: .leading, spacing: 3) {
                // The file's own path, not its parent's: the name says which
                // file of the folder it is. A link only while this Mac holds
                // it.
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

    /// Nil for a file the chain's newest backup holds: its rows and disk
    /// line say it already.
    private var standing: String? {
        guard let newestHolder, let chainNewest, newestHolder.id != chainNewest.id else { return nil }
        return FileStandingWords.standing(notRead: notRead, lastBackedUp: newestHolder.time)
    }
}
