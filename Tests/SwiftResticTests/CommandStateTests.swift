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
            model.binary = ResticBinary(url: URL(fileURLWithPath: "/usr/bin/false"), version: "restic 0.19.1")
        }
        return model
    }

    private func makeRepository(_ name: String = "NAS") -> Repository {
        var repository = Repository()
        repository.name = name
        repository.kind = .local
        repository.localPath = "/tmp/command-state-repo"
        return repository
    }

    private func makePlan(_ name: String = "Docs", on repository: Repository?) -> BackupPlan {
        var plan = BackupPlan()
        plan.name = name
        plan.repositoryID = repository?.id
        plan.sources = ["/tmp/command-state-source"]
        plan.schedule.frequency = .daily
        return plan
    }

    @Test("the Plan menu acts on the selected plan, and on nothing else")
    func planCommandsFollowTheSelection() {
        let model = makeModel()
        let repository = makeRepository()
        var plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        for selection: SidebarItem? in [nil, .activity, .console, .repository(repository.id),
                                         .orphanPlan(repositoryID: repository.id, planID: UUID())] {
            let state = model.planCommands(for: selection)
            #expect(state.planID == nil, "selection \(String(describing: selection))")
            #expect(!state.canBackUp && !state.canStop && !state.canEdit && !state.canToggleSchedule)
            #expect(!state.canApplyRetention && !state.canDelete)
            #expect(state.scheduleTitle == "Pause Schedule")
            #expect(state.stopTitle == "Stop Backup")
            // Back Up All Plans Now is not about the selection.
            #expect(state.canBackUpAll)
        }
        // A plan deleted since the selection was made is nothing to act on.
        #expect(model.planCommands(for: .plan(UUID())).planID == nil)

        let idle = model.planCommands(for: .plan(plan.id))
        #expect(idle.planID == plan.id)
        #expect(idle.canBackUp && idle.canEdit && idle.canToggleSchedule && idle.canApplyRetention && idle.canDelete)
        #expect(idle.retentionBlocker == nil)
        #expect(!idle.canStop)
        #expect(idle.scheduleTitle == "Pause Schedule")
        #expect(idle.isScheduleActive)

        // Both kinds of pause read Resume: switched off, and a timed pause
        // still running — isScheduleActive(at:) is the one predicate.
        plan.isEnabled = false
        model.configuration.plans = [plan]
        let off = model.planCommands(for: .plan(plan.id))
        #expect(off.scheduleTitle == "Resume Schedule")
        #expect(!off.isScheduleActive)
        #expect(off.canToggleSchedule)

        plan.isEnabled = true
        plan.pausedUntil = .now.addingTimeInterval(3600)
        model.configuration.plans = [plan]
        let timed = model.planCommands(for: .plan(plan.id))
        #expect(timed.scheduleTitle == "Resume Schedule")
        #expect(!timed.isScheduleActive)
        #expect(timed.canToggleSchedule)

        // A timed pause that has run out is no pause.
        plan.pausedUntil = .now.addingTimeInterval(-60)
        model.configuration.plans = [plan]
        #expect(model.planCommands(for: .plan(plan.id)).scheduleTitle == "Pause Schedule")

        // A manual plan has no schedule to pause; switched off, its Resume
        // is the editor's switch and stays offered.
        plan.pausedUntil = nil
        plan.schedule.frequency = .manual
        model.configuration.plans = [plan]
        let manual = model.planCommands(for: .plan(plan.id))
        #expect(manual.scheduleTitle == "Pause Schedule")
        #expect(!manual.canToggleSchedule)
        plan.isEnabled = false
        model.configuration.plans = [plan]
        let manualOff = model.planCommands(for: .plan(plan.id))
        #expect(manualOff.scheduleTitle == "Resume Schedule")
        #expect(manualOff.canToggleSchedule)
    }

    @Test("Stop follows the plan's run and says which work it stops")
    func stopFollowsTheRunAndItsPhase() {
        let model = makeModel()
        let repository = makeRepository()
        let plan = makePlan(on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        model.activity[plan.id] = PlanActivity()
        let running = model.planCommands(for: .plan(plan.id))
        #expect(running.canStop)
        #expect(!running.canBackUp)
        #expect(running.stopTitle == "Stop Backup")

        model.activity[plan.id]?.phase = .applyingRetention
        let retention = model.planCommands(for: .plan(plan.id))
        #expect(retention.canStop)
        #expect(retention.stopTitle == "Stop Applying Retention")

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
            MenuBarStatus.planRows(plans: model.configuration.plans, activity: model.activity, isResticAvailable: true).first
        }

        model.activity[plan.id] = PlanActivity(phase: .backingUp)
        #expect(trayRow()?.title == "Stop “Docs” Backup")
        #expect(model.planCommands(for: .plan(plan.id)).stopTitle == "Stop Backup")

        // Apply Retention Now…'s forget, or a backup's own retention step
        // (its snapshot is already written): Stop ends the forget, and both
        // surfaces say so.
        model.activity[plan.id]?.phase = .applyingRetention
        #expect(trayRow()?.title == "Stop Applying Retention to “Docs”")
        #expect(trayRow()?.action == .stop)
        #expect(model.planCommands(for: .plan(plan.id)).stopTitle == "Stop Applying Retention")
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
        #expect(!state.canApplyRetention)
        #expect(state.retentionBlocker == "restic is missing.")
        #expect(state.canEdit && state.canDelete && state.canToggleSchedule)

        let repositoryState = model.repositoryCommands(for: .repository(repository.id))
        #expect(!repositoryState.canMaintain)
        #expect(!repositoryState.canFind)
        #expect(!repositoryState.canRefreshAll)
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

        model.activity[plan.id] = PlanActivity()
        #expect(!model.planCommands(for: nil).canBackUpAll)
        model.activity[plan.id] = nil

        var incomplete = plan
        incomplete.sources = []
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
        #expect(model.commandRepositoryID(for: .restoreSnapshot(repository.id, "abc")) == repository.id)
        #expect(model.commandRepositoryID(for: .plan(plan.id)) == repository.id)
        #expect(model.commandRepositoryID(for: .plan(orphan.id)) == nil)
        #expect(model.commandRepositoryID(for: .plan(unset.id)) == nil)
        // A group under Other backups resolves to the repository it sits in
        // — whatever its plan ID names — and to nothing once that
        // repository is gone.
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: repository.id, planID: orphan.id)) == repository.id)
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: repository.id, planID: UUID())) == repository.id)
        #expect(model.commandRepositoryID(for: .orphanPlan(repositoryID: UUID(), planID: orphan.id)) == nil)
        #expect(model.commandRepositoryID(for: .repository(UUID())) == nil)
        for selection: SidebarItem? in [.activity, .console, nil] {
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
        // Find and Refresh All are about every repository, not the selection.
        #expect(nothing.canFind && nothing.canRefreshAll)
        model.configuration.repositories = []
        #expect(!model.repositoryCommands(for: nil).canFind)
        #expect(!model.repositoryCommands(for: nil).canRefreshAll)
    }

    @Test("a busy repository holds maintenance and retention back, never its removal")
    func busyRepositoryBlocksMaintenanceAndRetentionNotRemoval() {
        let model = makeModel()
        let repository = makeRepository()
        let planA = makePlan("A", on: repository)
        let planB = makePlan("B", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [planA, planB]
        let busy = "The repository is in use by a backup or maintenance job — try again when it finishes."

        model.maintenance[repository.id] = MaintenanceActivity(task: .check)
        let maintaining = model.repositoryCommands(for: .repository(repository.id))
        #expect(!maintaining.canMaintain)
        #expect(maintaining.canEdit && maintaining.canRemove)
        let heldA = model.planCommands(for: .plan(planA.id))
        #expect(!heldA.canApplyRetention)
        #expect(heldA.retentionBlocker == busy)

        // Another plan's backup to the same repository holds it too.
        model.maintenance[repository.id] = nil
        model.activity[planB.id] = PlanActivity()
        #expect(!model.planCommands(for: .plan(planA.id)).canApplyRetention)
        #expect(model.planCommands(for: .plan(planA.id)).retentionBlocker == busy)
        #expect(!model.repositoryCommands(for: .plan(planA.id)).canMaintain)
        model.activity[planB.id] = nil
        #expect(model.planCommands(for: .plan(planA.id)).canApplyRetention)

        var off = planA
        off.retention.isEnabled = false
        model.configuration.plans = [off, planB]
        #expect(model.planCommands(for: .plan(planA.id)).retentionBlocker == "Retention is off for this plan.")

        var zero = planA
        zero.retention = RetentionPolicy(
            isEnabled: true, keepLast: 0, keepHourly: 0, keepDaily: 0,
            keepWeekly: 0, keepMonthly: 0, keepYearly: 0
        )
        model.configuration.plans = [zero, planB]
        #expect(model.planCommands(for: .plan(planA.id)).retentionBlocker
            == "Every retention rule is zero, so there is nothing to apply.")

        let unset = makePlan("Unset", on: nil)
        model.configuration.plans = [unset]
        #expect(model.planCommands(for: .plan(unset.id)).retentionBlocker
            == "This plan needs a repository and at least one folder.")
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
        // Pause and Stop only while a backup runs.
        #expect(!idle.canPauseAndStopBackups)
        model.activity[plan.id] = PlanActivity()
        #expect(model.planCommands(for: nil).canPauseAndStopBackups)

        model.pauseBackups(for: .untilResumed)
        let paused = model.planCommands(for: nil)
        #expect(paused.backupsPaused)
        #expect(!paused.canPauseBackups && !paused.canPauseAndStopBackups)
        model.resumeBackups()
        #expect(!model.planCommands(for: nil).backupsPaused)

        // The battery's hold still offers a pause that outlasts it.
        model.configuration.settings.pauseOnBattery = true
        model.isOnBattery = true
        let battery = model.planCommands(for: nil)
        #expect(!battery.backupsPaused && battery.canPauseBackups)
    }

    @Test("every confirmation names its target, and a gone target asks nothing")
    func confirmationCopyNamesItsTarget() {
        let model = makeModel()
        let repository = makeRepository("NAS")
        let plan = makePlan("Docs", on: repository)
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]

        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.title == "Delete “Docs”?")
        #expect(model.confirmationCopy(for: .prune(repository.id))?.title == "Prune “NAS” now?")
        #expect(model.confirmationCopy(for: .check(repository.id))?.title == "Check the integrity of “NAS”?")
        #expect(model.confirmationCopy(for: .removeRepository(repository.id))?.title
            == "Remove “NAS” from SwiftRestic?")
        #expect(model.confirmationCopy(for: .unlock(repository.id))?.title == "Remove stale locks on “NAS”?")
        #expect(model.confirmationCopy(for: .rebuildIndex(repository.id))?.title
            == "Rebuild the search index for “NAS”?")

        let stopping = "will be stopped and recorded as cancelled"
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message.contains(stopping) == false)
        model.activity[plan.id] = PlanActivity()
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.message.contains(stopping) == true)
        #expect(model.confirmationCopy(for: .removeRepository(repository.id))?.message
            == model.removalConsequences(for: repository.id))
        model.activity[plan.id] = nil

        // The check dialog says which size of slow the user is holding.
        #expect(model.confirmationCopy(for: .check(repository.id))?.message.contains("currently holds") == false)
        model.repositoryStats[repository.id] = RepositoryStats(totalSize: 2_000_000)
        #expect(model.confirmationCopy(for: .check(repository.id))?.message
            .contains("This repository currently holds \(Format.bytes(2_000_000)).") == true)

        var unnamed = plan
        unnamed.name = ""
        model.configuration.plans = [unnamed]
        #expect(model.confirmationCopy(for: .deletePlan(plan.id))?.title == "Delete “Untitled Plan”?")

        #expect(model.confirmationCopy(for: .deletePlan(UUID())) == nil)
        #expect(model.confirmationCopy(for: .prune(UUID())) == nil)
    }
}
