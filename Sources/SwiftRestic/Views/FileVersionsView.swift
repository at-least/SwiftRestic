import QuickLook
import QuickLookUI
import SwiftUI

/// A file picked on a Backups tab, by version: each content it had through
/// its chain's history, newest first — the backups that held it unchanged
/// (`ContentVersion`, from the index) — with when it was modified and how
/// big it was, from one `restic find` of its path in each version's newest
/// backup. Pick one to restore it, Space to look at it; drag one to Finder.
struct FileVersionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(DiskWatch.self) private var diskWatch
    let node: FileNode
    /// Newest first.
    let versions: [ContentVersion]
    /// The chosen version, by its newest backup's ID.
    @Binding var chosenID: String?
    /// Where the file is on this Mac, when the chain backs up this Mac's
    /// folders by their own paths (`DiskFile.localPath`); nil says nothing
    /// of the disk.
    let diskPath: String?
    /// The pane header's line about the copy on this Mac
    /// (`DiskFile.line`), written here, where the versions' sizes and dates
    /// are read.
    @Binding var diskLine: String?

    /// Each version's newest backup's node of the file — size and
    /// modification time — by backup ID; empty until the answer lands.
    @State private var details: [String: SnapshotNode] = [:]
    @State private var detailsError: String?
    /// True from the start: the find begins as the pane opens, and the
    /// first frame must not read as one that has finished — the disk line
    /// would say "matches none" a moment before it matches.
    @State private var isReadingDetails = true
    @State private var destinationRequest: RestoreDestinationRequest?
    @State private var disk: DiskFile?
    @State private var previewer = PreviewSession()
    @FocusState private var listIsFocused: Bool

    private var chosen: ContentVersion? {
        versions.chosen(chosenID)
    }

    var body: some View {
        VStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .restoreCommand(restore)
        .onChange(of: diskLineText, initial: true) { _, line in diskLine = line }
        .onDisappear { diskLine = nil }
        // One find per file shown, again when the versions change under a
        // newer listing or a re-read of the index.
        .task(id: versions.map(\.id)) { await readDetails() }
        // A restore can put a version back where it came from: the disk is
        // read again once it ends, as when the pane opens — and whenever
        // the tree reads the disk again (`DiskWatch.diskMayHaveChanged`).
        // Off the main actor, as the tree's and the pane's own reads are: a
        // stalled share holds the read for as long as it stalls, and every
        // activation and mount is a disk turn.
        .task(id: DiskReadKey(path: diskPath, isRestoring: model.isRestoring, diskGeneration: diskWatch.diskGeneration)) {
            guard let path = diskPath else {
                disk = nil
                return
            }
            let read = await Task.detached(priority: .userInitiated) { DiskFile.at(path) }.value
            guard !Task.isCancelled else { return }
            disk = read
        }
        .restoreFlow($destinationRequest)
        // The copy is user data in a temporary folder: it goes when the
        // preview closes, when another version is chosen — a preview must
        // show the version the list says — and when the pane goes.
        .previewSession(previewer)
        // The chosen version's id, not the binding's: with none picked the
        // newest is chosen, and a new backup can change which that is.
        .onChange(of: chosen?.id) { previewer.end() }
    }

    /// What the disk read is keyed by: the path, whether a restore is
    /// running — its start and its end each read again — and the disk's
    /// turn.
    private struct DiskReadKey: Equatable {
        let path: String?
        let isRestoring: Bool
        let diskGeneration: UInt64
    }

    private func versionRow(_ version: ContentVersion) -> some View {
        FileVersionRow(
            version: version,
            detail: detail(of: version),
            olderDetail: versions.after(version).flatMap(detail(of:)),
            isReadingDetail: isReadingDetails
        )
        // The list's own drag, no gesture on the row (the Restore pane's
        // rule).
        .itemProvider { dragProvider(for: version) }
    }

    @ViewBuilder
    private var list: some View {
        if versions.isEmpty {
            // The empty state says why, while the index reads.
            NoBackupHoldsItYet()
        } else {
            List(selection: Binding(get: { chosen?.id }, set: { chosenID = $0 })) {
                // A history past one month is grouped by month, as the
                // folder pane's picker and the Backups tab's list are, so a year
                // of hourly versions is not one flat scroll. Each version
                // falls under the month of the first backup that held it —
                // the backup after its change, so the month its modified
                // date sits in, give or take one backup's interval; its
                // newest backup could be months later for a file left alone.
                if let months = DiffCandidateGrouping.landmarks(in: versions, time: \.snapshots.last!.time) {
                    ForEach(months, id: \.label) { month in
                        Section(month.label) {
                            ForEach(month.items) { versionRow($0) }
                        }
                    }
                } else {
                    ForEach(versions) { versionRow($0) }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier(AccessibilityID.FileVersions.list)
            .focusOnClick($listIsFocused)
            // The clicked row's, which a right-click does not select.
            .contextMenu(forSelectionType: String.self) { ids in
                if let version = versions.first(where: { ids.contains($0.id) }) {
                    Button("Restore") { restoreVersion(version) }
                        .disabled(model.isRestoring)
                    Button("Restore To…") { restoreVersion(version, choosingDestination: true) }
                        .disabled(model.isRestoring)
                    Button("Preview") { preview(version) }
                        .disabled(previewBlock(for: version) != nil || previewer.isCopying)
                }
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
            .onKeyPress(.space, phases: .down) { press in
                previewer.space(press, start: chosen.flatMap { version in
                    previewBlock(for: version) == nil ? { preview(version) } : nil
                })
            }
            .help("Drag a version to Finder to restore it there")
        }
    }

    /// The pane's foot: the reads' errors at the left, and at the right the
    /// chosen version's ways out. Preview is Space and the row's menu, as
    /// Quick Look is in Finder.
    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                if let detailsError {
                    WarningLine(text: "Sizes and dates couldn’t be read")
                        .font(.caption)
                        .help(detailsError)
                }
                if let failure = previewer.failure {
                    WarningLine(text: failure.title)
                        .font(.caption)
                        .help(failure.message)
                }
                Spacer()
                if previewer.isCopying {
                    ProgressView()
                        .controlSize(.small)
                        .help("Copying the chosen version for the preview")
                }
                Button("Restore To…") { chosen.map { restoreVersion($0, choosingDestination: true) } }
                    .accessibilityIdentifier(AccessibilityID.FileVersions.restoreTo)
                    .disabled(chosen == nil || model.isRestoring)
                    .help("Restore the chosen version to a folder you choose")
                Button("Restore") { restoreChosen() }
                    .accessibilityIdentifier(AccessibilityID.FileVersions.restore)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || model.isRestoring)
                    .help("Put the chosen version back where the file was (Return)")
            }
        }
        .padding(12)
    }

    /// What the pane restores, for File ▸ Restore: the chosen version —
    /// the bottom bar's button's restore. Return is the list's own.
    private var restore: RestoreCommand {
        RestoreCommand(
            isEnabled: chosen != nil && !model.isRestoring,
            run: restoreChosen
        )
    }

    private var diskLineText: String? {
        disk?.line(
            versions: versions.map { version in (detail(of: version)?.size, detail(of: version)?.mtime) },
            isReading: isReadingDetails
        )
    }

    private func detail(of version: ContentVersion) -> SnapshotNode? {
        version.snapshots.first.flatMap { details[$0.id] }
    }

    /// The file as the chosen version's newest backup holds it: the find's
    /// node when it has answered, else the bare path as a file — a drag's
    /// guess until then. A drag lands in a fresh folder, where restic's file
    /// route brings a folder through as well: only the promised type can be
    /// wrong. Restore does not guess (`restoreChosen`).
    private func restorable(_ version: ContentVersion) -> (backup: IndexVersion, node: SnapshotNode)? {
        guard let backup = version.snapshots.first else { return nil }
        let node = details[backup.id] ?? SnapshotNode(name: self.node.name, type: .file, path: self.node.path)
        return (backup, node)
    }

    private func dragProvider(for version: ContentVersion) -> NSItemProvider? {
        guard let (backup, file) = restorable(version), model.canDragRestore(repositoryID: node.repositoryID)
        else { return nil }
        return model.dragRestoreProvider(repositoryID: node.repositoryID, snapshotID: backup.id, node: file)
    }

    private func restoreChosen() {
        chosen.map { restoreVersion($0) }
    }

    /// A version, back where the file was or, choosing, through the
    /// destination sheet (`restoreFlow`): the find's node once it has
    /// answered, else the path, its kind in that backup read before it
    /// restores: the versions span every backup holding the path, and one
    /// may hold it as a folder (`RestoreSource.node`).
    private func restoreVersion(_ version: ContentVersion, choosingDestination: Bool = false) {
        guard let backup = version.snapshots.first else { return }
        let found = details[backup.id]
        var request = RestoreDestinationRequest.picked(
            [RestoreSource(
                name: node.name, path: node.path, isDirectory: false,
                snapshotID: backup.id, backupTime: backup.time, node: found
            )],
            repositoryID: node.repositoryID,
            model: model,
            choosingDestination: choosingDestination
        )
        // The row was picked by this time; the sheet says it back.
        request?.versionModified = found?.mtime
        destinationRequest = request
    }

    /// Why a version cannot be previewed, or nil: the repository and restic
    /// first, as the drag's gate, then its size (`VersionPreview`).
    private func previewBlock(for version: ContentVersion) -> String? {
        guard model.repository(id: node.repositoryID) != nil else { return "The backup location no longer exists" }
        if model.isResticDamaged { return ResticError.damagedInstall.localizedDescription }
        return VersionPreview.unavailableReason(size: detail(of: version)?.size, isReading: isReadingDetails)
    }

    /// Copies the version out and hands it to Quick Look. Offered only once
    /// the size is read (`previewBlock`), so the node is the find's.
    private func preview(_ version: ContentVersion) {
        guard let (backup, file) = restorable(version) else { return }
        previewer.start(model, repositoryID: node.repositoryID, snapshotID: backup.id) { file }
    }

    private func readDetails() async {
        guard !versions.isEmpty else {
            // Nothing to ask: the disk line may speak.
            isReadingDetails = false
            return
        }
        isReadingDetails = true
        do {
            let found = try await model.fileHistory(
                repositoryID: node.repositoryID,
                path: node.path,
                snapshotIDs: versions.compactMap { $0.snapshots.first?.id }
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
    let detail: SnapshotNode?
    /// The same for the version below, which the size change counts from.
    let olderDetail: SnapshotNode?
    let isReadingDetail: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(modified)
                    .foregroundStyle(detail?.mtime == nil ? .secondary : .primary)
                    .accessibilityLabel(detail?.mtime == nil ? missing("Modified date") : "Modified \(modified)")
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
    /// shown; never a per-row "Reading…".
    private var modified: String {
        if let mtime = detail?.mtime { return Format.timestamp(mtime) }
        return isReadingDetail ? "…" : "—"
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

    /// How the index came to cut here — the provenance the row's change
    /// text does not spell.
    private var changeHelp: String {
        if version.since == .changed { return "Compared with the previous backup, which found the file changed" }
        let uncompared = "Not compared with the previous backup, or the file was absent in between"
        return change == .mayBeIdentical ? "\(uncompared): its content may be the same" : "\(uncompared); the sizes differ"
    }
}
