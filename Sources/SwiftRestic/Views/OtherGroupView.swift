import SwiftUI

/// The page of one group under a repository's Other backups — a plan's
/// history in this repository that none of its plans owns, or the backups
/// of one Mac's folders that no plan made. Overview | Files in the toolbar,
/// as a plan's page has: the overview says what the history is, in one
/// sentence, and the facts that identify it (when, from which Mac, which
/// folders, which patterns, its plan tag), with its newest backup one click
/// away; Files is its folders and files across every backup. The records
/// themselves are the sidebar's, under the group — the plan page's own rule
/// — so the page does not list them a second time.
///
/// Every fact comes from `OtherGroupPageSummary`, the one derivation the
/// sidebar's labels already feed. No verbs in the toolbar: there is nothing
/// to edit before a group is adopted (the explanation card's verb, raised
/// through the root as the sidebar's is) and nothing to refresh that the
/// repository's page does not already offer.
struct OtherGroupView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let repositoryID: UUID
    let groupID: OtherBackupsGroup.ID
    /// Opens the adopt sheet for a plan-UUID group — the root owns the
    /// presenting state, as it does for every sheet a pane raises.
    let onAdopt: (_ planID: UUID) -> Void
    /// The Files tab's "Search All Backups…": Find Files, prefilled.
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
                switch router.tab(of: page) {
                case .overview: content(summary)
                case .files:
                    FilesBrowserView(
                        roots: FileNode.roots(repositoryID: repositoryID, chainKey: summary.chainKey),
                        searchPrompt: "Search these backups' files",
                        onSearchAllBackups: onSearchAllBackups
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
        .pageTabPicker(router.tabBinding(for: page))
    }

    private func content(_ summary: OtherGroupPageSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            explanationCard(summary)
            backupsCard(summary)
        }
        .detailPane()
    }

    /// What the history is, in the summary's one sentence — and the way on
    /// from it: adopting, for a plan no configuration sets up, or the plan
    /// itself, for one that now backs up elsewhere. Moving a plan back is
    /// the plan editor's guarded path, so this page offers the plan, not a
    /// second way to move it. Backups no plan made have no way on: the
    /// sentence says why.
    private func explanationCard(_ summary: OtherGroupPageSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(summary.explanation)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            if let plan = summary.formerPlan {
                Button("Open the “\(plan.displayName)” Plan") {
                    router.selection = .plan(plan.id)
                }
                .controlSize(.small)
                .help("Show this plan's page, where it backs up now")
            } else if case let .plan(planID) = groupID {
                // The flow's main entry: the group selected, adopt beside
                // what it adopts — the group's context menu carries the
                // same verb.
                Button("Adopt as a Backup Plan…") { onAdopt(planID) }
                    .controlSize(.small)
                    .help("Rebuild a plan around these backups — their history becomes its own, and nothing is written to the repository")
            }
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }

    /// The history's identifying facts. Newest and Oldest bracket it; Made
    /// from, Folders, Excludes and Tags say what it holds — a folder set
    /// per line when the plan's folders changed, rows omitted when there
    /// is nothing to say — and Plan tag is the identifier itself, the one
    /// line a copy can carry elsewhere, for a group that has one.
    private func backupsCard(_ summary: OtherGroupPageSummary) -> some View {
        Card("Backups") {
            DetailGrid {
                DetailRow("Newest", Format.timestamp(summary.newestAt))
                DetailRow("Oldest", Format.timestamp(summary.oldestAt))
                DetailRow("Made from") {
                    Text(summary.madeFrom)
                }
                DetailRow("Folders") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(summary.folders, id: \.self) { set in
                            Text(set)
                                .lineLimit(1)
                                .truncationMode(.middle)
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
                if let planTag = summary.planTag {
                    DetailRow("Plan tag") {
                        Text(planTag)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(planTag)
                    }
                }
            }
        } accessory: {
            // The group's newest record, selected in the sidebar, which
            // opens the group's fold. Its files across every backup are the
            // toolbar's Files.
            Button("Restore Files…") {
                router.showRestore(repositoryID: repositoryID, snapshotID: summary.newestSnapshotID)
            }
            .controlSize(.small)
            .help("Browse these backups and restore files — opens the group's newest record in the sidebar")
        }
    }
}
