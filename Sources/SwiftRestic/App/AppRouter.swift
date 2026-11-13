import Observation
import SwiftUI

/// Not on `AppModel`: none of this is domain state — it is the navigation
/// surface the views and the menu bar share, and pane switches would
/// otherwise write through the same object the domains mutate. Intents
/// asked while the window is closed survive until the window exists.
@MainActor
@Observable
final class AppRouter {
    /// What the user asked for, from a menu command or the tray. Consumed by
    /// the root view: cleared the moment it is seen, then applied only when
    /// no sheet is already up — refused with a beep otherwise.
    enum Intent: Equatable {
        case newPlan
        case newRepository
        case showFind
        case runSelectedPlan
        // The Backup and Location menus' targeted asks carry their target
        // rather than read the selection when consumed: the ask may wait for
        // a window, and the selection may move meanwhile. runSelectedPlan is
        // the exception — its item enables against the live selection, and
        // the consume re-checks planCommands(for: router.selection) the same
        // way.
        case stopPlan(UUID)
        case editPlan(UUID)
        case editRepository(UUID)
        case enterPassword(UUID)
        case confirm(CommandConfirmation)
        /// Verify Backups, from every surface that offers it: at once, with
        /// no question — a check only reads, and a backup asked for
        /// meanwhile waits its turn. Then the location's page, the only
        /// place a check shows its progress and Cancel; a check that passes
        /// posts no banner.
        case verifyBackups(UUID)
        /// Clean Up Again and a full location's Clean Up Now, from Activity's
        /// drawer and a failed run's fix, the only ways to it: at once, as
        /// Verify Backups — the failed run already asked for it.
        case cleanUp(UUID)
    }

    var selection: SidebarItem?

    /// The pending intent, if any. One slot, not a queue: a second request
    /// before the first was consumed replaces it — two sheets cannot present
    /// at once, so queueing would only delay a stale ask.
    private(set) var pendingIntent: Intent?

    /// The run a detail surface asked Activity to land selected — the plan
    /// page's "Last backup" value: the timestamp is the handle to its own
    /// record. Transient, never persisted; Activity consumes and clears it.
    var activityFocusRunID: RunRecord.ID?

    /// Transient, never persisted: whether Activity shows every run or only
    /// problems — Activity's own picker. A landing that may arrive on a clean
    /// run (the plan page's Last backup) turns it off.
    var activityShowsProblemsOnly = false

    /// An item a backup's tree should open its folders to and select when
    /// it next loads this exact record — a search hit, Search All Backups'
    /// row, an unread item's earlier copy.
    private struct RestoreFocus: Equatable {
        var repositoryID: UUID
        var snapshotID: String
        var path: String
    }

    /// Transient, never persisted. Keyed on the record so a stale request can
    /// never steer an unrelated load; the pane spends it on its next load.
    private var restoreFocus: RestoreFocus?

    /// The toolbar's Overview | Backups, one choice for every page
    /// (the user's call, 2026-10-24): switching plans keeps the view. Read
    /// through `tab(of:)`, never directly — a page without the chosen view
    /// shows another. Transient: every page opens on its overview after a
    /// launch, where "is it backing up" is answered.
    private(set) var pageTab: PageTab = .overview

    /// The backup each page's Backups tab has open, by the page. Transient,
    /// as the tabs are: a page keeps its pick for the session, and its tab
    /// opens on the newest backup after a launch.
    var backupSelection: [SidebarItem: String] = [:]

    /// The item whose versions each chain's Backups tab shows under its
    /// tree, by the chain's roots (`FileNode.roots`): a file picked in the
    /// tree or a search hit. Transient.
    var filesSelection: [FileNode: FileNode] = [:]

    /// What each chain's Backups tab is searching for, by the chain's
    /// roots, as typed in the toolbar's search field; empty or absent shows
    /// the backup's tree. Transient, as the selection is: a search left on a
    /// page is there when the page is shown again.
    var filesSearchText: [FileNode: String] = [:]

    /// The search `roots`' Backups tab runs: the typed text, trimmed; empty
    /// shows the tree.
    func filesSearchQuery(for roots: FileNode) -> String {
        (filesSearchText[roots] ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The page whose toolbar search field takes the keyboard focus next —
    /// ⌘F, and Search All Backups on arrival. The page spends it once its
    /// field has the focus.
    var searchFocus: SidebarItem?

    func showMaintenance(of repositoryID: UUID) {
        if selection != .repository(repositoryID) {
            selection = .repository(repositoryID)
        }
    }

    func searchFiles(on page: SidebarItem) {
        setTab(.backups, of: page)
        searchFocus = page
    }

    /// Search All Backups' query as typed in its toolbar field — and in a
    /// repository's page's, which hands it over on Return. Transient, kept
    /// while the app runs: coming back to the page finds it.
    var findQuery = ""

    /// The plan a search came from, for the page's way back to it.
    struct FindOrigin: Equatable {
        var page: SidebarItem
        var roots: FileNode
    }

    private(set) var findOrigin: FindOrigin?

    func openFind(query: String? = nil, from origin: FindOrigin? = nil) {
        if let query { findQuery = query }
        findOrigin = origin
        searchFocus = .findFiles
        selection = .findFiles
    }

    /// Search All Backups' This Plan: the plan's Backups tab, the query kept.
    func returnToPlanSearch() {
        guard let origin = findOrigin else { return }
        filesSearchText[origin.roots] = findQuery
        searchFiles(on: origin.page)
        selection = origin.page
    }

    /// The backup each file's pane opens at — the version left at, or the
    /// backup the file was picked in — so coming back to the file from
    /// another page finds it as it was read. Transient; a pane reads it as it
    /// opens, never while shown.
    @ObservationIgnored var filesChosenVersion: [FileNode: String] = [:]

    /// Bumped by `showVersions`, so the file's pane opens again — at the
    /// backup it names — even for the file already selected, whose pane
    /// would otherwise keep its version.
    private(set) var filesPaneOpenings = 0

    /// The chosen view where `page` offers it.
    func tab(of page: SidebarItem) -> PageTab {
        page.pageTabs.contains(pageTab) ? pageTab : .overview
    }

    /// Sets the view for every page. Only a tab `page` offers
    /// (`SidebarItem.pageTabs`): a route that asks a page without it is a bug
    /// to hear about.
    func setTab(_ tab: PageTab, of page: SidebarItem) {
        precondition(page.pageTabs.contains(tab), "\(page) has no \(tab.menuTitle) tab")
        pageTab = tab
    }

    /// A file picked in a backup's tree: its versions under the tree,
    /// opening at the backup it was picked in.
    func showVersions(of item: FileNode, at backupID: String) {
        filesSelection[FileNode.roots(repositoryID: item.repositoryID, chainKey: item.chainKey)] = item
        filesChosenVersion[item] = backupID
        filesPaneOpenings += 1
    }

    func tabBinding(for page: SidebarItem) -> Binding<PageTab> {
        Binding(get: { self.tab(of: page) }, set: { self.setTab($0, of: page) })
    }

    /// The main window's `openWindow` action, parked by the root view the
    /// first time the window appears — the AppKit tray has no view
    /// environment to call it from, and it outlives the window it was
    /// captured in. See TrayStatusItem.openMainWindow.
    @ObservationIgnored var openMainWindowAction: OpenWindowAction?

    /// Records an intent for the root view to consume. Naming it `request`
    /// keeps call sites reading as what they are — asks, not commands.
    func request(_ intent: Intent) {
        pendingIntent = intent
    }

    func focusRun(_ id: RunRecord.ID) {
        activityFocusRunID = id
        selection = .activity
    }

    func takePendingIntent() -> Intent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }

    /// A plain route clears an older focus request rather than inheriting
    /// it. A plan's search left on the tab would list its hits over the
    /// tree the route lands on, so it ends.
    func showBackup(_ snapshotID: String, on page: SidebarItem, repositoryID: UUID, focusPath: String? = nil) {
        restoreFocus = focusPath.map {
            RestoreFocus(repositoryID: repositoryID, snapshotID: snapshotID, path: $0)
        }
        if case let .plan(planID) = page {
            filesSearchText[FileNode.roots(repositoryID: repositoryID, chainKey: ResticService.planTag(planID))] = nil
        }
        backupSelection[page] = snapshotID
        // A group's page is its backups, with no tab to turn; the choice
        // stays as it was for the next plan's page.
        if page.pageTabs.contains(.backups) { setTab(.backups, of: page) }
        selection = page
    }

    /// A backup's tree's consumption half: the focus path, only when it was
    /// asked for this record. Spent either way — a load of another record
    /// means the request is stale.
    func takeRestoreFocus(repositoryID: UUID, snapshotID: String) -> String? {
        defer { restoreFocus = nil }
        guard let restoreFocus,
              restoreFocus.repositoryID == repositoryID,
              restoreFocus.snapshotID == snapshotID
        else { return nil }
        return restoreFocus.path
    }

    /// After a deletion the selected plan or repository may no longer exist;
    /// landing on "Plan not found" is a dead end whose only exit is the
    /// sidebar, so retarget to the landing pane instead. A selected
    /// Other-backups group falls back to its repository's page — the place
    /// it lived — for every way it can disappear: adopted, its plan moved
    /// by the editor, refreshed away, its repository removed.
    static func revalidated(
        selection: SidebarItem?,
        repositories: [Repository],
        plans: [BackupPlan],
        shelves: (UUID) -> BackupShelves,
        isResticAvailable: Bool
    ) -> SidebarItem? {
        let landing = SidebarTree.landingSelection(repositories: repositories, plans: plans)
        switch selection {
        case .plan(let id) where !plans.contains { $0.id == id },
             .repository(let id) where !repositories.contains { $0.id == id }:
            return landing
        case let .orphanPlan(repositoryID, planID)
            where shelves(repositoryID).orphanPlanGroup(planID) == nil:
            // The group is gone — adopted, its plan moved by the editor, or
            // refreshed away. Its repository's page is where it lived; the
            // landing pane when the repository went with it.
            return repositories.contains { $0.id == repositoryID }
                ? .repository(repositoryID)
                : landing
        case let .lineage(repositoryID, key)
            where shelves(repositoryID).lineageGroup(key) == nil:
            // The same for a lineage — forgotten, given a plan tag by the
            // console, or refreshed away.
            return repositories.contains { $0.id == repositoryID }
                ? .repository(repositoryID)
                : landing
        case .findFiles where repositories.isEmpty || !isResticAvailable:
            // Its menu item is disabled against the same state; a selection
            // parked on the page must not outlive the item that opens it.
            return landing
        default:
            return selection
        }
    }
}

/// Not the sidebar's, folded under their plan: a sidebar shows no more than
/// two levels (HIG, Sidebars).
enum PageTab: Hashable, CaseIterable {
    case overview
    case backups

    var menuTitle: String {
        switch self {
        case .overview: "Overview"
        case .backups: "Backups"
        }
    }
}

/// The destructive (or slow) actions that ask first, wherever they are
/// asked from — the menu bar, a pane's toolbar, a sidebar menu. One dialog
/// presents them all (`CommandPresentations`), with the model's words
/// (`AppModel.confirmationCopy(for:)`), so no two surfaces can word one
/// action two ways.
enum CommandConfirmation: Hashable, Identifiable {
    case deletePlan(UUID)
    case deleteRepository(UUID)

    var id: Self { self }
}
