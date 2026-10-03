import SwiftUI

/// A file of the Files view, by version: each content it had through its
/// chain's history, newest first — the backups that held it unchanged
/// (`ContentVersion`, from the index) — with when it was modified and how
/// big it was, from one `restic find` of its path. Pick one to restore it or
/// open it in its backup; drag one to Finder.
struct FileVersionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let node: FileNode
    /// Newest first.
    let versions: [ContentVersion]
    /// The chosen version, by its newest backup's ID.
    @Binding var chosenID: String?

    /// Each backup's node of the file — size and modification time — by
    /// backup ID; empty until the find answers.
    @State private var details: [String: FindMatch] = [:]
    @State private var detailsError: String?
    @State private var isReadingDetails = false
    @State private var destinationRequest: RestoreDestinationRequest?
    @FocusState private var listIsFocused: Bool

    private var chosen: ContentVersion? {
        versions.first { $0.id == chosenID } ?? versions.first
    }

    var body: some View {
        VStack(spacing: 0) {
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        // One find per file shown, again when the versions change under a
        // newer listing or a re-read of the index.
        .task(id: versions.map(\.id)) { await readDetails() }
        .sheet(item: $destinationRequest) { request in
            RestoreDestinationSheet(request: request)
                .environment(model)
        }
    }

    @ViewBuilder
    private var list: some View {
        if versions.isEmpty {
            ContentUnavailableView(
                "No backup holds it yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("The index is still reading this repository's backups.")
            )
        } else {
            List(versions, selection: Binding(get: { chosen?.id }, set: { chosenID = $0 })) { version in
                FileVersionRow(
                    version: version,
                    detail: version.snapshots.first.flatMap { details[$0.id] },
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
                    router.sidebarMode = .backups
                    router.showRestore(
                        repositoryID: node.repositoryID,
                        snapshotID: backup.id,
                        focusPath: ResticPath.parent(of: node.path)
                    )
                }
                .disabled(chosen == nil)
                .help("Open the chosen version's newest backup in the Backups view, at this file's folder")
                Button("Restore…") { restoreChosen() }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || model.isRestoring)
                    .help("Restore the chosen version of this file (Return)")
            }
        }
        .padding(12)
    }

    /// The file as the chosen version's newest backup holds it: the find's
    /// node when it has answered, else the bare path, which restores the
    /// same bytes.
    private func restorable(_ version: ContentVersion) -> (backup: IndexVersion, node: SnapshotNode)? {
        guard let backup = version.snapshots.first else { return nil }
        let node = details[backup.id]?.node ?? SnapshotNode(name: self.node.name, type: .file, path: self.node.path)
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
            let found = try await model.fileHistory(repositoryID: node.repositoryID, path: node.path)
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

/// One version: when the file was modified then and how big it was, the
/// backups that held it, and how it follows the version before.
private struct FileVersionRow: View {
    let version: ContentVersion
    /// The newest backup's node of the file, once the find has answered.
    let detail: FindMatch?
    let isReadingDetail: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(modified)
                Text(backedUp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(sinceText)
                .font(.caption)
                .foregroundStyle(version.since == .uncertain ? .secondary : .tertiary)
                .help(sinceHelp)
            Text(detail.map { Format.bytes($0.size) } ?? (isReadingDetail ? "…" : "—"))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var modified: String {
        if let mtime = detail?.mtime { return "Modified \(Format.timestamp(mtime))" }
        return isReadingDetail ? "Reading…" : "Modified —"
    }

    /// "Backed up Oct 3, 2026 at 9:00 PM" for one backup; for several, the
    /// newest and oldest and how many.
    private var backedUp: String {
        guard let newest = version.snapshots.first, let oldest = version.snapshots.last else { return "" }
        if version.snapshots.count == 1 { return "Backed up \(Format.timestamp(newest.time))" }
        return "Backed up \(Format.timestamp(oldest.time)) – \(Format.timestamp(newest.time)) · \(Format.plural(version.snapshots.count, "backup"))"
    }

    private var sinceText: String {
        switch version.since {
        case .changed: "Changed"
        case .uncertain: "May have changed"
        case nil: "Oldest"
        }
    }

    private var sinceHelp: String {
        switch version.since {
        case .changed: "restic's diff of this backup with the one before said the file changed"
        case .uncertain: "No diff compared this backup with the one before, or the file was absent in between: its content may be the same"
        case nil: "The oldest content of this file in the plan's backups"
        }
    }
}
