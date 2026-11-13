import Foundation

/// Derived on every read, never stored, so no surface can enable what
/// another refuses.
struct PlanCommandState: Equatable {
    var planID: UUID?
    /// Empty on a plan's page, where `planID` says.
    var repositoryPlanIDs: [UUID] = []
    var canBackUp = false
    var backUpDisabledReason: String?
    var canStop = false
    var stopTitle = "Stop Backup"
    var canEdit = false
    var canDelete = false
    var backupsPaused = false
    var canPauseBackups = false
}

struct RepositoryCommandState: Equatable {
    var repositoryID: UUID?
    /// A new repository's Save asks restic.
    var canAddRepository = false
    var canNewPlan = false
    var canFind = false
    var canMaintain = false
    var canEdit = false
    /// Never busy-gated: the removal dialog names the work it will cancel.
    var canRemove = false
}

struct ConfirmationCopy: Equatable {
    var title: String
    var message: String
}

extension AppModel {
    func planCommands(for selection: SidebarItem?) -> PlanCommandState {
        var state = PlanCommandState()
        // The tray's rule, for every Back Up Now and Stop.
        let rows = MenuBarStatus.planRows(
            plans: configuration.plans,
            activity: activity,
            isResticDamaged: !isResticAvailable,
            lockedRepositories: lockedRepositories
        )
        if case .paused = scheduleHold {
            state.backupsPaused = true
        } else {
            state.canPauseBackups = !configuration.repositories.isEmpty
        }

        if case let .repository(repositoryID) = selection {
            let own = Set(plans(in: repositoryID).map(\.id))
            state.repositoryPlanIDs = rows
                .filter { own.contains($0.planID) && $0.action == .backUp && $0.isEnabled }
                .map(\.planID)
            state.canBackUp = !state.repositoryPlanIDs.isEmpty
            return state
        }
        guard case let .plan(id) = selection, plan(id: id) != nil else { return state }
        state.planID = id
        if let row = rows.first(where: { $0.planID == id }) {
            state.canBackUp = row.action == .backUp && row.isEnabled
            state.backUpDisabledReason = row.disabledReason
            state.canStop = row.action == .stop
        }
        state.stopTitle = MenuBarStatus.stopTitle(for: activity[id]?.phase)
        state.canEdit = true
        state.canDelete = true
        return state
    }

    func repositoryCommands(for selection: SidebarItem?) -> RepositoryCommandState {
        var state = RepositoryCommandState()
        state.canAddRepository = isResticAvailable
        state.canNewPlan = isResticAvailable || !configuration.repositories.isEmpty
        state.canFind = !configuration.repositories.isEmpty && isResticAvailable
        guard let id = commandRepositoryID(for: selection) else { return state }
        state.repositoryID = id
        state.canMaintain = isResticAvailable && !busyRepositoryIDs.contains(id)
        state.canEdit = true
        state.canRemove = true
        return state
    }

    /// A group acts on the repository it sits under, even when its plan
    /// moved to another one.
    func commandRepositoryID(for selection: SidebarItem?) -> UUID? {
        let id: UUID? = switch selection {
        case let .repository(id): id
        case let .plan(planID): plan(id: planID)?.repositoryID
        case let .orphanPlan(id, _): id
        case let .lineage(id, _): id
        case .findFiles, .activity, nil: nil
        }
        return repository(id: id)?.id
    }

    /// Names its target: raised from row menus and the menu bar, where
    /// "this" says nothing.
    func confirmationCopy(for confirmation: CommandConfirmation) -> ConfirmationCopy? {
        switch confirmation {
        case let .deletePlan(id):
            guard let plan = plan(id: id) else { return nil }
            let name = label(of: plan)
            // Continue Backups… later restores this same UUID.
            let landing: String
            if let repositoryID = plan.repositoryID,
               let repository = repository(id: repositoryID),
               let left = backupsLeftBehind(planID: id, in: repositoryID)
            {
                landing = "Its \(Format.plural(left, "backup")) \(left == 1 ? "stays" : "stay")"
                    + " in “\(label(of: repository))”, and you can continue \(left == 1 ? "it" : "them") later."
            } else {
                landing = "Backups already written to the location are not deleted."
            }
            let message = activity[id] != nil
                ? "The running backup will be stopped. \(landing)"
                : "This Mac stops backing up “\(name)”. \(landing)"
            return ConfirmationCopy(title: "Remove “\(name)”?", message: message)
        case let .deleteRepository(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Remove “\(label(of: repository))” from SwiftRestic?",
                message: removalConsequences(for: id)
            )
        }
    }
}
