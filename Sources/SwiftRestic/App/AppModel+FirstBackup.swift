import Foundation

extension AppModel {
    /// A plan the user just created: it starts now, and its first success is
    /// announced whatever the notification setting. A Manually plan waits for
    /// its Back Up Now.
    func createPlan(_ plan: BackupPlan) {
        var plan = plan
        plan.announcesFirstBackup = true
        upsert(plan: plan)
        if LoginItemAdvice.isScheduled(plan), isResticAvailable {
            runBackup(planID: plan.id)
        }
    }

    /// The first scheduled plan asks for what a schedule needs.
    func registersLoginItemOnSave(_ plan: BackupPlan) -> Bool {
        LoginItemAdvice.registersOnSave(
            draft: plan,
            among: configuration.plans,
            offer: LoginItemAdvice.offer(
                startsAtLogin: startsAtLogin,
                needsApproval: loginItemNeedsApproval,
                isInstallable: loginItemInstallable
            )
        )
    }

    /// The first-run sheet's Back Up: a repository in `folder`, created
    /// before it is kept, as the repository editor's Save does, then a plan
    /// for `source` with today's defaults. Throws with nothing kept.
    func createFirstBackup(source: String, folder: String, password: String) async throws -> UUID {
        var repository = Repository()
        repository.localPath = folder
        let service = try service()
        let context = RepositoryContext(repository: repository, password: password, providerSecret: nil)
        if try await !service.repositoryExists(context, timeout: EditorRequirements.probeTimeout) {
            _ = try await service.initializeRepository(context)
        }
        await upsert(repository: repository, password: password, providerSecret: nil)
        await flushSave()
        scheduleSnapshotRefresh(repositoryID: repository.id)
        var plan = BackupPlan()
        plan.path = source
        plan.repositoryID = repository.id
        if registersLoginItemOnSave(plan) { requestStartsAtLogin(true) }
        createPlan(plan)
        return plan.id
    }
}

/// A disk the first-run sheet offers: external, writable, on this Mac.
struct ExternalDisk: Equatable, Sendable {
    let name: String
    let path: String

    /// The repository folder on it: restic creates it.
    var repositoryFolder: String {
        (path as NSString).appendingPathComponent("SwiftRestic Backups")
    }

    struct Facts: Sendable {
        let name: String
        let path: String
        let isInternal: Bool
        let isLocal: Bool
        let isReadOnly: Bool
        let isRoot: Bool
    }

    static func offered(from volumes: [Facts]) -> [ExternalDisk] {
        volumes
            .filter { !$0.isInternal && $0.isLocal && !$0.isReadOnly && !$0.isRoot }
            .map { ExternalDisk(name: $0.name, path: $0.path) }
    }

    /// A volume whose facts macOS won't give is not offered: "Other…" still reaches it.
    static func mounted() -> [ExternalDisk] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return offered(from: urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let name = values.volumeName,
                  let isInternal = values.volumeIsInternal,
                  let isLocal = values.volumeIsLocal,
                  let isReadOnly = values.volumeIsReadOnly,
                  let isRoot = values.volumeIsRootFileSystem
            else { return nil }
            return Facts(name: name, path: url.path, isInternal: isInternal, isLocal: isLocal, isReadOnly: isReadOnly, isRoot: isRoot)
        })
    }
}
