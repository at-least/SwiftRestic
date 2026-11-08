import Foundation
import Testing

/// The Plan and Repository menus' state for the sidebar selection: which
/// items are enabled, what the two toggles are titled, and what each
/// confirmation says. Derived from the model on every read, so the menu
/// bar, the sidebar's menus and the panes cannot disagree.
@MainActor
@Suite("menu command state")
struct CommandStateTests {
    private let suiteName = "SwiftResticCommandStateTests"

    private func makeModel(resticAvailable: Bool = true) -> AppModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            store: ConfigStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CommandStateTests-\(UUID().uuidString)")),
            secrets: .inMemory(),
            defaults: defaults
        )
        if resticAvailable {
            // Never run: the state only asks whether restic was found.
            model.resticState = .ready(ResticBinary(url: URL(fileURLWithPath: "/usr/bin/false")), version: "")
        }
        return model
    }

    private func makeRepository(_ name: String = "NAS") -> Repository {
        namedRepository(name)
    }

    private func makePlan(_ name: String = "Docs", on repository: Repository?) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repository?.id
        // A plan is called by its path's last component: the name ends it.
        plan.path = "/tmp/" + name
        plan.schedule.frequency = .daily
        return plan
    }

    @Test("once restic has finished copying, the backup's numbers leave the progress bar: they would stand still through the steps after it")
    func progressClearsAfterCopying() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents]
        model.activity[documents.id] = PlanActivity(of: documents, phase: .backingUp)
        var midway = OperationProgress()
        midway.fraction = 0.97
        model.planProgress[documents.id] = midway

        model.setActivityPhase(.backingUp, for: documents.id)
        #expect(model.planProgress[documents.id]?.fraction == 0.97)

        for phase in [PlanActivity.Phase.applyingRetention, .runningHooks, .notifying] {
            model.planProgress[documents.id] = midway
            model.setActivityPhase(phase, for: documents.id)
            #expect(model.planProgress[documents.id] == nil, "phase \(phase)")
        }
    }

    @Test("Back Up Now waits for a prune, a check or another plan's retention on its repository — restic would refuse its lock")
    func backUpWaitsForExclusiveWork() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        #expect(model.planCommands(for: .plan(documents.id)).canBackUp)
        #expect(model.backupLockReason(for: documents) == nil)

        model.maintenance[repository.id] = MaintenanceActivity(task: .prune)
        #expect(!model.planCommands(for: .plan(documents.id)).canBackUp)
        #expect(!model.planCommands(for: nil).canBackUpAll)
        #expect(model.backupLockReason(for: documents) == "“Home NAS” is running a cleanup — backups wait until it finishes.")
        model.maintenance[repository.id] = MaintenanceActivity(task: .check)
        #expect(model.backupLockReason(for: documents) == "“Home NAS” is running a verification — backups wait until it finishes.")
        model.maintenance = [:]

        // Another plan's backup shares the lock; its retention step does not.
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        #expect(model.planCommands(for: .plan(documents.id)).canBackUp)
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        model.setActivityPhase(.applyingRetention, for: photos.id)
        #expect(!model.planCommands(for: .plan(documents.id)).canBackUp)
        #expect(model.backupLockReason(for: documents)
            == "“Home NAS” is removing old backups of “Photos”. Backups wait until it finishes.")
    }

    @Test("a removed plan's stopping run keeps its repository's backups waiting until it unwinds")
    func removedPlansRunKeepsTheLock() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        model.setActivityPhase(.applyingRetention, for: photos.id)
        // Remove Plan takes the plan at once; the forget's restic child still
        // holds the lock while it dies.
        model.configuration.plans = [documents]
        #expect(model.plan(id: photos.id) == nil)
        #expect(model.backupLockReason(for: documents)
            == "“Home NAS” is removing old backups of “Photos”. Backups wait until it finishes.")
        #expect(!model.planCommands(for: .plan(documents.id)).canBackUp)
        #expect(model.busyRepositoryIDs == [repository.id])
        model.activity[photos.id] = nil
        #expect(model.backupLockReason(for: documents) == nil)
        #expect(model.busyRepositoryIDs.isEmpty)
    }

    @Test("a phase the engine writes after Stop keeps the strip stopping")
    func stopOutlivesLaterPhases() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        model.activity[photos.id] = PlanActivity(of: photos, phase: .starting)
        model.cancelBackup(planID: photos.id)
        model.setActivityPhase(.backingUp, for: photos.id)
        #expect(model.activity[photos.id]?.phase == .cancelling)
        // A forget launched after the Stop still takes the lock until its
        // child dies.
        model.setActivityPhase(.applyingRetention, for: photos.id)
        #expect(model.activity[photos.id]?.phase == .cancelling)
        #expect(model.backupLockReason(for: documents)
            == "“Home NAS” is removing old backups of “Photos”. Backups wait until it finishes.")
    }

    @Test("the lock reason names a running plan as the sidebar does, after a rename too")
    func lockReasonFollowsARename() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        model.setActivityPhase(.applyingRetention, for: photos.id)
        model.configuration.plans[1].path = "/tmp/Pictures"
        #expect(model.backupLockReason(for: documents)
            == "“Home NAS” is removing old backups of “Pictures”. Backups wait until it finishes.")
    }

    @Test("a backup stopped in its forget keeps the repository's backups waiting; after the forget it no longer does")
    func stoppedBackupInItsForgetKeepsTheLock() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        let reason = "“Home NAS” is removing old backups of “Photos”. Backups wait until it finishes."
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        // The engine's own phase writes, as the backup moves on.
        model.setActivityPhase(.applyingRetention, for: photos.id)
        #expect(model.backupLockReason(for: documents) == reason)
        model.cancelBackup(planID: photos.id)
        #expect(model.activity[photos.id]?.phase == .cancelling)
        #expect(model.backupLockReason(for: documents) == reason)
        model.endRetentionStep(for: photos.id)
        #expect(model.backupLockReason(for: documents) == nil)
        #expect(model.activity[photos.id]?.phase == .cancelling, "Stop's word stays on the strip")
    }

    @Test("a run nobody asked for — a mount's or the network's catch-up — waits for a check or prune without a banner")
    func unaskedRunWaitsSilently() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents]
        model.maintenance[repository.id] = MaintenanceActivity(task: .prune)

        model.runBackup(planID: documents.id, askedByUser: false)
        #expect(model.banners.isEmpty)
        #expect(!model.isRunning(planID: documents.id))

        model.runBackup(planID: documents.id)
        #expect(model.banners.map(\.title) == ["“Documents” waits"])
        #expect(!model.isRunning(planID: documents.id))
    }

    @Test("Verify or Clean Up Now on a location a backup is using says it is busy and starts nothing")
    func maintenanceOnABusyLocationIsAnswered() {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents]
        model.activity[documents.id] = PlanActivity(of: documents, phase: .backingUp)

        model.runMaintenance(repositoryID: repository.id, task: .check)
        #expect(model.banners.map(\.title) == ["“Home NAS” is busy"])
        #expect(model.maintenance[repository.id] == nil, "a check started beside the running backup")
    }

    @Test("a Back Up Now that waited its turn starts when the run ahead ends, though Pause Backups came meanwhile")
    func askedForQueuedBackupStartsUnderAPause() async {
        let model = makeModel()
        let repository = makeRepository("Home NAS")
        let documents = makePlan("Documents", on: repository)
        let photos = makePlan("Photos", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [documents, photos]
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)

        model.runBackups(planIDs: [documents.id])
        #expect(model.isQueued(documents.id))
        model.pauseBackups(for: .untilResumed)
        model.unwindPlanRun(photos.id)

        #expect(model.isRunning(planID: documents.id), "the backup the user asked for was dropped by the pause")
        await model.waitForRun(planID: documents.id)
    }

    @Test("a check whose server was out of reach is not started by the tick until the network changes")
    func upkeepWaitsForAnAwayServer() async throws {
        let model = makeModel()
        var repository = Repository()
        repository.kind = .rest
        repository.restURL = "http://127.0.0.1:9/app"
        // Added long ago and never checked: its check is due.
        repository.createdAt = .now.addingTimeInterval(-90 * 86400)
        model.configuration.repositories = [repository]
        try #require(Scheduler.dueMaintenance(in: [repository], plans: []).first?.task == .check)
        model.maintenanceAwaitingServer.insert(repository.id)

        await model.runDuePlans()
        #expect(model.maintenance[repository.id] == nil, "the tick started a check against a server known to be out of reach")
        await model.tasks.drain()
    }

    @Test("a skipped check is answered in a banner when the user asked for it; a scheduled one stays quiet")
    func skippedCheckBannerOnlyWhenAsked() async {
        let model = makeModel()
        let repository = makeRepository("NAS")
        model.configuration.repositories = [repository]
        var record = RunRecord(kind: .check, planName: "NAS", repositoryID: repository.id)
        record.outcome = .skipped
        record.detailText = "“NAS” isn’t connected."

        model.maintenance[repository.id] = MaintenanceActivity(task: .check, askedByUser: false)
        await model.deliver(record: record, repository: repository, transcript: RunTranscript().contents)
        #expect(model.banners.isEmpty, "the scheduler's skip posted \(model.banners.map(\.title))")

        model.maintenance[repository.id] = MaintenanceActivity(task: .check, askedByUser: true)
        await model.deliver(record: record, repository: repository, transcript: RunTranscript().contents)
        #expect(model.banners.map(\.title) == ["\(RunRecord.Kind.check.displayName) of “NAS” skipped"])
        #expect(model.banners.first?.message == "“NAS” isn’t connected.")
    }

    @Test("Back Up Now on a plan without a repository posts the banner and starts nothing")
    func incompletePlanBackUpIsAnswered() {
        let model = makeModel()
        let draft = makePlan("Draft", on: nil)
        model.configuration.plans = [draft]

        model.runBackup(planID: draft.id)
        #expect(model.banners.map(\.title) == ["Plan is incomplete"])
        #expect(model.activity.isEmpty)
    }

    @Test("Back Up All queues a plan behind another plan's run on its repository, its retention step too, and leaves out one whose repository a check or prune holds")
    func backUpAllQueuesBehindAPlansRun() {
        let model = makeModel()
        let home = makeRepository("Home NAS")
        let offsite = makeRepository("Offsite")
        let documents = makePlan("Documents", on: home)
        let photos = makePlan("Photos", on: home)
        let music = makePlan("Music", on: offsite)
        model.configuration.repositories = [home, offsite]
        model.configuration.plans = [documents, photos, music]
        // Photos' run is past its backup, in the forget — with a prune, for
        // minutes. Its unwind starts the next plan in Home NAS's queue.
        model.activity[photos.id] = PlanActivity(of: photos, phase: .backingUp)
        model.setActivityPhase(.applyingRetention, for: photos.id)
        // Offsite's check holds it exclusively, and no plan's run ends there
        // to start a plan that waited for it.
        model.maintenance[offsite.id] = MaintenanceActivity(task: .check)

        model.backUpAllPlans()
        #expect(model.isQueued(documents.id), "Documents waits for Photos' run, as it does while Photos backs up")
        #expect(!model.isRunning(planID: documents.id))
        #expect(!model.isQueued(music.id))
        #expect(!model.isRunning(planID: music.id))

        // A deleted plan leaves its queue: adopting its backups again brings
        // back the same ID, which a stale entry would start.
        model.deletePlan(id: documents.id)
        #expect(!model.isQueued(documents.id))
    }

    @Test("excluding unreadable items adds each exact path to the plan once, glob characters escaped")
    func excludeItemAddsItsPath() {
        let model = makeModel()
        let repository = makeRepository()
        var plan = makePlan(on: repository)
        plan.excludePatterns = [".DS_Store"]
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        model.exclude(paths: ["/Users/u/Taxes/a[1].pdf"], fromPlan: plan.id)
        #expect(model.plan(id: plan.id)?.excludePatterns == [".DS_Store", "/Users/u/Taxes/a\\[1].pdf"])
        model.exclude(paths: ["/Users/u/Taxes/a[1].pdf"], fromPlan: plan.id)
        #expect(model.plan(id: plan.id)?.excludePatterns.count == 2)
        model.exclude(paths: ["/Users/u/b?.txt", "/Users/u/Taxes/a[1].pdf", "/Users/u/c", "/Users/u/b?.txt"], fromPlan: plan.id)
        #expect(model.plan(id: plan.id)?.excludePatterns
            == [".DS_Store", "/Users/u/Taxes/a\\[1].pdf", "/Users/u/b\\?.txt", "/Users/u/c"])
        #expect(model.plan(id: plan.id)?.path == plan.path)
    }

    @Test("the Plan menu acts on the selected plan, and on nothing else")
    func planCommandsFollowTheSelection() {
        let model = makeModel()
        let repository = makeRepository()
        var plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        for selection: SidebarItem? in [nil, .activity,
                                         .orphanPlan(repositoryID: repository.id, planID: UUID())] {
            let state = model.planCommands(for: selection)
            #expect(state.planID == nil, "selection \(String(describing: selection))")
            #expect(!state.canBackUp && !state.canStop && !state.canEdit)
            #expect(!state.canDelete)
            #expect(state.stopTitle == "Stop Backup")
            // Back Up All Plans Now is not about the selection.
            #expect(state.canBackUpAll)
        }
        #expect(model.planCommands(for: .plan(UUID())).planID == nil)

        let idle = model.planCommands(for: .plan(plan.id))
        #expect(idle.planID == plan.id)
        #expect(idle.canBackUp && idle.canEdit && idle.canDelete)
        #expect(!idle.canStop)
    }

    @Test("Stop follows the plan's run and says which work it stops")
    func stopFollowsTheRunAndItsPhase() {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        model.activity[plan.id] = PlanActivity(of: plan)
        let running = model.planCommands(for: .plan(plan.id))
        #expect(running.canStop)
        #expect(!running.canBackUp)
        #expect(running.stopTitle == "Stop Backup")

        model.activity[plan.id]?.phase = .applyingRetention
        let retention = model.planCommands(for: .plan(plan.id))
        #expect(retention.canStop)
        #expect(retention.stopTitle == "Stop Removing Old Backups")

        // A stop already asked for: a second one would promise nothing new.
        model.activity[plan.id]?.phase = .cancelling
        let cancelling = model.planCommands(for: .plan(plan.id))
        #expect(!cancelling.canStop)
        #expect(!cancelling.canBackUp)
    }

    @Test("the tray and the Plan menu word a retention run's Stop by one rule")
    func trayAndMenuShareTheStopRule() {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        func trayRow() -> MenuBarStatus.PlanRow? {
            MenuBarStatus.planRows(plans: model.configuration.plans, activity: model.activity, isResticDamaged: false).first
        }

        model.activity[plan.id] = PlanActivity(of: plan, phase: .backingUp)
        #expect(trayRow()?.title == "Stop “Docs” Backup")
        #expect(model.planCommands(for: .plan(plan.id)).stopTitle == "Stop Backup")

        // A backup's own retention step (its snapshot is already written):
        // Stop ends the forget, and both
        // surfaces say so.
        model.activity[plan.id]?.phase = .applyingRetention
        #expect(trayRow()?.title == "Stop Removing Old Backups of “Docs”")
        #expect(trayRow()?.action == .stop)
        #expect(model.planCommands(for: .plan(plan.id)).stopTitle == "Stop Removing Old Backups")
    }

    @Test("without restic only restic's work is disabled")
    func resticMissingDisablesOnlyResticWork() {
        let model = makeModel(resticAvailable: false)
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        let state = model.planCommands(for: .plan(plan.id))
        #expect(!state.canBackUp)
        #expect(!state.canBackUpAll)
        #expect(state.canEdit && state.canDelete)

        let repositoryState = model.repositoryCommands(for: .repository(repository.id))
        #expect(!repositoryState.canMaintain)
        #expect(!repositoryState.canFind)
        #expect(!repositoryState.canRefreshAll)
        #expect(!repositoryState.canOpenConsole)
        #expect(repositoryState.canEdit && repositoryState.canRemove)
    }

    @Test("Back Up All Plans Now needs a complete, idle plan and restic")
    func backUpAllNeedsAnIdleCompletePlan() {
        let model = makeModel()
        #expect(!model.planCommands(for: nil).canBackUpAll)

        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        #expect(model.planCommands(for: nil).canBackUpAll)

        model.activity[plan.id] = PlanActivity(of: plan)
        #expect(!model.planCommands(for: nil).canBackUpAll)
        model.activity[plan.id] = nil

        var incomplete = plan
        incomplete.path = ""
        model.configuration.plans = [incomplete]
        #expect(!model.planCommands(for: nil).canBackUpAll)
    }

    @Test("the Repository menu acts on the selected repository, a record's, or the selected plan's")
    func repositoryTargetFollowsTheSelection() {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        let orphan = makePlan("Orphan", on: makeRepository("Gone"))
        let unset = makePlan("Unset", on: nil)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan, orphan, unset]

        #expect(model.commandRepositoryID(for: .repository(repository.id)) == repository.id)
        #expect(model.commandRepositoryID(for: .plan(plan.id)) == repository.id)
        #expect(model.commandRepositoryID(for: .plan(orphan.id)) == nil)
        #expect(model.commandRepositoryID(for: .plan(unset.id)) == nil)
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: repository.id, planID: orphan.id)) == repository.id)
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: repository.id, planID: UUID())) == repository.id)
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: UUID(), planID: orphan.id)) == nil)
        let lineage = SnapshotLineage.Key(hostname: "studio", paths: ["/Data/Music"])
        #expect(model.commandRepositoryID(for: .lineage(repositoryID: repository.id, key: lineage)) == repository.id)
        #expect(model.commandRepositoryID(for: .lineage(repositoryID: UUID(), key: lineage)) == nil)
        #expect(model.planCommands(for: .lineage(repositoryID: repository.id, key: lineage)).planID == nil)
        #expect(model.commandRepositoryID(for: .repository(UUID())) == nil)
        for selection: SidebarItem? in [.activity, nil] {
            #expect(model.commandRepositoryID(for: selection) == nil)
        }

        let viaPlan = model.repositoryCommands(for: .plan(plan.id))
        #expect(viaPlan.repositoryID == repository.id)
        #expect(viaPlan.canMaintain && viaPlan.canEdit && viaPlan.canRemove)
        let viaGroup = model.repositoryCommands(for: .orphanPlan(repositoryID: repository.id, planID: orphan.id))
        #expect(viaGroup.repositoryID == repository.id)
        #expect(viaGroup.canMaintain && viaGroup.canEdit && viaGroup.canRemove)
        let nothing = model.repositoryCommands(for: .activity)
        #expect(nothing.repositoryID == nil)
        #expect(!nothing.canMaintain && !nothing.canEdit && !nothing.canRemove)
        // Find, Refresh All and the console are about every repository,
        // not the selection.
        #expect(nothing.canFind && nothing.canRefreshAll && nothing.canOpenConsole)
        model.configuration.repositories = []
        #expect(!model.repositoryCommands(for: nil).canFind)
        #expect(!model.repositoryCommands(for: nil).canRefreshAll)
        #expect(!model.repositoryCommands(for: nil).canOpenConsole)
    }

    @Test("⇧⌘F searches the Files tab of a plan's page, and Find Files everywhere else — a group's page too")
    func filesSearchRootsFollowThePage() throws {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        let homeless = makePlan("Homeless", on: nil)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan, homeless]
        let deleted = UUID()
        let tagged = try IndexTestData.snapshot(
            IndexTestData.hexID(1), micros: 1_000_000, tags: [ResticService.planTag(deleted)], paths: ["/Data"])
        let untagged = try IndexTestData.snapshot(IndexTestData.hexID(2), micros: 2_000_000, paths: ["/Music"])
        model.snapshots[repository.id] = [untagged, tagged]

        #expect(model.filesSearchRoots(for: .plan(plan.id))
            == FileNode.roots(repositoryID: repository.id, chainKey: ResticService.planTag(plan.id)))
        for selection: SidebarItem? in [
            .plan(homeless.id), .orphanPlan(repositoryID: repository.id, planID: deleted),
            .lineage(repositoryID: repository.id, key: untagged.lineageKey),
            .repository(repository.id), .activity, nil,
        ] {
            #expect(model.filesSearchRoots(for: selection) == nil, "selection \(String(describing: selection))")
        }
    }

    @Test("a backup's page is its plan's, or its group's under Other backups, and none once the listing drops it")
    func backupPageFollowsTheShelf() throws {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        let own = try IndexTestData.snapshot(
            IndexTestData.hexID(1), micros: 1_000_000, tags: [ResticService.planTag(plan.id)], paths: ["/Data"])
        let deleted = UUID()
        let orphan = try IndexTestData.snapshot(
            IndexTestData.hexID(2), micros: 2_000_000, tags: [ResticService.planTag(deleted)], paths: ["/Data"])
        let untagged = try IndexTestData.snapshot(IndexTestData.hexID(3), micros: 3_000_000, paths: ["/Music"])
        model.snapshots[repository.id] = [untagged, orphan, own]

        // Where a run's Browse and a Files tab's Show in Backups land: the
        // one page whose Backups tab lists it.
        #expect(model.page(ofBackup: own.id, in: repository.id) == .plan(plan.id))
        #expect(model.page(ofBackup: orphan.id, in: repository.id) == .orphanPlan(repositoryID: repository.id, planID: deleted))
        #expect(model.page(ofBackup: untagged.id, in: repository.id) == .lineage(repositoryID: repository.id, key: untagged.lineageKey))
        #expect(model.page(ofBackup: IndexTestData.hexID(9), in: repository.id) == nil)
    }

    @Test("a busy repository holds maintenance and retention back, never its removal")
    func busyRepositoryBlocksMaintenanceAndRetentionNotRemoval() {
        let model = makeModel()
        let repository = makeRepository()
        let planA = makePlan("A", on: repository)
        let planB = makePlan("B", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [planA, planB]

        model.maintenance[repository.id] = MaintenanceActivity(task: .check)
        let maintaining = model.repositoryCommands(for: .repository(repository.id))
        #expect(!maintaining.canMaintain)
        #expect(maintaining.canEdit && maintaining.canRemove)

        model.maintenance[repository.id] = nil
        model.activity[planB.id] = PlanActivity(of: planB)
        #expect(!model.repositoryCommands(for: .plan(planA.id)).canMaintain)
        model.activity[planB.id] = nil

        let unset = makePlan("Unset", on: nil)
        model.configuration.plans = [unset]
        #expect(!model.planCommands(for: .plan(unset.id)).canBackUp)
        #expect(model.planCommands(for: .plan(unset.id)).backUpDisabledReason
            == "This plan needs a backup location and a folder or file to back up")
    }

    @Test("the app-wide pause items follow the tray's rules")
    func appWidePauseFollowsTheTray() {
        let model = makeModel()
        #expect(!model.planCommands(for: nil).canPauseBackups)

        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        let idle = model.planCommands(for: nil)
        #expect(idle.canPauseBackups && !idle.backupsPaused)

        model.pauseBackups(for: .untilResumed)
        let paused = model.planCommands(for: nil)
        #expect(paused.backupsPaused)
        #expect(!paused.canPauseBackups)
        model.resumeBackups()
        #expect(!model.planCommands(for: nil).backupsPaused)

        // A metered network's hold still offers a pause that outlasts it.
        model.isOnMeteredNetwork = true
        let metered = model.planCommands(for: nil)
        #expect(!metered.backupsPaused && metered.canPauseBackups)
    }

    @Test("every confirmation names its target, and a gone target asks nothing")
    func confirmationCopyNamesItsTarget() {
        let model = makeModel()
        let repository = makeRepository("NAS")
        let plan = makePlan("Docs", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.title == "Remove “Docs”?")
        #expect(model.confirmationCopy(for: .prune(repository.id))?.title == "Clean up “NAS” now?")
        #expect(model.confirmationCopy(for: .check(repository.id))?.title == "Verify “NAS”?")
        #expect(model.confirmationCopy(for: .deleteRepository(repository.id))?.title
            == "Remove “NAS” from SwiftRestic?")

        let stopping = "will be stopped"
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message.contains(stopping) == false)
        model.activity[plan.id] = PlanActivity(of: plan)
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message.contains(stopping) == true)
        #expect(model.confirmationCopy(for: .deleteRepository(repository.id))?.message
            == model.removalConsequences(for: repository.id))
        model.activity[plan.id] = nil

        // The check dialog says which size of slow the user is holding.
        #expect(model.confirmationCopy(for: .check(repository.id))?.message.contains("It holds") == false)
        model.repositoryStats[repository.id] = RepositoryStats(totalSize: 2_000_000)
        #expect(model.confirmationCopy(for: .check(repository.id))?.message
            .contains("It holds \(Format.bytes(2_000_000)).") == true)

        // A plan is called by its folder; one with no path yet has nothing
        // to be called.
        var pathless = plan
        pathless.path = ""
        model.configuration.plans = [pathless]
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.title == "Remove “Untitled Plan”?")

        #expect(model.confirmationCopy(for: .deletePlan(UUID())) == nil)
        #expect(model.confirmationCopy(for: .prune(UUID())) == nil)
    }

}
