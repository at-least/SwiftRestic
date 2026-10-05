import SwiftUI

/// A file of the Files view, by version: each content it had through its
/// chain's history, newest first — the backups that held it unchanged
/// (`ContentVersion`, from the index) — with when it was modified and how
/// big it was, from one `restic find` of its path in each version's newest
/// backup. Pick one to restore it or open it in its backup; drag one to
/// Finder.
struct FileVersionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode
    /// Newest first.
    let versions: [ContentVersion]
    /// The chosen version, by its newest backup's ID.
    @Binding var chosenID: String?
    /// Where the file is on this Mac, when the chain backs up this Mac's
    /// folders by their own paths (`DiskFile.localPath`); nil says nothing
    /// of the disk.
    let diskPath: String?

    /// Each version's newest backup's node of the file — size and
    /// modification time — by backup ID; empty until the answer lands.
    @State private var details: [String: SnapshotNode] = [:]
    @State private var detailsError: String?
    /// True from the start: the find begins as the pane opens, and the
    /// first frame must not read as one that has finished — the disk line
    /// would say "matches none" a moment before it matches.
    @State private var isReadingDetails = true
    @State private var destinationRequest: RestoreDestinationRequest?
    /// The file as this Mac holds it now, read with the versions' details.
    @State private var disk: DiskFile?
    @FocusState private var listIsFocused: Bool

    private var chosen: ContentVersion? {
        versions.first { $0.id == chosenID } ?? versions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let diskLine {
                Label(diskLine, systemImage: "laptopcomputer")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .help(diskPath ?? "")
                Divider()
            }
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // One find per file shown, again when the versions change under a
        // newer listing or a re-read of the index.
        .task(id: versions.map(\.id)) { await readDetails() }
        // A restore can put a version back where it came from: the disk is
        // read again once it ends, as when the pane opens.
        .task(id: diskPath) { disk = diskPath.map(DiskFile.at) }
        .onChange(of: model.isRestoring) { disk = diskPath.map(DiskFile.at) }
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
    }

    @ViewBuilder
    private var list: some View {
        if versions.isEmpty {
            // Why is the pane's banner's to say, while the index reads.
            ContentUnavailableView("No backup holds it yet", systemImage: "clock.arrow.circlepath")
        } else {
            List(versions, selection: Binding(get: { chosen?.id }, set: { chosenID = $0 })) { version in
                FileVersionRow(
                    version: version,
                    detail: detail(of: version),
                    olderDetail: older(than: version).flatMap(detail(of:)),
                    isReadingDetail: isReadingDetails
                )
                // The list's own drag, no gesture on the row (the Restore
                // pane's measured rule).
                .itemProvider { dragProvider(for: version) }
            }
            .listStyle(.inset)
            .focusOnClick($listIsFocused)
            .contextMenu(forSelectionType: String.self) { _ in
                EmptyView()
            } primaryAction: { _ in
                restoreChosen()
            }
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control, .shift]),
                      chosen != nil, !model.isRestoring
                else { return .ignored }
                restoreChosen()
                return .handled
            }
            .help("Return or double-click restores the chosen version; drag a version to Finder to restore it there")
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            RestoreProgressStrip()
            HStack {
                if let detailsError {
                    Label("Sizes and dates could not be read", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(detailsError)
                }
                Spacer()
                Button("Show in Backups") {
                    guard let backup = chosen?.snapshots.first else { return }
                    router.showRestore(
                        repositoryID: node.repositoryID,
                        snapshotID: backup.id,
                        focusPath: ResticPath.parent(of: node.path)
                    )
                }
                .disabled(chosen == nil)
                .help("Open the chosen version's newest backup at this file's folder, in the sidebar's list of backups")
                Button("Restore…") { restoreChosen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || model.isRestoring)
                    .help("Restore the chosen version of this file (Return)")
            }
        }
        .padding(12)
    }

    /// What the pane says of the copy on this Mac, against the versions'
    /// sizes and dates once the find has read them.
    private var diskLine: String? {
        disk?.line(
            versions: versions.map { version in (detail(of: version)?.size, detail(of: version)?.mtime) },
            isReading: isReadingDetails
        )
    }

    /// A version's newest backup's node of the file, once the find has
    /// answered.
    private func detail(of version: ContentVersion) -> SnapshotNode? {
        version.snapshots.first.flatMap { details[$0.id] }
    }

    /// The version below `version` in the list — the one it follows.
    private func older(than version: ContentVersion) -> ContentVersion? {
        guard let index = versions.firstIndex(where: { $0.id == version.id }), index + 1 < versions.count else {
            return nil
        }
        return versions[index + 1]
    }

    /// The file as the chosen version's newest backup holds it: the find's
    /// node when it has answered, else the bare path, which restores the
    /// same bytes.
    private func restorable(_ version: ContentVersion) -> (backup: IndexVersion, node: SnapshotNode)? {
        guard let backup = version.snapshots.first else { return nil }
        let node = details[backup.id] ?? SnapshotNode(name: self.node.name, type: .file, path: self.node.path)
        return (backup, node)
    }

    private func dragProvider(for version: ContentVersion) -> NSItemProvider? {
        guard let (backup, file) = restorable(version),
              model.repository(id: node.repositoryID) != nil, model.isResticAvailable
        else { return nil }
        return model.dragRestoreProvider(repositoryID: node.repositoryID, snapshotID: backup.id, node: file)
    }

    private func restoreChosen() {
        guard let chosen, let (backup, file) = restorable(chosen) else { return }
        let repositoryID = node.repositoryID
        destinationRequest = RestoreDestinationRequest(
            subject: .item(name: file.name, path: file.path, isDirectory: false),
            backupTime: backup.time,
            snapshotShortID: String(backup.id.prefix(8))
        ) { directories, overwrite in
            model.restore(repositoryID: repositoryID, snapshotID: backup.id, node: file, to: directories[0], overwrite: overwrite)
        }
    }

    private func readDetails() async {
        guard !versions.isEmpty else { return }
        isReadingDetails = true
        do {
            let found = try await model.fileHistory(
                repositoryID: node.repositoryID,
                path: node.path,
                backupIDs: versions.compactMap { $0.snapshots.first?.id }
            )
            guard !Task.isCancelled else { return }
            details = found
            detailsError = nil
        } catch {
            guard !Task.isCancelled else { return }
            detailsError = error.localizedDescription
        }
        isReadingDetails = false
    }
}

/// One version: when the file was modified then — what picks Tuesday's
/// copy — how big it was and how that moved from the version below, and,
/// for a content several backups held, which backups.
private struct FileVersionRow: View {
    let version: ContentVersion
    /// The newest backup's node of the file, once the find has answered.
    let detail: SnapshotNode?
    /// The same for the version below, which the size change counts from.
    let olderDetail: SnapshotNode?
    let isReadingDetail: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(modified)
                    .foregroundStyle(detail?.mtime == nil ? .secondary : .primary)
                    .accessibilityLabel(detail?.mtime == nil ? missing("Modified date") : modified)
                if let heldBy {
                    Text(heldBy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let changeText {
                Text(changeText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(changeHelp)
            }
            Text(size)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
                .accessibilityLabel(detail == nil ? missing("Size") : size)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Filled in quietly while the find runs, as the size column is — the
    /// backups and the change mark beside it are the index's, already
    /// shown — never a "Reading…" that every click put on every row.
    private var modified: String {
        if let mtime = detail?.mtime { return "Modified \(Format.timestamp(mtime))" }
        return isReadingDetail ? "Modified …" : "Modified —"
    }

    private var size: String {
        detail.map { Format.bytes($0.size) } ?? (isReadingDetail ? "…" : "—")
    }

    /// What VoiceOver says for a value not in hand, which the row shows as
    /// "…" or "—": one glyph apart, they say nothing of which.
    private func missing(_ value: String) -> String {
        isReadingDetail ? "\(value) still being read" : "\(value) not known"
    }

    /// "In 4 backups · Oct 2 – Oct 4, 2026" for a content several backups
    /// held — the span "Tuesday's version" may sit in; nil for one backup's,
    /// whose moment the restore sheet names.
    private var heldBy: String? {
        guard version.snapshots.count > 1, let newest = version.snapshots.first, let oldest = version.snapshots.last
        else { return nil }
        let span = Format.historySpan(oldest: oldest.time, newest: newest.time)
        return "In \(Format.plural(version.snapshots.count, "backup")) · \(span)"
    }

    private var change: FileVersionChange {
        .between(since: version.since, newerSize: detail?.size, olderSize: olderDetail?.size, isReading: isReadingDetail)
    }

    private var changeText: String? {
        switch change {
        case .none: nil
        case let .size(text): text
        case .mayBeIdentical: "May be identical"
        }
    }

    /// How the index came to cut here — the provenance the row no longer
    /// spells.
    private var changeHelp: String {
        if version.since == .changed { return "restic's diff of this backup with the one before said the file changed" }
        let uncompared = "No diff compared this backup with the one before, or the file was absent in between"
        return change == .mayBeIdentical ? "\(uncompared): its content may be the same" : "\(uncompared); the sizes differ"
    }
}
