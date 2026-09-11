import Foundation

extension AppModel {
    // MARK: - Repositories

    func repository(id: UUID?) -> Repository? { configuration.repository(id: id) }

    func upsert(repository: Repository, password: String?, providerSecret: String?) async {
        do {
            try await secrets.save(repository.id, password, providerSecret)
        } catch {
            post(Banner(title: "Keychain", message: error.localizedDescription, isError: true))
        }
        if password?.isEmpty == false { repositoriesMissingPassword.remove(repository.id) }

        if let index = configuration.repositories.firstIndex(where: { $0.id == repository.id }) {
            // As with plans: maintenance stamps are written by the model while
            // the editor held its draft. A check that finished mid-edit must
            // not look like it never happened, or the scheduler repeats it.
            var updated = repository
            updated.maintenance.lastCheckAt = configuration.repositories[index].maintenance.lastCheckAt
            updated.maintenance.lastPruneAt = configuration.repositories[index].maintenance.lastPruneAt
            configuration.repositories[index] = updated
        } else {
            configuration.repositories.append(repository)
        }

        // The context always applies the stored location and password last, so
        // these entries would silently do nothing. Say so rather than let the
        // user believe a variable is doing work.
        let overridden = RepositoryContext(
            repository: repository,
            password: password ?? "",
            providerSecret: providerSecret
        ).overriddenExtraEnvironmentKeys
        if !overridden.isEmpty {
            post(Banner(
                title: "Ignored environment variables",
                message: "\(overridden.joined(separator: ", ")) is set by SwiftRestic itself; an entry for it in this repository's extra environment (configuration file) has no effect.",
                isError: false
            ))
        }
    }

    /// What removing this repository does to work in flight — the removal
    /// dialogs word themselves from here so the rule and its phrasing stay
    /// testable at the model level, the same pattern as `quitInterruptions`.
    /// Every kind of cancellation `deleteRepository` will perform gets its own
    /// clause, so the dialog's word of what will be interrupted can never
    /// trail what removal actually does.
    func removalConsequences(for repositoryID: UUID) -> String {
        Self.removalConsequences(
            isRestoring: restoreRepositoryID == repositoryID,
            runningBackupNames: configuration.plans
                .filter { $0.repositoryID == repositoryID && activity[$0.id] != nil }
                .map { $0.name.isEmpty ? "Untitled Plan" : $0.name },
            isMaintaining: maintenance[repositoryID] != nil,
            isConsoleRunning: console.runningRepositoryID == repositoryID
        )
    }

    /// Pure so the dialog's wording can be tested without a live model — the
    /// console's running state is `private(set)`, and the sentence, not the
    /// bookkeeping, is what needs testing.
    nonisolated static func removalConsequences(
        isRestoring: Bool,
        runningBackupNames: [String],
        isMaintaining: Bool,
        isConsoleRunning: Bool
    ) -> String {
        var consequences = "The backup data itself is not deleted. Plans pointing at it will be paused."
        if isRestoring {
            consequences += " A restore from this repository is running and will be cancelled."
        }
        if !runningBackupNames.isEmpty {
            consequences += " A backup (\(runningBackupNames.joined(separator: ", "))) is running and will be cancelled."
        }
        if isMaintaining {
            consequences += " Repository maintenance is running and will be cancelled."
        }
        if isConsoleRunning {
            consequences += " A console command is running and will be cancelled."
        }
        return consequences
    }

    /// Removes a repository from the app. The data in the repository is untouched.
    ///
    /// Work in flight against it is cancelled first, and the tasks' unwind
    /// writes the run records itself — a cancelled run beats one that finishes
    /// silently against a repository the app no longer lists. Nothing else is
    /// cleaned up here: the completion blocks nil their own dictionary entries,
    /// and double bookkeeping would double the records. Cancellation is
    /// cooperative, so a backup already past restic (in retention or the
    /// closing refresh) still settles as a success — its snapshot is real.
    ///
    /// The removal dialog discloses all of it through `removalConsequences`,
    /// which enumerates every kind of work in flight; cancelled runs land in
    /// the run history either way, so the record of what stopped survives the
    /// dialog.
    func deleteRepository(id: UUID) {
        for plan in configuration.plans where plan.repositoryID == id {
            planTasks[plan.id]?.cancel()
        }
        maintenanceTasks[id]?.cancel()
        if restoreRepositoryID == id { restoreTask?.cancel() }
        if console.runningRepositoryID == id { console.cancelRunningCommand() }
        // Cancel-then-forget the menu line: the cancelled child can take
        // seconds to unwind, and `maintenanceLines` derives its rows from the
        // repository list this removal just shrank — without this the menu
        // would show neither a headline nor a line until the unwind lands.
        maintenance[id] = nil
        configuration.repositories.removeAll { $0.id == id }
        for index in configuration.plans.indices where configuration.plans[index].repositoryID == id {
            configuration.plans[index].repositoryID = nil
            configuration.plans[index].isEnabled = false
        }
        snapshots[id] = nil
        repositoryStats[id] = nil
        snapshotListingOutcomes[id] = nil
        snapshotsLoadedAt[id] = nil
        repositoriesMissingPassword.remove(id)
        Task { [secrets] in await secrets.remove(id) }
    }

    func storedSecrets(for repositoryID: UUID) async -> (password: String?, providerSecret: String?) {
        await secrets.load(repositoryID)
    }

    func storedPassword(for repositoryID: UUID) async -> String? {
        await secrets.load(repositoryID).password
    }

    /// Builds everything a restic command needs, or explains what is missing.
    /// The password rules live once, in the drag path's main-actor-free
    /// variant (`AppModel.dragContext`) — this delegates to it.
    func context(for repository: Repository) async throws -> RepositoryContext {
        try await Self.dragContext(
            repository: repository,
            settings: configuration.settings,
            secrets: secrets
        )
    }

    /// The engine seam: everything above `ResticClient` is written against
    /// the protocol, and this is the one place the concrete binary-backed
    /// implementation is chosen.
    func service() throws -> any ResticClient {
        guard let binary else {
            throw ResticError.binaryNotFound(searched: ResticBinary.searchPaths)
        }
        return ResticService(runner: runner, binary: binary.url)
    }
}
