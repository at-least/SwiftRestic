import Foundation
import Testing

/// The router's intent slot: one ask at a time, cleared the moment it is
/// seen, replaced while unconsumed — what lets a menu command fired while
/// the window is closed survive until the window exists.
@MainActor
@Suite("app router")
struct AppRouterTests {
    @Test("request parks an intent; taking it returns and clears it")
    func requestAndTake() {
        let router = AppRouter()
        router.request(.newRepository)
        #expect(router.pendingIntent == .newRepository)
        #expect(router.takePendingIntent() == .newRepository)
        #expect(router.pendingIntent == nil)
        #expect(router.takePendingIntent() == nil)
    }

    @Test("focusing a run lands Activity on it: the tray, a notification and a problem row share one route")
    func focusRunLandsActivity() {
        let router = AppRouter()
        let run = UUID()
        router.selection = .plan(UUID())
        router.focusRun(run)
        #expect(router.selection == .activity)
        #expect(router.activityFocusRunID == run)
    }

    @Test("a second unconsumed ask replaces the first")
    func lastAskWins() {
        let router = AppRouter()
        router.request(.newPlan)
        router.request(.showFind)
        #expect(router.takePendingIntent() == .showFind)
    }

    @Test("the menus' intents carry their target, and a newer ask replaces an older one")
    func intentsCarryTheirTarget() {
        let router = AppRouter()
        let a = UUID()
        let b = UUID()
        let plan = UUID()

        router.request(.confirm(.prune(a)))
        router.request(.confirm(.prune(b)))
        #expect(router.takePendingIntent() == .confirm(.prune(b)))

        for intent: AppRouter.Intent in [
            .applyRetention(plan),
            .pauseSchedule(plan, .oneHour),
            .resumeSchedule(plan),
            .stopPlan(plan),
            .editPlan(plan),
            .editRepository(a),
            .confirm(.deletePlan(plan)),
        ] {
            router.request(intent)
            #expect(router.takePendingIntent() == intent)
        }
        #expect(AppRouter.Intent.pauseSchedule(plan, .oneHour) != .pauseSchedule(plan, .untilResumed))
        #expect(CommandConfirmation.check(a).id == .check(a))
    }

    @Test("Show in Backups opens the page's Backups tab on its backup, and its focus steers only that record's load, once")
    func showBackupOpensTheTabAndFocusesOnce() {
        let router = AppRouter()
        let repository = UUID()
        let page = SidebarItem.plan(UUID())

        router.showBackup("s1", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        #expect(router.selection == page)
        #expect(router.tab(of: page) == .backups)
        #expect(router.backupSelection[page] == "s1")
        // Another record's load finds nothing — and spends the request, so a
        // stale ask can never steer a later, unrelated load.
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s2") == nil)
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)
        router.showBackup("s1", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: UUID(), snapshotID: "s1") == nil)

        router.showBackup("s1", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)

        // A plain route afterwards clears an older focused ask.
        router.showBackup("s1", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        router.showBackup("s2", on: page, repositoryID: repository)
        #expect(router.backupSelection[page] == "s2")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)
    }

    @Test("a Files version hint is spent by the next pane that takes it, once")
    func filesVersionHintIsSpentOnce() {
        let router = AppRouter()
        #expect(router.takeFilesVersionHint() == nil)
        router.filesVersionHint = "abc"
        #expect(router.takeFilesVersionHint() == "abc")
        #expect(router.takeFilesVersionHint() == nil)
    }

    @Test("a page opens on its overview and keeps the view it was left on; each page its own, a trip to another page's backup and back included")
    func pageTabsArePerPage() {
        let router = AppRouter()
        let plan = SidebarItem.plan(UUID())
        let other = SidebarItem.plan(UUID())
        #expect(router.tab(of: plan) == .overview)

        router.tabBinding(for: plan).wrappedValue = .files
        #expect(router.tab(of: plan) == .files)
        #expect(router.tab(of: other) == .overview)

        router.selection = plan
        router.showBackup("s1", on: other, repositoryID: UUID())
        #expect(router.tab(of: other) == .backups)
        router.selection = plan
        #expect(router.tab(of: plan) == .files)

        router.setTab(.overview, of: plan)
        #expect(router.tab(of: plan) == .overview)
    }

    @Test("a plan's page offers Overview, Backups and Files; a group's, either kind, Overview and Backups; every other page none")
    func pagesOfferTheirTabs() {
        let router = AppRouter()
        let repositoryID = UUID()
        let plan = SidebarItem.plan(UUID())
        #expect(plan.pageTabs == [.overview, .backups, .files])
        let group = SidebarItem.otherGroup(repositoryID: repositoryID, id: .plan(UUID()))
        let key = SnapshotLineage.Key(hostname: "mac", paths: ["/Data/Music"])
        let lineage = SidebarItem.otherGroup(repositoryID: repositoryID, id: .lineage(key))
        #expect(lineage == .lineage(repositoryID: repositoryID, key: key))
        for page in [group, lineage] {
            #expect(page.pageTabs == [.overview, .backups])
            #expect(page.hasPageTabs)
            router.tabBinding(for: page).wrappedValue = .backups
            #expect(router.tab(of: page) == .backups)
        }
        for page: SidebarItem in [.repository(repositoryID), .activity, .console, .findFiles] {
            #expect(page.pageTabs.isEmpty)
            #expect(!page.hasPageTabs)
        }
    }

    @Test("⇧⌘F on a page turns it to its Files tab and asks that page's toolbar field, and no other, for the focus")
    func searchFilesFocusesThePagesField() {
        let router = AppRouter()
        let page = SidebarItem.plan(UUID())
        router.selection = page
        router.searchFiles(on: page)
        #expect(router.tab(of: page) == .files)
        #expect(router.selection == page)
        #expect(router.searchFocus == page)
    }

    @Test("Find Files opens as a page on its repository, its field focused, a handed-over search kept and run on arrival")
    func openFindIsAPage() {
        let router = AppRouter()
        let repository = UUID()
        router.findQuery = "older"
        router.openFind(repositoryID: repository)
        #expect(router.selection == .findFiles)
        #expect(router.findRepositoryID == repository)
        #expect(router.searchFocus == .findFiles)
        // ⇧⌘F keeps what was typed; nothing runs until asked.
        #expect(router.findQuery == "older")
        #expect(!router.findRunsOnArrival)

        // Search All Backups… hands its query over and asks for the run.
        router.openFind(repositoryID: repository, query: "invoice", run: true)
        #expect(router.findQuery == "invoice")
        #expect(router.findRunsOnArrival)
    }

    @Test("a search's hit opens the folders above it down from the deepest top holding it, and a whole-disk top ends the walk")
    func openFoldersAboveAHit() {
        let repositoryID = UUID()
        let chain = "swiftrestic-plan-aaaa"
        func node(_ path: String, folder: Bool = true) -> FileNode {
            FileNode(repositoryID: repositoryID, chainKey: chain, path: path, isDirectory: folder)
        }
        let router = AppRouter()
        router.openFolders(above: node("/Data/Photos/2026/Trip/beach.jpg", folder: false), from: ["/Data", "/Data/Photos/2026"])
        #expect(router.openFolders == [node("/Data/Photos/2026"), node("/Data/Photos/2026/Trip")])

        // The root is its own parent: a backup of the whole disk opens down
        // to it and stops.
        let disk = AppRouter()
        disk.openFolders(above: node("/Users/x.txt", folder: false), from: ["/"])
        #expect(disk.openFolders == [node("/"), node("/Users")])

        // A top itself, and a path no top holds — bytes, not a string
        // prefix — open nothing.
        let none = AppRouter()
        none.openFolders(above: node("/Data"), from: ["/Data"])
        none.openFolders(above: node("/Data2/x.txt", folder: false), from: ["/Data"])
        #expect(none.openFolders.isEmpty)
    }

}


/// The documentation links are constant literals — a typo would hide until
/// clicked. Pinned here so it hides until CI instead.
@Suite("app links")
struct AppLinksTests {
    @Test("every documentation link parses as https")
    func linksAreValid() {
        for url in [AppLinks.documentation, AppLinks.changelog] {
            #expect(url.scheme == "https")
            #expect(url.host()?.hasSuffix("readthedocs.io") == true)
        }
    }
}
