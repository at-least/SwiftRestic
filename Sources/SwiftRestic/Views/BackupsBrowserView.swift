import SwiftUI

/// A page's Backups tab: the page's backups, newest first, on the leading
/// side — a section per month once the history passes one — and the open
/// one's files on the trailing side (`RestorePaneView`), the Files tab's own
/// layout. Not the sidebar's, folded under their plan: the HIG's Sidebars
/// ("In general, show no more than two levels of hierarchy in a sidebar.
/// When a data hierarchy is deeper than two levels, consider using a split
/// view interface that includes a content list between the sidebar items
/// and detail view") — this list is that content list, and its edge drags.
///
/// Which backup is open is the router's, per page, so leaving the page and
/// coming back finds it as it was left; a page opens on its newest backup.
struct BackupsBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    /// The page whose backups these are.
    let page: SidebarItem
    let repositoryID: UUID
    /// The page's backups, newest first.
    let backups: [Snapshot]
    /// "Search All Backups": the host opens Find Files on this repository
    /// with the query filled in.
    let onSearchAllBackups: (_ repositoryID: UUID, _ query: String) -> Void

    /// The list's width, dragged at its edge — the window's, kept across
    /// pages while it is open, as the Files tab's tree's is.
    @SceneStorage("BackupsListWidth") private var listWidth: Double = 230
    /// The view's own width, which bounds the drag: the pane keeps room for
    /// its tree.
    @State private var width: CGFloat = 0
    /// Compare with Previous's sheet: what the backup changed, deletions
    /// among them — the tree, being the backup's, shows only what it holds.
    @State private var comparing: SnapshotDiffTarget?

    /// The backup the tab has open: the page's pick while the listing still
    /// holds it, else the newest — so a pick retention removed gives way to
    /// the newest rather than to an empty pane.
    static func openBackup(in backups: [Snapshot], picked: String?) -> Snapshot? {
        backups.first { $0.id == picked } ?? backups.first
    }

    private var open: Snapshot? {
        Self.openBackup(in: backups, picked: router.backupSelection[page])
    }

    var body: some View {
        // An HStack, not HSplitView: the Files tab's reason — the split
        // would not narrow the pane below the width it first laid out at.
        HStack(spacing: 0) {
            list
                .frame(width: min(max(listWidth, listBounds.lowerBound), listBounds.upperBound))
            TreeEdge(width: $listWidth, bounds: listBounds)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .sheet(item: $comparing) { target in
            SnapshotDiffView(target: target)
                .environment(model)
                .environment(router)
        }
    }

    @ViewBuilder
    private var list: some View {
        if backups.isEmpty {
            // "No backups yet" only once the listing says so; before that
            // it is being read, and after a failure the row says why.
            BackupsStatusRow(repositoryID: repositoryID)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let openID = open?.id
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { openID },
                    set: { router.backupSelection[page] = $0 }
                )) {
                    // Past one month, a section per month (the Compare
                    // sheet's months), so a deep history has landmarks.
                    if let months = DiffCandidateGrouping.landmarks(in: backups, time: \.time) {
                        ForEach(months, id: \.label) { month in
                            Section(month.label) {
                                rows(month.items, sectioned: true)
                            }
                        }
                    } else {
                        rows(backups, sectioned: false)
                    }
                }
                .listStyle(.inset)
                // Activity's Compare with Previous, on the backup clicked —
                // offered only where there is a previous backup of the same
                // folders from the same Mac to compare with.
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first,
                       let snapshot = backups.first(where: { $0.id == id }),
                       SnapshotLineage.changeBaseline(for: id, in: model.snapshots(for: repositoryID)) != nil
                    {
                        Button("Compare with Previous") {
                            comparing = SnapshotDiffTarget(repositoryID: repositoryID, snapshot: snapshot)
                        }
                    }
                }
                // A backup a route opened — a Files tab's Show in Backups, a
                // run's Browse — may sit a year down the list: brought into
                // view, a turn later because the list may gain its row in
                // this update. A click's row is in view already, and the
                // minimal scroll leaves it where it is.
                .onChange(of: openID, initial: true) { _, id in
                    guard let id else { return }
                    Task { @MainActor in proxy.scrollTo(id) }
                }
            }
        }
    }

    private func rows(_ snapshots: [Snapshot], sectioned: Bool) -> some View {
        ForEach(snapshots) { snapshot in
            BackupRow(snapshot: snapshot, run: model.backupRun(forSnapshot: snapshot.id), isSectioned: sectioned)
                .tag(snapshot.id)
                .id(snapshot.id)
        }
    }

    @ViewBuilder
    private var pane: some View {
        if let open {
            RestorePaneView(
                repositoryID: repositoryID,
                snapshotID: open.id,
                searchText: Binding(
                    get: { router.backupsSearchText[page] ?? "" },
                    set: { router.backupsSearchText[page] = $0 }
                ),
                onSearchAllBackups: onSearchAllBackups
            )
                // Folder state and the record the search belongs to are one
                // page's: another page — another plan's of the same
                // repository too, which the root shows in the same view —
                // must not carry paths, history or a search over, nor find
                // its own query wiped as if it were a record switch
                // (`RestorePaneView.loadLevel`). The pane's own @State resets
                // with the identity.
                .id(page)
        } else {
            // Blank behind the list's own empty row — "Reading backups…",
            // its failure, or "No backups yet" — which states the fact
            // already; a second empty pane said it twice.
            Color.clear
        }
    }

    /// How far the list's edge drags: no narrower than a backup's moment
    /// needs, no wider than leaves the pane its tree.
    private var listBounds: ClosedRange<Double> {
        let lower = 225.0
        return lower...max(lower, min(360, Double(width) - 400))
    }
}

/// One backup in a Backups tab's list — its moment, and the completeness
/// mark when restic could not read all of it: the whole record at list
/// size, as Arq's is.
private struct BackupRow: View {
    let snapshot: Snapshot
    /// The backup run that wrote it, when the history still holds one.
    let run: RunRecord?
    /// The list sits under "October 2026" section headers, so the row drops
    /// the year its header says; a flat single-month list keeps the full
    /// stamp.
    let isSectioned: Bool

    var body: some View {
        Text(isSectioned ? Format.dayTime(snapshot.time) : Format.timestamp(snapshot.time))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            // State trails identity, the sidebar's rule: the mark sits at
            // the row's right end, and only a visible one claims room there.
            .padding(.trailing, run?.snapshotCompleteness == .incomplete ? Self.markWidth + 6 : 0)
            // An overlay, so the clear "Complete" text and the hidden
            // slot-holder stay in the row — VoiceOver keeps its
            // Complete/Incomplete word — without taking the date's width.
            .overlay(alignment: .trailing) {
                SnapshotCompletenessMark(run: run)
                    .font(.caption)
                    .frame(width: Self.markWidth)
            }
            // One utterance per backup: the mark's label, when it has one,
            // merges with the date.
            .accessibilityElement(children: .combine)
    }

    private static let markWidth: CGFloat = 14
}
