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
    func removalConsequences(for repositoryID: UUID) -> String {
        var consequences = "The backup data itself is not deleted. Plans pointing at it will be paused."
        if restoreRepositoryID == repositoryID {
            consequences += " A restore from this repository is running and will be cancelled."
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
    /// Known disclosure gap: only a cancelled *restore* is announced (banner
    /// plus the removal-dialog clause in `removalConsequences`). Cancelled
    /// backups, maintenance and console commands land in the run history and
    /// menu lines but are not disclosed by the dialogs — same defect class,
    /// still open.
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
    func context(for repository: Repository) async throws -> RepositoryContext {
        #if DEBUG
        // Capture and CI runs hand over the password through the environment so
        // they never touch the login Keychain. Gated on the throwaway-config
        // override as well, so a stale variable in a developer's shell cannot
        // silently feed the wrong password to a normal debug run.
        if let injected = ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_PASSWORD"],
           !injected.isEmpty,
           ProcessInfo.processInfo.environment["SWIFTRESTIC_CONFIG_DIR"] != nil
        {
            return RepositoryContext(
                repository: repository,
                password: injected,
                providerSecret: ProcessInfo.processInfo.environment["SWIFTRESTIC_REPO_SECRET"],
                settings: configuration.settings
            )
        }
        #endif
        let stored = await secrets.load(repository.id)
        guard let password = stored.password, !password.isEmpty else {
            throw ResticError.passwordMissing(repositoryName: repository.name)
        }
        return RepositoryContext(
            repository: repository,
            password: password,
            providerSecret: stored.providerSecret,
            settings: configuration.settings
        )
    }

    func service() throws -> ResticService {
        guard let binary else {
            throw ResticError.binaryNotFound(searched: ResticBinary.searchPaths)
        }
        return ResticService(runner: runner, binary: binary.url)
    }
}
