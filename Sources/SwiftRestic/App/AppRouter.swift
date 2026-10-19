import Observation
import SwiftUI

/// The app's view state and window-level intents: which pane is selected,
/// which sheet a menu command asked for, where Activity should land, and the
/// main-window action the AppKit tray needs.
///
/// Split out of `AppModel`: none of this is domain state — it is the
/// navigation surface the views and the menu bar share, and pane switches
/// would otherwise write through the same object the domains mutate. Intents
/// asked while the window is closed survive until the window exists.
@MainActor
@Observable
final class AppRouter {
    /// What the user asked for, from a menu command or the tray. Consumed by
    /// the root view: cleared the moment it is seen, then applied only when
    /// no sheet is already up — refused with a beep otherwise.
    enum Intent: Equatable {
        case newPlan
        /// A new plan in this repository: a failure's fix.
        case newPlanIn(UUID)
        case newRepository
        case showFind
        /// Repository ▸ restic Console…: a pane switch, not a sheet, but it
        /// waits out an open sheet like every other menu ask.
        case showConsole
        case runSelectedPlan
        // The Plan and Repository menus' targeted asks carry their target
        // rather than read the selection when consumed: the ask may wait for
        // a window, and the selection may move meanwhile. runSelectedPlan is
        // the exception — its item enables against the live selection, and
        // the consume re-checks planCommands(for: router.selection) the same
        // way.
        case stopPlan(UUID)
        case pauseSchedule(UUID, PauseLength)
        case resumeSchedule(UUID)
        case editPlan(UUID)
        /// A refused retention's fix (`RunFix.editPlanRetention`): the plan
        /// editor, on its Retention tab.
        case editPlanRetention(UUID)
        case editRepository(UUID)
        case applyRetention(UUID)
        case confirm(CommandConfirmation)
    }

    /// The pane the sidebar is showing.
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

    /// Transient, never persisted: whether a plan's Files tree lists, after
    /// each folder's own items, what only its backups hold — items deleted
    /// from this Mac since. View ▸ Show Deleted Items, off at every launch
    /// (the user's call, 2026-10-19).
    var filesShowsDeletedItems = false

    /// A folder a backup's tree should open and select when it next loads
    /// this exact record — the Files view's Show in Backups, which leaves
    /// the folder or file the user was reading and must not lose their place.
    struct RestoreFocus: Equatable {
        var repositoryID: UUID
        var snapshotID: String
        var path: String
    }

    /// Transient, never persisted. Keyed on the record so a stale request can
    /// never steer an unrelated load; the pane spends it on its next load.
    private(set) var restoreFocus: RestoreFocus?

    /// The view each page shows, by the page's selection — the toolbar's
    /// Overview | Backups | Files. Transient: a page keeps the view it was
    /// left on for the session, so a trip to Activity and back finds it
    /// there, and every page opens on its overview after a launch, where "is
    /// it backing up" is answered.
    private(set) var pageTabs: [SidebarItem: PageTab] = [:]

    /// The backup each page's Backups tab has open, by the page. Transient,
    /// as the tabs are: a page keeps its pick for the session, and its tab
    /// opens on the newest backup after a launch.
    var backupSelection: [SidebarItem: String] = [:]

    /// The folders open in the Files views' trees, every chain's together:
    /// a node names its chain, so one set serves them all. Transient, as the
    /// tabs are.
    var openFolders: Set<FileNode> = []

    /// The folder or file each chain's Files view has selected, by the
    /// chain's roots (`FileNode.roots`). Transient.
    var filesSelection: [FileNode: FileNode] = [:]

    /// What each chain's Files view is searching for, by the chain's roots,
    /// as typed in the toolbar's search field; empty or absent shows the
    /// tree. Transient, as the selection is: a search left on a page is
    /// there when the page is shown again.
    var filesSearchText: [FileNode: String] = [:]

    /// What each page's Backups tab is searching the open backup for, by
    /// the page, as typed in the toolbar's search field. Transient; a
    /// record switch clears it, the search belonging to the backup it ran
    /// in.
    var backupsSearchText: [SidebarItem: String] = [:]

    /// The page whose toolbar search field takes the keyboard focus next —
    /// ⇧⌘F, and Find Files on arrival. The page spends it once its field
    /// has the focus.
    var searchFocus: SidebarItem?

    /// ⇧⌘F on a plan's page: its Files tab, the search field focused.
    func searchFiles(on page: SidebarItem) {
        setTab(.files, of: page)
        searchFocus = page
    }

    /// Find Files' search as typed in its toolbar field — and in a
    /// repository page's, which hands it over on Return. Transient, kept
    /// while the app runs: coming back to Find Files finds it.
    var findQuery = ""

    /// The repository Find Files searches. Transient.
    var findRepositoryID: UUID?

    /// A search Find Files runs as it arrives — Search All Backups…'s and a
    /// repository page's Return, which asked for it — whichever engine
    /// answers. Find Files spends it.
    var findRunsOnArrival = false

    /// Find Files, the pane: on `repositoryID`, with `query` in its field
    /// when one is handed over (Search All Backups…, a repository page's
    /// Return) and run as it arrives when `run` says so — the field
    /// focused, its "area dedicated to discovery", as the HIG puts it.
    func openFind(repositoryID: UUID?, query: String? = nil, run: Bool = false) {
        findRepositoryID = repositoryID
        if let query { findQuery = query }
        findRunsOnArrival = run
        searchFocus = .findFiles
        selection = .findFiles
    }

    /// The backup a folder's listing was read from when one of its items
    /// was opened from it: the item's pane opens at it when the item exists
    /// then, so walking down keeps the era. Transient; the next Files pane
    /// to load spends it, whichever item that is.
    @ObservationIgnored var filesVersionHint: String?

    /// The backup each Files pane was left at, by its item — a folder's
    /// backup, a file's version by its newest backup — so coming back to
    /// the item, from Show in Backups or another page, finds it as it was
    /// read. Transient; a pane reads it as it opens, never while shown.
    @ObservationIgnored var filesChosenVersion: [FileNode: String] = [:]

    /// Bumped by Show Versions, so the Files pane opens again — at the
    /// backup it names — even for the item already selected, whose pane
    /// would otherwise keep its backup and leave the hint for the next.
    private(set) var filesPaneOpenings = 0

    /// An item the Files tab was asked to show — Show Versions', a search
    /// hit picked, one opened from the pane — waiting for the tab to look
    /// whether this Mac still has it: one it no longer has turns Show
    /// Deleted Items on, so the tree lists it (the user's call, 2026-10-19).
    /// Transient; the tab spends it.
    var filesRevealRequest: FileNode?

    func tab(of page: SidebarItem) -> PageTab {
        pageTabs[page] ?? .overview
    }

    /// Only a tab the page offers (`SidebarItem.pageTabs`): a group's page
    /// set to Files would show its overview under a Files segment no one
    /// can see, so a route that asks for one is a bug to hear about.
    func setTab(_ tab: PageTab, of page: SidebarItem) {
        precondition(page.pageTabs.contains(tab), "\(page) has no \(tab.menuTitle) tab")
        pageTabs[page] = tab
    }

    /// An item by version, from a backup that holds it — the Restore pane's
    /// and Find Files' Show Versions: `page`, the plan's page whose Files tab
    /// holds `record`'s history (`BackupShelves.versionsPage(of:)`), on
    /// Files, the item selected with every folder above it open down from
    /// the backed-up folder that holds it, and its pane opening at `record`.
    func showVersions(path: String, isDirectory: Bool, in record: Snapshot, repositoryID: UUID, page: SidebarItem) {
        let chain = SnapshotIndex.chainKey(for: record)
        let item = FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: isDirectory)
        setTab(.files, of: page)
        openFolders(above: item, from: record.paths)
        filesSelection[FileNode.roots(repositoryID: repositoryID, chainKey: chain)] = item
        filesRevealRequest = item
        filesVersionHint = record.id
        filesPaneOpenings += 1
        selection = page
    }

    /// Opens every folder above `item` in its chain's tree, down from the
    /// deepest of `tops` — the backed-up folders the tree hangs from — that
    /// holds it, so the tree lists the item's row: Show Versions, and a hit
    /// picked in a Files tab's search. Nothing opens when no top holds it.
    func openFolders(above item: FileNode, from tops: [String]) {
        guard let top = tops.filter({ ResticPath.holds($0, item.path) }).max(by: { $0.utf8.count < $1.utf8.count })
        else { return }
        var above = ResticPath.parent(of: item.path)
        while ResticPath.holds(top, above) {
            openFolders.insert(FileNode(repositoryID: item.repositoryID, chainKey: item.chainKey, path: above, isDirectory: true))
            // The root is its own parent: a whole-disk backup's top ends the
            // walk here.
            if above.utf8.elementsEqual(top.utf8) { break }
            above = ResticPath.parent(of: above)
        }
    }

    /// The toolbar picker's binding for one page.
    func tabBinding(for page: SidebarItem) -> Binding<PageTab> {
        Binding(get: { self.tab(of: page) }, set: { self.setTab($0, of: page) })
    }

    func takeFilesVersionHint() -> String? {
        defer { filesVersionHint = nil }
        return filesVersionHint
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

    /// Activity, landing on one run: the tray's problem line, a clicked
    /// notification and the problem rows all take this route.
    func focusRun(_ id: RunRecord.ID) {
        activityFocusRunID = id
        selection = .activity
    }

    /// The root view's consumption half: returns and clears whatever was
    /// asked for.
    func takePendingIntent() -> Intent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }

    /// The one route into a backup's contents from outside its page's
    /// Backups tab — the run drawer's Browse, a Files tab's Show in Backups,
    /// a group's Show Backups: `page`, the one whose Backups tab lists the
    /// record (`AppModel.page(ofBackup:in:)`), on that tab with the record
    /// open, where the Change column, search, drag and whole-backup restore
    /// all live, whichever button was pressed. A plain route clears an older
    /// focus request rather than inheriting it.
    func showBackup(_ snapshotID: String, on page: SidebarItem, repositoryID: UUID, focusPath: String? = nil) {
        restoreFocus = focusPath.map {
            RestoreFocus(repositoryID: repositoryID, snapshotID: snapshotID, path: $0)
        }
        backupSelection[page] = snapshotID
        pageTabs[page] = .backups
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
}

/// A page's views — the toolbar's Overview | Backups | Files on a plan's
/// page, Overview | Backups on a group's under Other backups
/// (`SidebarItem.pageTabs`): its overview; its backups, each one's files
/// beside the list; and its folders and files, each by version. The backups
/// were the sidebar's, folded under their plan, until the HIG review of
/// 2026-10-18: a sidebar shows no more than two levels.
enum PageTab: Hashable, CaseIterable {
    case overview
    case backups
    case files

    /// The View menu's words for it, the toolbar segment's own.
    var menuTitle: String {
        switch self {
        case .overview: "Overview"
        case .backups: "Backups"
        case .files: "Files"
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
    case removeRepository(UUID)
    case check(UUID)
    case prune(UUID)
    case unlock(UUID)
    case rebuildIndex(UUID)

    var id: Self { self }
}
