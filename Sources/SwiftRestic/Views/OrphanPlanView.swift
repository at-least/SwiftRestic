import SwiftUI

/// The page of one plan-UUID group under a repository's Other backups — a
/// plan's history in this repository that none of its plans owns. What the
/// history is, in one sentence; the facts that identify it (when, from
/// which Mac, which folders, which patterns, its plan tag); and the way
/// into its files. The records themselves are the sidebar's, under the
/// group — the plan page's own rule — so the page does not list them a
/// second time.
///
/// Every fact comes from `OrphanPlanPageSummary`, the one derivation the
/// sidebar's labels already feed. The toolbar is empty on purpose: there
/// is nothing to edit before the group is adopted (next stage's verb, from
/// this page's explanation card) and nothing to refresh that the
/// repository's page does not already offer.
struct OrphanPlanView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    let repositoryID: UUID
    let planID: UUID

    @State private var browsingFolders: FolderBrowserTarget?

    private var summary: OrphanPlanPageSummary? {
        model.shelves(for: repositoryID).orphanPlanPage(
            planID: planID,
            repositories: model.configuration.repositories,
            localHost: model.localHostname
        )
    }

    var body: some View {
        Group {
            if let summary {
                content(summary)
            } else {
                // Only while the shelves lag a change that revalidation is
                // already reacting to — the group was adopted, its plan
                // moved, or a refresh dropped it.
                ContentUnavailableView("Backups not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(summary?.title ?? "Backups")
        .sheet(item: $browsingFolders) { target in
            // Show in Restore leaves for the Restore pane at the version
            // and folder the folder browser was showing — the plan page's
            // own wiring.
            FolderBrowserView(target: target, onShowInRestore: { snapshotID, folder in
                router.showRestore(repositoryID: target.repositoryID, snapshotID: snapshotID, focusPath: folder)
            })
            .environment(model)
        }
    }

    private func content(_ summary: OrphanPlanPageSummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(model.banners) { banner in
                BannerView(banner: banner)
            }

            explanationCard(summary)
            backupsCard(summary)
        }
        .detailPane()
    }

    /// What the history is, in the summary's one sentence — and, for a
    /// plan that now backs up elsewhere, the way back to it. Moving a plan
    /// back is the plan editor's guarded path, so this page offers the
    /// plan, not a second way to move it.
    private func explanationCard(_ summary: OrphanPlanPageSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(summary.explanation)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            if let plan = summary.formerPlan {
                Button("Open the “\(plan.name.isEmpty ? "Untitled Plan" : plan.name)” Plan") {
                    router.selection = .plan(plan.id)
                }
                .controlSize(.small)
                .help("Show this plan's page, where it backs up now")
            }
        }
        .padding(Theme.Space.cardPadding)
        .cardSurface()
    }

    /// The history's identifying facts. Newest and Oldest bracket it; Made
    /// from, Folders, Excludes and Tags say what it holds — a folder set
    /// per line when the plan's folders changed, rows omitted when there
    /// is nothing to say — and Plan tag is the identifier itself, the one
    /// line a copy can carry elsewhere.
    private func backupsCard(_ summary: OrphanPlanPageSummary) -> some View {
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
                DetailRow("Plan tag") {
                    Text(summary.planTag)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(summary.planTag)
                }
            }
        } accessory: {
            HStack(spacing: 8) {
                // The plan page's own entry: the group's newest record,
                // selected in the sidebar, which opens the group's fold.
                Button("Restore Files…") {
                    router.showRestore(repositoryID: repositoryID, snapshotID: summary.newestSnapshotID)
                }
                .help("Browse these backups and restore files — opens the group's newest record in the sidebar")
                // The orphan UUID is all a target needs: the browser walks
                // the plan tag's chain and lists from the tag's snapshots,
                // neither of which asks whether a plan is configured.
                Button("Browse Folders…") {
                    browsingFolders = FolderBrowserTarget(repositoryID: repositoryID, planID: planID)
                }
                .help("Walk these folders and flip through the backups that contain them")
            }
            .controlSize(.small)
        }
    }
}
