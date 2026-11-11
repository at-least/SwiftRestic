import Foundation

/// Derived on every read, never stored: the menu bar, the sidebar's plan
/// menu and the plan page read the same answers, so one surface cannot
/// enable what another refuses.
struct PlanCommandState: Equatable {
    var planID: UUID?
    /// On a repository's page: the plans Back Up Now starts. Empty on a plan's,
    /// where `planID` says.
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
    /// A new repository's Save asks restic, so neither form opens without it:
    /// a plan needs a repository to go in.
    var canAddRepository = false
    var canNewPlan = false
    var canFind = false
    var canRefreshAll = false
    /// restic Console, the menu's and the sidebar row's: the console
    /// picks its own repository, so it needs only one to exist.
    var canOpenConsole = false
    /// Check, Clean Up: restic work that must not collide with a backup
    /// or another job on it.
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
        // One rule for every Back Up Now and every Stop: the tray's.
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
        state.canRefreshAll = state.canFind
        state.canOpenConsole = state.canFind
        guard let id = commandRepositoryID(for: selection) else { return state }
        state.repositoryID = id
        state.canMaintain = isResticAvailable && !busyRepositoryIDs.contains(id)
        state.canEdit = true
        state.canRemove = true
        return state
    }

    /// The repository the Location menu acts on: the selected one, the
    /// selected plan's, or the one a selected Other-backups group sits
    /// under (which is where
    /// that menu acts even for a moved plan's group: the plan's own
    /// repository is the other one). Nil for a target that no longer exists
    /// and for every other pane. A group is no plan, so the Backup menu stays
    /// grey over its selection.
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

    /// The Files tab ⌘F searches on this selection, by the roots its tree
    /// hangs from: a plan's with a repository set, the one page whose Files
    /// tab lists a tree. Nil on every other pane, where it opens Search All
    /// Backups.
    func filesSearchRoots(for selection: SidebarItem?) -> FileNode? {
        guard case let .plan(id) = selection, let repositoryID = plan(id: id)?.repositoryID else { return nil }
        return FileNode.roots(repositoryID: repositoryID, chainKey: ResticService.planTag(id))
    }

    /// A confirmation's title and message, naming its target — the dialog
    /// is raised from the sidebar's row menus and the menu bar, where an
    /// unnamed "this" would say nothing. Nil once the target is gone.
    func confirmationCopy(for confirmation: CommandConfirmation) -> ConfirmationCopy? {
        switch confirmation {
        case let .deletePlan(id):
            guard let plan = plan(id: id) else { return nil }
            let name = label(of: plan)
            // Where the snapshots land, said when there are some. Deleting is
            // the main source of adoptable groups — Continue Backups… restores this
            // same UUID.
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
                // From the model, so the disclosed consequences cannot drift
                // from what removal does.
                message: removalConsequences(for: id)
            )
        case let .prune(id):
            guard let repository = repository(id: id) else { return nil }
            return ConfirmationCopy(
                title: "Clean up “\(label(of: repository))” now?",
                message: "The data of removed backups is deleted for good. Backups to it wait until the cleanup finishes."
            )
        }
    }
}
