import Foundation

/// What the Plan menu can do for the sidebar's selection. Derived on every
/// read, never stored: the menu bar, the sidebar's plan menu and the plan
/// page read the same answers, so an item cannot be enabled on one surface
/// over an action another refuses.
struct PlanCommandState: Equatable {
    /// The selected plan, when the selection is one that still exists.
    var planID: UUID?
    var canBackUp = false
    var canStop = false
    /// "Stop Backup", or "Stop Applying Retention" while that phase runs —
    /// a backup's own retention step included; the tray's row words itself
    /// by the same rule (`MenuBarStatus.stopsRetention`).
    var stopTitle = "Stop Backup"
    var canEdit = false
    /// "Pause Schedule" or "Resume Schedule", keyed on
    /// `BackupPlan.isScheduleActive(at:)` — both kinds of pause resume.
    var scheduleTitle = "Pause Schedule"
    var isScheduleActive = true
    /// Resume always; Pause only where there is a schedule to pause.
    var canToggleSchedule = false
    var canApplyRetention = false
    /// Why Apply Retention Now… is disabled, for its help and the sheet.
    var retentionBlocker: String?
    var canDelete = false
    /// Back Up All Plans Now: not about the selection.
    var canBackUpAll = false
    /// The app-wide pause, by the tray's rules: Resume Backups while
    /// paused, else Pause Backups once a repository exists, and Pause and
    /// Stop only while a backup runs.
    var backupsPaused = false
    var canPauseBackups = false
    var canPauseAndStopBackups = false
}

/// What the Repository menu can do for the sidebar's selection.
struct RepositoryCommandState: Equatable {
    /// The repository the menu acts on — see `commandRepositoryID(for:)`.
    var repositoryID: UUID?
    /// Find Files and Refresh All Snapshots: every repository's, not the
    /// selection's.
    var canFind = false
    var canRefreshAll = false
    /// Check, Prune, Remove Stale Locks, Rebuild Search Index: restic work
    /// that must not collide with a backup or another job on it.
    var canMaintain = false
    var canEdit = false
    /// Never busy-gated: the removal dialog names the work it will cancel.
    var canRemove = false
}

/// A confirmation dialog's words.
struct ConfirmationCopy: Equatable {
    var title: String
    var message: String
}

extension AppModel {
    // MARK: - Menu command state

    func planCommands(for selection: SidebarItem?, now: Date = .now) -> PlanCommandState {
        var state = PlanCommandState()
        // One rule for every Back Up Now and every Stop: the tray's.
        let rows = MenuBarStatus.planRows(
            plans: configuration.plans,
            activity: activity,
            isResticAvailable: isResticAvailable
        )
        state.canBackUpAll = rows.contains { $0.action == .backUp && $0.isEnabled }
        if case .paused = scheduleHold {
            state.backupsPaused = true
        } else {
            state.canPauseBackups = !configuration.repositories.isEmpty
            state.canPauseAndStopBackups = state.canPauseBackups && !activity.isEmpty
        }

        guard case let .plan(id) = selection, let plan = plan(id: id) else { return state }
        state.planID = id
        if let row = rows.first(where: { $0.planID == id }) {
            state.canBackUp = row.action == .backUp && row.isEnabled
            state.canStop = row.action == .stop
        }
        if MenuBarStatus.stopsRetention(activity[id]?.phase) {
            state.stopTitle = "Stop Applying Retention"
        }
        state.canEdit = true
        state.canDelete = true
        state.isScheduleActive = plan.isScheduleActive(at: now)
        state.scheduleTitle = state.isScheduleActive ? "Pause Schedule" : "Resume Schedule"
        state.canToggleSchedule = !state.isScheduleActive || plan.schedule.frequency != .manual
        state.retentionBlocker = retentionBlocker(for: plan)
        state.canApplyRetention = state.retentionBlocker == nil
        return state
    }

    /// Why the plan's retention cannot be applied now, first reason first;
    /// nil when it can.
    private func retentionBlocker(for plan: BackupPlan) -> String? {
        guard plan.isConfigurationComplete, let repository = repository(id: plan.repositoryID) else {
            return "This plan needs a repository and at least one folder."
        }
        guard plan.retention.isEnabled else { return "Retention is off for this plan." }
        guard plan.retention.isSafeToRun else {
            return "Every retention rule is zero, so there is nothing to apply."
        }
        guard isResticAvailable else { return "restic is missing." }
        // The plan's own run included: its backup holds the repository too.
        guard !busyRepositoryIDs.contains(repository.id) else {
            return "The repository is in use by a backup or maintenance job — try again when it finishes."
        }
        return nil
    }

    func repositoryCommands(for selection: SidebarItem?) -> RepositoryCommandState {
        var state = RepositoryCommandState()
        state.canFind = !configuration.repositories.isEmpty && isResticAvailable
        state.canRefreshAll = state.canFind
        guard let id = commandRepositoryID(for: selection) else { return state }
        state.repositoryID = id
        state.canMaintain = isResticAvailable && !busyRepositoryIDs.contains(id)
        state.canEdit = true
        state.canRemove = true
        return state
    }

    /// The repository the Repository menu acts on: the selected one, the
    /// one a selected Restore record or Files item belongs to, the selected
    /// plan's — Arq's Backup Plan menu acts through the plan the same way —
    /// or the one a selected Other-backups group sits under (which is where that
    /// menu acts even for a moved plan's group: the plan's own repository
    /// is the other one). Nil for a target that no longer exists and for
    /// every other pane. A group is no plan, so the Plan menu stays grey
    /// over its selection.
    func commandRepositoryID(for selection: SidebarItem?) -> UUID? {
        let id: UUID? = switch selection {
        case let .repository(id): id
        case let .restoreSnapshot(id, _): id
        case let .plan(planID): plan(id: planID)?.repositoryID
        case let .orphanPlan(id, _): id
        case let .lineage(id, _): id
        case let .file(node): node.repositoryID
        case .console, .activity, nil: nil
        }
        return repository(id: id)?.id
    }

    /// The repository Find Files opens on: the Restore pane's "Search All
    /// Backups…" hand-off wins; otherwise the window's selection by the
    /// Repository menu's own rule — and the first repository only when that
    /// names none to look at (Activity, the console, nothing). The root
    /// reads this beside the prefill — the read that provably reaches the
    /// sheet — and hands the answer over, so FindFilesView needs no router.
    func findFilesRepositoryID(prefillRepositoryID: UUID?, selection: SidebarItem?) -> UUID? {
        prefillRepositoryID ?? commandRepositoryID(for: selection) ?? configuration.repositories.first?.id
    }

    // MARK: - Confirmations

    /// A confirmation's title and message, naming its target — the dialog
    /// can now be raised from the plan page or the menu bar, where "this
    /// repository" named nothing. Nil once the target is gone.
    func confirmationCopy(for confirmation: CommandConfirmation) -> ConfirmationCopy? {
        switch confirmation {
        case let .deletePlan(id):
            guard let plan = plan(id: id) else { return nil }
            let name = plan.name.isEmpty ? "Untitled Plan" : plan.name
            // Where the snapshots land, said when there are some: the count
            // and the shelf the sidebar will move them to, so the dialog and
            // what happens next cannot disagree. Deleting is the main source
            // of adoptable groups — re-adoption restores this same UUID.
            let landing: String
            if let repositoryID = plan.repositoryID,
               let repository = repository(id: repositoryID),
               let count = shelves(for: repositoryID).byPlan[id]?.count,
               count > 0
            {
                // The shelf's title as it will read once this plan is gone —
                // the sidebar's own derivation, counted without the plan
                // being deleted, so the dialog never names a section by a
                // title it will not have ("Backups" beside no plan).
                let shelf = SidebarTree.otherBackupsTitle(
                    repositoryHasPlans: plans(in: repositoryID).count > 1
                )
                landing = "Its \(Format.plural(count, "snapshot")) \(count == 1 ? "stays" : "stay")"
                    + " in “\(repository.name)”, under \(shelf), and can be adopted back."
            } else {
                landing = "Snapshots already written to the repository are not deleted."
            }
            return ConfirmationCopy(
                title: "Delete “\(name)”?",
                // The plan page's words: it could see a run in flight, and
                // now every surface can.
                message: isRunning(planID: id)
                    ? "The running backup will be stopped and recorded as cancelled. \(landing)"
                    : "The plan and its schedule are removed. \(landing)"
            )
        case let .removeRepository(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Remove “\(repository.name)” from SwiftRestic?",
                // From the model, so the disclosed consequences can never
                // drift from what removal actually does.
                message: removalConsequences(for: id)
            )
        case let .check(id):
            guard let repository = repository(id: id) else { return nil }
            // "Slow" is a different unit of slow on a 4 TB repository than on
            // a memory stick, so the dialog says which one the user holds.
            var message = "Structure checks are fast; reading data finds more problems at the cost of time. The repository is locked while the check runs, so backups to it are held back until it finishes."
            if let size = repositoryStats[id]?.totalSize {
                message += " This repository currently holds \(Format.bytes(size))."
            }
            return ConfirmationCopy(title: "Check the integrity of “\(repository.name)”?", message: message)
        case let .prune(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Prune “\(repository.name)” now?",
                message: "Pruning permanently removes the data of deleted snapshots and locks the repository exclusively — backups to it are held back until it finishes."
            )
        case let .unlock(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Remove stale locks on “\(repository.name)”?",
                message: "This removes locks left behind by interrupted restic processes. If restic is running somewhere else right now, removing its lock can corrupt the repository."
            )
        case let .rebuildIndex(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Rebuild the search index for “\(repository.name)”?",
                message: "The local search index, with its cached folder listings and comparisons, is deleted and read back from the repository, snapshot by snapshot. The repository itself is not touched. Until the rebuild finishes, folder version lists are incomplete, the Restore pane's search may miss matches, and Find Files searches through restic, which is slower."
            )
        }
    }
}
