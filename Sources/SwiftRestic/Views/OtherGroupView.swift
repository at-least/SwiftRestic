import SwiftUI

/// The page of one group under a repository's Other backups: its backups,
/// each one's files beside the list, under one line saying what they are and,
/// where it can, Continue Backups — a new Mac's way back to its history. No
/// Files tab, as a plan's page has: that lists a folder as this Mac holds it
/// now, and these backups name none of this Mac's to list.
struct OtherGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let repositoryID: UUID
    let groupID: OtherBackupsGroup.ID
    /// Opens the adopt sheet for a plan-UUID group — the root owns the
    /// presenting state, as it does for every sheet a pane raises.
    let onAdopt: (_ planID: UUID) -> Void

    private var summary: OtherGroupPageSummary? {
        model.shelves(for: repositoryID).otherGroupPage(
            groupID,
            repositories: model.configuration.repositories,
            localHost: model.localHostname
        )
    }

    private var page: SidebarItem {
        .otherGroup(repositoryID: repositoryID, id: groupID)
    }

    var body: some View {
        Group {
            if let summary {
                VStack(spacing: 0) {
                    header(summary)
                    Divider()
                    BackupsBrowserView(
                        page: page,
                        repositoryID: repositoryID,
                        backups: groupBackups
                    )
                }
            } else {
                // Only while the shelves lag a change that revalidation is
                // already reacting to — the group was adopted, its plan
                // moved, or a refresh dropped it.
                ContentUnavailableView("Backups not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(summary?.title ?? "Backups")
        .navigationSubtitle(subtitle)
        .allBackupsSearch()
    }

    /// The group's backups, newest first.
    private var groupBackups: [Snapshot] {
        model.shelves(for: repositoryID).others.first { $0.id == groupID }?.snapshots ?? []
    }

    private var subtitle: String {
        guard let open = BackupsBrowserView.openBackup(in: groupBackups, picked: router.backupSelection[page])
        else { return "" }
        return Format.timestamp(open.time)
    }

    private func header(_ summary: OtherGroupPageSummary) -> some View {
        HStack(spacing: 12) {
            // Not fixedSize: the window measures its minimum at a tiny width,
            // this text then reads hundreds of points tall, and the split
            // view is pushed up under the title bar.
            Text(summary.explanation)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
            Spacer(minLength: 12)
            if summary.isAdoptable, case let .plan(planID) = groupID {
                Button("Continue Backups…") { onAdopt(planID) }
                    .buttonStyle(.borderedProminent)
                    .help("Keep backing up this folder from this Mac, with these backups as its history")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
