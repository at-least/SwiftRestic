import AppKit
import SwiftUI

/// A page's Backups tab: the page's backups, newest first, on the leading
/// side — a section per month once the history passes one — and the open
/// one's files on the trailing side (`RestorePaneView`), with the versions
/// of the file picked in them under the tree (`FilesPaneView`): Time
/// Machine's way, one moment's folders beside the moments. While a plan's
/// search field holds a query, its hits stand in the tree's place
/// (`FilesSearchView`). Not the sidebar's, folded under their plan: the
/// HIG's Sidebars ("In general, show no more than two levels of hierarchy in a sidebar.
/// When a data hierarchy is deeper than two levels, consider using a split
/// view interface that includes a content list between the sidebar items
/// and detail view") — this list is that content list, and its edge drags.
///
/// Which backup is open is the router's, per page, so leaving the page and
/// coming back finds it as it was left; a page opens on its newest backup.
struct BackupsBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @Environment(FilesTree.self) private var filesTree
    let page: SidebarItem
    let repositoryID: UUID
    /// The page's backups, newest first.
    let backups: [Snapshot]

    /// The list's width, dragged at its edge — the window's, kept across
    /// pages while it is open.
    @SceneStorage("BackupsListWidth") private var listWidth: Double = 230
    /// The view's own width, which bounds the drag: the pane keeps room for
    /// its tree.
    @State private var width: CGFloat = 0

    /// The backup the tab has open: the page's pick while the listing still
    /// holds it, else the newest — so a pick retention removed gives way to
    /// the newest rather than to an empty pane.
    static func openBackup(in backups: [Snapshot], picked: String?) -> Snapshot? {
        backups.first { $0.id == picked } ?? backups.first
    }

    private var open: Snapshot? {
        Self.openBackup(in: backups, picked: router.backupSelection[page])
    }

    /// The plan whose empty list can offer Back Up Now — a plan page's;
    /// a group's page has no plan to run and passes none.
    private var statusRowPlanID: UUID? {
        if case let .plan(planID) = page { planID } else { nil }
    }

    /// The chain the open backup belongs to, whose items' versions the pane
    /// under the tree reads — and, on a plan's page, the plan's search.
    private var roots: FileNode? {
        if let searchRoots = model.filesSearchRoots(for: page) { return searchRoots }
        return open.map { FileNode.roots(repositoryID: repositoryID, chainKey: SnapshotIndex.chainKey(for: $0)) }
    }

    private var isSearching: Bool {
        guard let roots else { return false }
        return !router.filesSearchQuery(for: roots).isEmpty
    }

    var body: some View {
        // An HStack, not HSplitView: the split would not narrow the pane
        // below the width it first laid out at, so a wider list pushes the
        // window's content past its edges — the sidebar and the pane's
        // buttons clip.
        HStack(spacing: 0) {
            list
                .frame(width: min(max(listWidth, listBounds.lowerBound), listBounds.upperBound))
            TreeEdge(width: $listWidth, bounds: listBounds)
            VStack(spacing: 0) {
                pane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                itemPane
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // The disk is not watched: what the tab shows of this Mac is read
        // again when the tab shows, when SwiftRestic comes to the front —
        // another app may have changed a folder meanwhile — and when a
        // volume comes or goes.
        .onChange(of: page, initial: true) { filesTree.diskMayHaveChanged() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            filesTree.diskMayHaveChanged()
        }
    }

    /// The versions of the item picked in the tree or the search, under
    /// them; nothing while none is.
    @ViewBuilder
    private var itemPane: some View {
        if let roots, let item = router.filesSelection[roots] {
            Divider()
            FilesPaneView(node: item)
                // Each item's version state is its own, and a pick in the
                // tree opens it anew at the backup it was picked in.
                .id(FilesPaneIdentity(node: item, opening: router.filesPaneOpenings))
                .frame(height: Self.itemPaneHeight)
        }
    }

    /// Room for the item's name and path and a few versions, leaving the
    /// tree above the larger part of a window at its default size.
    private static let itemPaneHeight: CGFloat = 300

    /// A file picked in the tree, or none: the pane under it follows.
    private func pick(_ picked: RestorePanePick?) {
        guard let roots else { return }
        guard let picked else {
            router.filesSelection[roots] = nil
            return
        }
        router.showVersions(
            of: FileNode(repositoryID: repositoryID, chainKey: roots.chainKey, path: picked.path, isDirectory: false),
            at: picked.backupID
        )
    }

    @ViewBuilder
    private var list: some View {
        if backups.isEmpty {
            // The empty words only once the listing says so; before that
            // it is being read, and after a failure the row says why.
            BackupsStatusRow(repositoryID: repositoryID, planID: statusRowPlanID)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            let openID = open?.id
            ScrollViewReader { proxy in
                List(selection: Binding(
                    get: { openID },
                    set: { router.backupSelection[page] = $0 }
                )) {
                    // Past one month, a section per month, so a deep history
                    // has landmarks.
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
                // A backup a route opened — a search hit, Search All Backups, a
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
        if let open, let roots, isSearching {
            FilesSearchView(roots: roots, page: page, openBackup: open)
        } else if let open {
            RestorePaneView(
                repositoryID: repositoryID,
                snapshotID: open.id,
                onPick: pick
            )
                // Folder state is one page's: another page — another plan's of
                // the same repository too, which the root shows in the same
                // view — must not carry paths or history over. The pane's own
                // @State resets with the identity.
                .id(page)
        } else {
            // Blank behind the list's own empty row — "Reading backups…",
            // its failure, or the empty words — which state the fact
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
                SnapshotCompletenessMark(run: run, isMuted: true)
                    .font(.caption)
                    .frame(width: Self.markWidth)
            }
            // One utterance per backup: the mark's label, when it has one,
            // merges with the date.
            .accessibilityElement(children: .combine)
    }

    private static let markWidth: CGFloat = 14
}

/// What a page's Backups tab says while it lists no backup, once a
/// listing has succeeded: "No backups yet", or — a plan's page whose
/// repository holds others — PlanStatus.noneFromThisPlanFact. Before that
/// it is still being read, and after a failure it says why. A plan's page offers its verb
/// under the words — the pane would otherwise hold nothing to do; a
/// group's page has no plan to run, so the words stand alone.
private struct BackupsStatusRow: View {
    @Environment(AppModel.self) private var model
    let repositoryID: UUID
    let planID: UUID?

    var body: some View {
        let outcome = model.snapshotListingOutcome(for: repositoryID)
        if model.loadingSnapshots.contains(repositoryID) || outcome == .idle {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Reading backups…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if outcome != .loaded {
            SnapshotListingCaveat(outcome: outcome, repositoryID: repositoryID)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // A plan's page says which kind of empty this is, as the
                // Overview's count line does; a group's page, or a
                // repository with nothing of anyone's, the plain fact.
                Text(
                    planID != nil && !model.snapshots(for: repositoryID).isEmpty
                        ? PlanStatus.noneFromThisPlanFact
                        : "No backups yet"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if let planID {
                    Button("Back Up Now") { model.runBackup(planID: planID) }
                        // The rule every Back Up Now follows.
                        .disabled(!model.planCommands(for: .plan(planID)).canBackUp)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct FilesPaneIdentity: Hashable {
    let node: FileNode
    let opening: Int
}

/// A column's trailing edge, which drags its width within `bounds`.
private struct TreeEdge: View {
    @Binding var width: Double
    let bounds: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start + drag.translation.width, bounds.lowerBound), bounds.upperBound)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            }
    }
}
