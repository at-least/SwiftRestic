import Foundation

extension AppModel {
    // MARK: - Repositories

    func repository(id: UUID?) -> Repository? { configuration.repository(id: id) }

    func upsert(repository: Repository, password: String?, providerSecret: String?) async {
        do {
            try await secrets.save(repository.id, password, providerSecret)
            // Cleared only on a successful save: a Keychain failure must not
            // have the model schedule upkeep for a repository whose password
            // never actually landed.
            if password?.isEmpty == false { repositoriesMissingPassword.remove(repository.id) }
        } catch {
            post(Banner(title: "Keychain", message: error.localizedDescription, isError: true))
        }
        // The cache key compares the Repository value, which by design carries
        // no secrets — a password-only or provider-secret-only edit leaves it
        // unchanged, so the entry dies here rather than serving stale
        // credentials until an exit-12 happens to clear it (a wrong provider
        // secret never would).
        resolvedContexts[repository.id] = nil

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
            tasks.cancel(.plan(plan.id))
        }
        tasks.cancel(.maintenance(id))
        if restoreRepositoryID == id { tasks.cancel(.restore) }
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
        pendingSnapshotRefreshes.remove(id)
        repositoriesMissingPassword.remove(id)
        resolvedContexts[id] = nil
        // Both sends quitting should drain: an untracked index drop could
        // recreate the file it was deleting, and an untracked keychain
        // removal that lost the race leaves orphaned secrets no UI path
        // can ever reach again.
        tasks.addBackground(Task { [indexCoordinator] in
            await indexCoordinator.dropRepository(repositoryID: id)
        })
        tasks.addBackground(Task { [secrets] in await secrets.remove(id) })
    }

    func storedSecrets(for repositoryID: UUID) async throws -> (password: String?, providerSecret: String?) {
        try await secrets.load(repositoryID)
    }

    func storedPassword(for repositoryID: UUID) async throws -> String? {
        try await secrets.load(repositoryID).password
    }
    /// Builds everything a restic command needs, or explains what is missing.
    /// The password rules live once, in the drag path's main-actor-free
    /// variant (`AppModel.dragContext`) — this delegates to it, and caches
    /// the answer. The cache key carries the repository value and the rate
    /// limits (everything except the secrets, which the key cannot see);
    /// secret edits are covered by `upsert`'s explicit invalidation, and a
    /// stale credential by `noteAuthFailure`. Failures are never cached;
    /// only a fully resolved context is.
    func context(for repository: Repository) async throws -> RepositoryContext {
        let key = ResolvedContextKey(repository: repository, settings: configuration.settings)
        if let cached = resolvedContexts[repository.id], cached.key == key {
            return cached.context
        }
        let context = try await Self.dragContext(
            repository: repository,
            settings: configuration.settings,
            secrets: secrets
        )
        resolvedContexts[repository.id] = (key, context)
        return context
    }

    /// Drops a repository's cached context so the next call re-reads the
    /// Keychain. Exit 12 (wrong password / no matching key) is the failure a
    /// stale repository credential produces; exit 1 is what a stale provider
    /// secret surfaces as (restic's fatal-error catch-all — a rejected B2 or
    /// S3 key exits 1, not 12). Without the drop, a credential fixed outside
    /// the app would leave every call failing until a restart. The cost is
    /// one extra Keychain read after any fatal error, which no run frequency
    /// makes expensive.
    func noteAuthFailure(_ error: Error, repositoryID: UUID) {
        guard case let ResticError.commandFailed(code, _, _) = error, code == 12 || code == 1 else { return }
        resolvedContexts[repositoryID] = nil
    }

    /// The engine seam: everything above `ResticClient` is written against
    /// the protocol, and this is the one place the concrete binary-backed
    /// implementation is chosen.
    func service() throws -> any ResticClient {
        guard let binary else {
            throw ResticError.binaryNotFound(searched: ResticBinary.searchPaths)
        }
        return ResticService(
            runner: runner,
            binary: binary.url,
            // `resolveBinary` probed the version at launch; an unreadable
            // answer keeps the stall cap's default (on).
            streamsRestoreProgress: ResticVersion(parsing: resticVersion)?.streamsRestoreProgress ?? true
        )
    }
}

/// Everything a cached `RepositoryContext` depends on, carried beside it so
/// any relevant edit invalidates by comparison — see `AppModel.context(for:)`.
/// Deliberately not the whole `AppSettings`: only the rate limits reach a
/// context, and settings like the console history change far more often than
/// the limits do.
struct ResolvedContextKey: Equatable, Sendable {
    var repository: Repository
    var uploadLimitKiBps: Int
    var downloadLimitKiBps: Int

    init(repository: Repository, settings: AppSettings) {
        self.repository = repository
        self.uploadLimitKiBps = settings.uploadLimitKiBps
        self.downloadLimitKiBps = settings.downloadLimitKiBps
    }
}
