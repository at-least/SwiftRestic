import SwiftUI

/// The page of one group under a repository's Other backups — a plan's
/// history in this repository that none of its plans owns, or the backups
/// of one Mac's folders that no plan made. Overview | Backups in the
/// toolbar: the overview says what the history is and the facts that
/// identify it; Backups lists them, each one's files beside the list. No
/// Files tab, as a plan's page has: that lists a folder as this Mac holds it
/// now, and these backups name none of this Mac's to list.
///
/// Every fact comes from `OtherGroupPageSummary`, the one derivation the
/// sidebar's labels already feed. No verbs in the toolbar: there is nothing
/// to edit before a group is adopted and nothing to refresh that the
/// repository's page does not already offer.
struct OtherGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let repositoryID: UUID
    let groupID: OtherBackupsGroup.ID
    /// Opens the adopt sheet for a plan-UUID group — the root owns the
    /// presenting state, as it does for every sheet a pane raises.
    let onAdopt: (_ planID: UUID) -> Void
    /// The Backups tab's "Search All Backups": Find Files, prefilled.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

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
                // Overview or Backups: `AppRouter.setTab` takes no other
                // tab for this page.
                if router.tab(of: page) == .backups {
                    BackupsBrowserView(
                        page: page,
                        repositoryID: repositoryID,
                        backups: groupBackups,
                        onSearchAllBackups: onSearchAllBackups
                    )
                } else {
                    content(summary)
                }
            } else {
                // Only while the shelves lag a change that revalidation is
                // already reacting to — the group was adopted, its plan
                // moved, or a refresh dropped it.
                ContentUnavailableView("Backups not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(summary?.title ?? "Backups")
        // On the Backups tab, the moment of the backup open there.
        .navigationSubtitle(subtitle)
        .pageTabPicker(router.tabBinding(for: page), tabs: page.pageTabs)
        .backupsPageSearch(page: page)
    }

    /// The group's backups, newest first.
    private var groupBackups: [Snapshot] {
        model.shelves(for: repositoryID).others.first { $0.id == groupID }?.snapshots ?? []
    }

    private var subtitle: String {
        guard router.tab(of: page) == .backups,
              let open = BackupsBrowserView.openBackup(in: groupBackups, picked: router.backupSelection[page])
        else { return "" }
        return Format.timestamp(open.time)
    }

    private func content(_ summary: OtherGroupPageSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            explanationCard(summary)
            backupsCard(summary)
        }
        .detailPane()
    }

    /// What the history is, in the summary's one sentence — and the way on
    /// from it: adopting, for a plan no configuration sets up, or the plan
    /// itself, for one that now backs up elsewhere — a history left by a
    /// move earlier builds allowed; a saved plan's repository no longer
    /// changes. Backups no plan made have their way on in the sentence too:
    /// the console's tag, which the row's tooltip no longer spells out.
    private func explanationCard(_ summary: OtherGroupPageSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(summary.explanation)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            if let plan = summary.formerPlan {
                Button("Show Plan") {
                    router.selection = .plan(plan.id)
                }
                .controlSize(.small)
            } else if summary.isAdoptable, case let .plan(planID) = groupID {
                // The flow's main entry; the group's context menu carries the
                // same verb.
                Button("Continue Backups…") { onAdopt(planID) }
                    .controlSize(.small)
                    .help("Keep backing up this folder from this Mac, with these backups as its history")
            }
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }

    /// The history's identifying facts. The count line leads, the card's
    /// title labelling it, with how far back the history reaches; Newest
    /// names the latest, and Made on, Folders, Excludes and Tags say what
    /// it holds — rows omitted when there is nothing to say. The plan tag,
    /// an identifier a person rarely reads, is the card's Copy Plan Tag,
    /// not a row.
    private func backupsCard(_ summary: OtherGroupPageSummary) -> some View {
        Card("Backups") {
            DetailGrid {
                // As the plan page's Backups card: the title labels this
                // line, so it goes unlabelled and first.
                Text(OverviewMetrics.snapshotsLine(
                    total: groupBackups.count,
                    otherBackups: 0,
                    repositoryHasPlans: false,
                    since: summary.oldestAt,
                    noun: true
                ))
                .monospacedDigit()
                DetailRow("Newest", Format.timestamp(summary.newestAt))
                DetailRow("Made on") {
                    Text(summary.madeFrom)
                }
                DetailRow(summary.pathCount == 1 ? "Folder" : "Folders") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary.folders, id: \.self) { set in
                            Text(set)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(set)
                        }
                    }
                }
                if !summary.excludes.isEmpty {
                    DetailRow("Excludes") {
                        Text(summary.excludes.joined(separator: ", "))
                    }
                }
                if !summary.userTags.isEmpty {
                    DetailRow("Tags") {
                        Text(summary.userTags.joined(separator: ", "))
                    }
                }
            }
        }
        .contextMenu {
            if let planTag = summary.planTag {
                Button("Copy Plan Tag") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(planTag, forType: .string)
                }
            }
        }
    }
}
