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

        router.request(.freeUpSpace(a))
        router.request(.freeUpSpace(b))
        #expect(router.takePendingIntent() == .freeUpSpace(b))

        for intent: AppRouter.Intent in [
            .stopPlan(plan),
            .editPlan(plan),
            .editRepository(a),
            .confirm(.deletePlan(plan)),
        ] {
            router.request(intent)
            #expect(router.takePendingIntent() == intent)
        }
        #expect(CommandConfirmation.deleteRepository(a).id == .deleteRepository(a))
    }

    @Test("Verify Backups and Clean Up land on the location's page, the only place their progress shows")
    func maintenanceShowsTheLocationPage() {
        let router = AppRouter()
        let repository = UUID()
        router.selection = .activity
        router.showMaintenance(of: repository)
        #expect(router.selection == .repository(repository))
    }

    @Test("Show in Backups opens the page's Backups tab on its backup, and its focus steers only that record's load, once")
    func showBackupOpensTheTabAndFocusesOnce() {
        let router = AppRouter()
        let repository = UUID()
        let pageID = UUID()
        let page = SidebarItem.plan(pageID)

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

        router.showBackup("s1", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        router.showBackup("s2", on: page, repositoryID: repository)
        #expect(router.backupSelection[page] == "s2")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)

        // Another page's open backup stays.
        let other = SidebarItem.plan(UUID())
        router.backupSelection[other] = "kept"
        router.showBackup("s3", on: page, repositoryID: repository, focusPath: "/D/Taxes")
        #expect(router.backupSelection[page] == "s3")
        #expect(router.backupSelection[other] == "kept")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s3") == "/D/Taxes")
    }

    @Test("the targeted asks wait in the one slot, are consumed once, and a later ask replaces an earlier one")
    func targetedIntentsWaitAndAreConsumedOnce() {
        let router = AppRouter()
        let repository = UUID()
        router.request(.editRepository(repository))
        #expect(router.pendingIntent == .editRepository(repository))
        #expect(router.takePendingIntent() == .editRepository(repository))
        #expect(router.pendingIntent == nil)
        #expect(router.takePendingIntent() == nil)

        // One slot, not a queue: the newest ask wins.
        router.request(.runSelectedPlan)
        router.request(.newPlan)
        #expect(router.takePendingIntent() == .newPlan)
    }

    @Test("every page opens on its overview, and the view chosen on one page is every page's; a route to a group's backups leaves that choice alone")
    func pageTabIsGlobal() {
        let router = AppRouter()
        let plan = SidebarItem.plan(UUID())
        let other = SidebarItem.plan(UUID())
        let group = SidebarItem.otherGroup(repositoryID: UUID(), id: .plan(UUID()))
        #expect(router.tab(of: plan) == .overview)
        #expect(router.tab(of: group) == .overview)

        router.tabBinding(for: plan).wrappedValue = .backups
        #expect(router.tab(of: plan) == .backups)
        #expect(router.tab(of: other) == .backups)
        router.tabBinding(for: plan).wrappedValue = .overview
        router.showBackup("s0", on: group, repositoryID: UUID())
        #expect(router.selection == group)
        #expect(router.backupSelection[group] == "s0")
        #expect(router.tab(of: other) == .overview)

        router.showBackup("s1", on: other, repositoryID: UUID())
        #expect(router.tab(of: plan) == .backups)

        #expect(router.tab(of: .activity) == .overview)
    }

    @Test("a plan's page offers Overview and Backups; every other page, a group's of either kind too, none")
    func pagesOfferTheirTabs() {
        let router = AppRouter()
        let repositoryID = UUID()
        let plan = SidebarItem.plan(UUID())
        #expect(plan.pageTabs == [.overview, .backups])
        let group = SidebarItem.otherGroup(repositoryID: repositoryID, id: .plan(UUID()))
        let key = SnapshotLineage.Key(hostname: "mac", paths: ["/Data/Music"])
        let lineage = SidebarItem.otherGroup(repositoryID: repositoryID, id: .lineage(key))
        #expect(lineage == .lineage(repositoryID: repositoryID, key: key))
        for page: SidebarItem in [group, lineage, .repository(repositoryID), .activity, .findFiles] {
            #expect(page.pageTabs.isEmpty)
        }
    }

    @Test("Search All Backups opens as a page from every page, its field focused, and a query handed over is kept")
    func openFindIsAPage() {
        let router = AppRouter()
        router.selection = .plan(UUID())
        router.setTab(.backups, of: .plan(UUID()))
        router.findQuery = "older"
        router.openFind()
        #expect(router.selection == .findFiles)
        #expect(router.focusesFindField)
        #expect(router.findQuery == "older")

        router.focusesFindField = false
        router.openFind(query: "invoice")
        #expect(router.findQuery == "invoice")
        #expect(router.focusesFindField)
    }


    private func revalidated(
        _ selection: SidebarItem?,
        repositories: [Repository],
        plans: [BackupPlan],
        shelves: BackupShelves = BackupShelves(listing: [], plans: [], allPlans: []),
        isResticAvailable: Bool = true
    ) -> SidebarItem? {
        AppRouter.revalidated(
            selection: selection,
            repositories: repositories,
            plans: plans,
            shelves: { _ in shelves },
            isResticAvailable: isResticAvailable
        )
    }

    @Test("a selection whose plan or repository is gone lands on the first repository's page, or Welcome when none is left")
    func gonePlanOrRepositoryLands() {
        let first = namedRepository("First")
        let second = namedRepository("Second")
        let kept = namedPlan("Documents", repositoryID: first.id)

        #expect(self.revalidated(.plan(kept.id), repositories: [first, second], plans: [kept]) == .plan(kept.id))
        #expect(self.revalidated(.repository(first.id), repositories: [first], plans: [kept]) == .repository(first.id))

        #expect(self.revalidated(.plan(UUID()), repositories: [first, second], plans: [kept]) == .repository(first.id))
        #expect(self.revalidated(.repository(UUID()), repositories: [first, second], plans: [kept]) == .repository(first.id))

        #expect(self.revalidated(.plan(UUID()), repositories: [], plans: []) == nil)
        #expect(self.revalidated(.repository(UUID()), repositories: [], plans: []) == nil)
    }

    @Test("a selected Other-backups group stays while its group is held, falls back to its repository's page, then to the landing")
    func orphanPlanRetargets() throws {
        let first = namedRepository("First")
        let second = namedRepository("Second")
        let kept = namedPlan("Kept", repositoryID: first.id)
        let moved = namedPlan("Moved", repositoryID: second.id)
        let held = BackupShelves(
            listing: [try snapshotFixture(id: "m1", time: "2026-09-30T02:00:00Z", paths: ["/Data/Music"],
                                          includeShortID: true, hostname: "mac", tags: [ResticService.planTag(moved.id)])],
            plans: [kept], allPlans: [kept, moved])

        // Adopted, moved by the editor, refreshed away — not yet: the group
        // is held, the selection stays.
        #expect(self.revalidated(.orphanPlan(repositoryID: first.id, planID: moved.id),
                                 repositories: [first, second], plans: [kept, moved], shelves: held)
            == .orphanPlan(repositoryID: first.id, planID: moved.id))

        // Gone, its repository alive: the page where the group lived — the
        // second repository's, not the landing (the first's).
        #expect(self.revalidated(.orphanPlan(repositoryID: second.id, planID: moved.id),
                                 repositories: [first, second], plans: [kept, moved])
            == .repository(second.id))

        #expect(self.revalidated(.orphanPlan(repositoryID: UUID(), planID: moved.id),
                                 repositories: [first], plans: [kept])
            == .plan(kept.id))
    }

    @Test("a selected lineage follows the same fall-back as a group")
    func lineageRetargets() throws {
        let first = namedRepository("First")
        let second = namedRepository("Second")
        let key = SnapshotLineage.Key(hostname: "old-mac", paths: ["/Data/Music"])
        let held = BackupShelves(
            listing: [try snapshotFixture(id: "x1", time: "2026-09-27T02:00:00Z", paths: ["/Data/Music"],
                                          includeShortID: true, hostname: "old-mac", tags: [])],
            plans: [], allPlans: [])

        #expect(self.revalidated(.lineage(repositoryID: first.id, key: key),
                                 repositories: [first, second], plans: [], shelves: held)
            == .lineage(repositoryID: first.id, key: key))
        #expect(self.revalidated(.lineage(repositoryID: second.id, key: key),
                                 repositories: [first, second], plans: [])
            == .repository(second.id))
        #expect(self.revalidated(.lineage(repositoryID: UUID(), key: key),
                                 repositories: [first], plans: [])
            == .repository(first.id))
    }

    @Test("Find Files stays only while repositories exist and restic is here; otherwise it lands")
    func findFilesNeedsARepositoryAndRestic() {
        let first = namedRepository("First")
        #expect(self.revalidated(.findFiles, repositories: [first], plans: []) == .findFiles)
        #expect(self.revalidated(.findFiles, repositories: [first], plans: [], isResticAvailable: false)
            == .repository(first.id))
        #expect(self.revalidated(.findFiles, repositories: [], plans: []) == nil)
    }

    @Test("Activity and no selection need no retargeting")
    func activityAndNothingStay() {
        #expect(self.revalidated(.activity, repositories: [], plans: [], isResticAvailable: false) == .activity)
        #expect(self.revalidated(nil, repositories: [], plans: [], isResticAvailable: false) == nil)
    }
}


/// The documentation links are constant literals — a typo would hide until
/// clicked. Pinned here so it hides until CI instead.
@Suite("app links")
struct AppLinksTests {
    @Test("every documentation link parses as https")
    func linksAreValid() {
        for url in [AppLinks.documentation] {
            #expect(url.scheme == "https")
            #expect(url.host()?.hasSuffix("readthedocs.io") == true)
        }
    }
}
