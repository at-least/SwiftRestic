import Foundation

extension AppModel {
    func repository(id: UUID?) -> Repository? { configuration.repository(id: id) }

    func repositoryLabel(id: UUID?) -> String? { repository(id: id).map { label(of: $0) } }

    /// The last snapshot listing refused the saved password (exit 12); a run
    /// refused it re-reads the listing, so this covers runs too. The editor
    /// then opens on the password field, not "Saved in Keychain".
    func passwordRefused(repositoryID: UUID) -> Bool {
        if case .passwordRefused? = snapshotListingOutcomes[repositoryID] { return true }
        return false
    }

    /// A non-empty `password` replaces the stored one; nil keeps it. A new
    /// password for a saved location reruns its failed backups once the
    /// Keychain holds it.
    func upsert(repository: Repository, password: String?, providerSecret: String?) async {
        let isSaved = self.repository(id: repository.id) != nil
        var fixesBackups = false
        do {
            try await secrets.save(repository.id, password, providerSecret)
            // Only after a successful save: a Keychain failure must not
            // schedule work for a password that never landed.
            if password?.isEmpty == false {
                repositoriesMissingPassword.remove(repository.id)
                fixesBackups = isSaved
            }
        } catch {
            post(Banner(
                title: "Couldn’t save the password for “\(label(of: repository))”",
                message: error.localizedDescription,
                level: .error
            ))
        }
        // The context cache compares the Repository value, which carries no
        // secrets: a secrets-only edit leaves it equal, so only this drop
        // stops stale credentials being served.
        forgetContext(repository.id)

        if let index = configuration.repositories.firstIndex(where: { $0.id == repository.id }) {
            configuration.repositories[index] = configuration.repositories[index].merging(draft: repository)
        } else {
            configuration.repositories.append(repository)
        }
        if fixesBackups { rerunFailedBackups(in: repository.id) }
    }

    /// A missing server or cloud location's fix: its plans back up to where
    /// the backups are now. Each keeps its id, so its tag and its history
    /// in the new location stay its own; the missing location stays until
    /// the user removes it.
    func movePlans(from oldRepositoryID: UUID, to newRepositoryID: UUID) {
        precondition(repository(id: newRepositoryID) != nil, "plans move to a saved location")
        for index in configuration.plans.indices where configuration.plans[index].repositoryID == oldRepositoryID {
            configuration.plans[index].repositoryID = newRepositoryID
        }
        rerunFailedBackups(in: newRepositoryID)
    }

    /// The removal dialog's sentence. Each cancellation `deleteRepository`
    /// performs needs its own clause here; the two are kept in step by hand.
    func removalConsequences(for repositoryID: UUID) -> String {
        let plans = plans(in: repositoryID)
        return Self.removalConsequences(
            removedPlanNames: plans.map { label(of: $0) },
            isRestoring: restoreRepositoryID == repositoryID,
            runningBackupNames: plans.filter { activity[$0.id] != nil }.map { label(of: $0) },
            runningMaintenance: maintenance[repositoryID]?.task,
            isConsoleRunning: console.runningRepositoryID == repositoryID
        )
    }

    /// Static so tests can word it without a live model (the console's
    /// running state is `private(set)`).
    nonisolated static func removalConsequences(
        removedPlanNames: [String],
        isRestoring: Bool,
        runningBackupNames: [String],
        runningMaintenance: MaintenanceTask?,
        isConsoleRunning: Bool
    ) -> String {
        var consequences = ""
        if !removedPlanNames.isEmpty {
            let quoted = removedPlanNames.map { "“\($0)”" }
            consequences += removedPlanNames.count == 1
                ? "Its plan \(quoted[0]) is removed too. "
                : "Its plans \(Format.list(quoted)) are removed too. "
        }
        consequences += "The backups in it are kept."
        if isRestoring {
            consequences += " A restore from this location is running and will be stopped."
        }
        if !runningBackupNames.isEmpty {
            let names = runningBackupNames.map { "“\($0)”" }
            consequences += names.count == 1
                ? " A backup of \(names[0]) is running and will be stopped."
                : " Backups of \(Format.list(names)) are running and will be stopped."
        }
        if let runningMaintenance {
            consequences += " \(runningMaintenance.runningClause(count: 1)) and will be stopped."
        }
        if isConsoleRunning {
            consequences += " A console command is running and will be stopped."
        }
        return consequences
    }

    /// Removes a repository and its plans; its data and run history stay.
    /// The cancelled tasks' unwind writes their own run records and clears
    /// their own entries, so doing either here would double them.
    /// Cancellation is cooperative: a backup already past restic still
    /// settles as a success, since its snapshot is real.
    func deleteRepository(id: UUID) {
        for plan in configuration.plans where plan.repositoryID == id {
            tasks.cancel(.plan(plan.id))
        }
        tasks.cancel(.maintenance(id))
        if restoreRepositoryID == id { tasks.cancel(.restore) }
        if console.runningRepositoryID == id { console.cancelRunningCommand() }
        // Before the repository list shrinks: the cancelled child can take
        // seconds to unwind, and `maintenanceLines` reads that list, so the
        // other order leaves the menu blank until the unwind lands.
        clearRuntimeState(repositoryID: id)
        configuration.repositories.removeAll { $0.id == id }
        // deletePlan's own bookkeeping, so the two ways a plan goes cannot
        // drift apart; its cancel repeats the one above harmlessly.
        for plan in plans(in: id) {
            deletePlan(id: plan.id)
        }
        // Tracked so quitting drains them: an interrupted index drop can
        // recreate its file, and an interrupted Keychain removal leaves
        // secrets no UI can reach.
        tasks.addBackground(Task { [indexCoordinator] in
            await indexCoordinator.dropRepository(repositoryID: id)
        })
        tasks.addBackground(Task { [weak self, secrets] in
            do {
                try await secrets.remove(id)
            } catch {
                self?.post(Banner(
                    title: "The removed location’s secrets are still in your Keychain",
                    message: error.localizedDescription
                        + " In Keychain Access they are named “\(KeychainStore.service)”, with accounts that start \(id.uuidString).",
                    level: .error
                ))
            }
        })
    }

    /// Every per-repository runtime entry; a new dictionary keyed by
    /// repository id joins this list, or its entry leaks forever.
    /// `loadingSnapshots` is left to the in-flight refresh's own `defer`.
    private func clearRuntimeState(repositoryID id: UUID) {
        maintenance[id] = nil
        retireRunToken(for: .maintenance(id))
        snapshots[id] = nil
        repositoryStats[id] = nil
        snapshotListingOutcomes[id] = nil
        snapshotsLoadedAt[id] = nil
        snapshotsGeneration[id] = nil
        indexTakenGeneration[id] = nil
        pendingSnapshotRefreshes.remove(id)
        repositoriesMissingPassword.remove(id)
        maintenanceAwaitingDrive.remove(id)
        maintenanceAwaitingServer.remove(id)
        backupQueue[id] = nil
        statsFailureNoted.remove(id)
        forgetContext(id)
        fileHistoryAnswers = fileHistoryAnswers.filter { $0.key.repositoryID != id }
    }

    func storedSecrets(for repositoryID: UUID) async throws -> (password: String?, providerSecret: String?) {
        try await secrets.load(repositoryID)
    }
    /// Caches `readContext`'s answer beside the repository value it was built
    /// from. That value holds no secrets, so secret edits invalidate through
    /// `upsert` and stale credentials through `noteAuthFailure`. Failures
    /// are never cached.
    func context(for repository: Repository) async throws -> RepositoryContext {
        if let cached = resolvedContexts[repository.id], cached.repository == repository {
            return cached.context
        }
        let generation = contextGenerations[repository.id, default: 0]
        let context = try await Self.readContext(for: repository, label: label(of: repository), secrets: secrets)
        if contextGenerations[repository.id, default: 0] == generation {
            resolvedContexts[repository.id] = (repository, context)
        }
        return context
    }

    /// Drops a repository's cached context, and keeps any secret read
    /// already in flight from caching what it read.
    func forgetContext(_ repositoryID: UUID) {
        resolvedContexts[repositoryID] = nil
        contextGenerations[repositoryID, default: 0] += 1
    }

    /// restic changes the key first, then the Keychain follows. Once restic
    /// has changed it the old password is gone, so a Keychain failure must
    /// surface as `PasswordNotStored`.
    func changeRepositoryPassword(repositoryID: UUID, to newPassword: String) async throws {
        precondition(EditorRequirements.newPassword(newPassword, confirm: newPassword) == nil, "an unchecked new password")
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryRemoved }
        let (service, context) = try await resticContext(for: repository)
        do {
            try await service.changePassword(context, newPassword: newPassword)
        } catch {
            noteAuthFailure(error, repositoryID: repositoryID)
            throw error
        }
        // After the save, whatever it answered: until it lands the
        // Keychain and the cache both hold the old password.
        defer { forgetContext(repositoryID) }
        do {
            try await secrets.save(repositoryID, newPassword, nil)
        } catch {
            throw PasswordNotStored(repositoryName: label(of: repository), reason: error.localizedDescription)
        }
    }

    /// Callers keep their own missing-repository guard: each surface words
    /// it its own way.
    func resticContext(
        for repository: Repository
    ) async throws -> (service: any ResticClient, context: RepositoryContext) {
        try await reconnectShare(before: repository)
        let service = try service()
        let context = try await context(for: repository)
        return (service, context)
    }

    /// A stale provider secret exits with restic's fatal catch-all, not 12
    /// (a rejected S3 key exits 1), so every fatal error costs one extra
    /// Keychain read.
    func noteAuthFailure(_ error: Error, repositoryID: UUID) {
        guard case let ResticError.commandFailed(code, _) = error,
              code == ResticError.wrongPasswordCode || code == Self.resticFatalErrorCode else { return }
        forgetContext(repositoryID)
    }

    private static let resticFatalErrorCode: Int32 = 1

    func service() throws -> any ResticClient {
        guard let binary else { throw ResticError.damagedInstall }
        return ResticService(runner: runner, binary: binary.url)
    }

    /// Run before anything is kept. Returns whether it created a repository.
    func openRepository(_ context: RepositoryContext, creatingIfMissing: Bool) async throws -> Bool {
        let service = try service()
        do {
            if try await service.repositoryExists(context, timeout: EditorRequirements.probeTimeout) { return false }
        } catch ResticError.timedOut {
            throw MessageError(message: EditorRequirements.probeTimedOut)
        }
        guard creatingIfMissing else { throw MessageError(message: EditorRequirements.noRepositoryHere) }
        _ = try await service.initializeRepository(context)
        return true
    }

    /// Opens the repository before the Keychain keeps `password`, so a
    /// refused one never replaces the stored one.
    func enterPassword(_ password: String, forRepository repositoryID: UUID) async throws {
        guard let repository = repository(id: repositoryID) else { throw ResticError.repositoryRemoved }
        let context = RepositoryContext(
            repository: repository,
            password: password,
            providerSecret: try await storedSecrets(for: repositoryID).providerSecret
        )
        do {
            _ = try await openRepository(context, creatingIfMissing: false)
        } catch let ResticError.commandFailed(code, _) where code == ResticError.wrongPasswordCode {
            throw MessageError(message: ResticError.wrongPassword(location: label(of: repository)))
        }
        await upsert(repository: repository, password: password, providerSecret: nil)
        scheduleSnapshotRefresh(repositoryID: repositoryID)
    }
}

/// An error whose whole content is the sentence the user reads.
struct MessageError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct PasswordNotStored: LocalizedError {
    let repositoryName: String
    let reason: String

    var errorDescription: String? {
        "“\(repositoryName)” now opens only with the new password, but the Keychain couldn’t store it: \(reason) "
            + "Type the new password in Password and save once the Keychain works. Until then its backups fail."
    }
}
