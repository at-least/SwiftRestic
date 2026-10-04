import Foundation
import Testing

/// The router's intent slot: one ask at a time, cleared the moment it is
/// seen, replaced while unconsumed. These rules are what let a menu command
/// fired while the window is closed survive until the window exists — the
/// property the old `pendingNewRepository` flag had and the notification
/// seam lacked.
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

    @Test("a Show in Restore focus steers only its own record's load, and only once")
    func restoreFocusIsForItsRecordOnlyAndOnce() {
        let router = AppRouter()
        let repository = UUID()

        router.showRestore(repositoryID: repository, snapshotID: "s1", focusPath: "/D/Taxes")
        #expect(router.selection == .restoreSnapshot(repository, "s1"))
        // Another record's load finds nothing — and spends the request, so a
        // stale ask can never steer a later, unrelated load.
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s2") == nil)
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)
        // Nor does the same snapshot ID under another repository.
        router.showRestore(repositoryID: repository, snapshotID: "s1", focusPath: "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: UUID(), snapshotID: "s1") == nil)

        router.showRestore(repositoryID: repository, snapshotID: "s1", focusPath: "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == "/D/Taxes")
        #expect(router.takeRestoreFocus(repositoryID: repository, snapshotID: "s1") == nil)

        // A plain route afterwards clears an older focused ask.
        router.showRestore(repositoryID: repository, snapshotID: "s1", focusPath: "/D/Taxes")
        router.showRestore(repositoryID: repository, snapshotID: "s1")
        #expect(router.selection == .restoreSnapshot(repository, "s1"))
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

    @Test("a page opens on its overview and keeps the view it was left on; each page its own, a trip to a backup and back included")
    func pageTabsArePerPage() {
        let router = AppRouter()
        let plan = SidebarItem.plan(UUID())
        let other = SidebarItem.plan(UUID())
        #expect(router.tab(of: plan) == .overview)

        router.tabBinding(for: plan).wrappedValue = .files
        #expect(router.tab(of: plan) == .files)
        #expect(router.tab(of: other) == .overview)

        router.selection = plan
        router.showRestore(repositoryID: UUID(), snapshotID: "s1")
        router.selection = plan
        #expect(router.tab(of: plan) == .files)

        router.setTab(.overview, of: plan)
        #expect(router.tab(of: plan) == .overview)
    }

    @Test("a group's Show Files lands on its page's Files tab, either kind of group")
    func showFilesOpensThePageOnFiles() throws {
        let router = AppRouter()
        let repositoryID = UUID()
        let group = SidebarItem.otherGroup(repositoryID: repositoryID, id: .plan(UUID()))
        router.showFiles(of: group)
        #expect(router.selection == group)
        #expect(router.tab(of: group) == .files)

        let key = SnapshotLineage.Key(hostname: "mac", paths: ["/Data/Music"])
        let lineage = SidebarItem.otherGroup(repositoryID: repositoryID, id: .lineage(key))
        #expect(lineage == .lineage(repositoryID: repositoryID, key: key))
        #expect(router.tab(of: lineage) == .overview)
        router.showFiles(of: lineage)
        #expect(router.selection == lineage)
        #expect(router.tab(of: lineage) == .files)
        #expect(router.tab(of: group) == .files)
    }

}


/// The documentation links are constant literals — which is exactly why a
/// typo would hide until clicked. Pin them here so it hides until CI.
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
