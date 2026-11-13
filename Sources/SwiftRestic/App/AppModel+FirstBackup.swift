import Foundation

extension AppModel {
    /// The first success is announced whatever the notification setting.
    func createPlan(_ plan: BackupPlan) {
        var plan = plan
        plan.announcesFirstBackup = true
        upsert(plan: plan)
        if plan.isScheduled, isResticAvailable {
            runBackup(planID: plan.id)
        }
    }

    /// The repository is created before it is kept, so a throw keeps
    /// nothing.
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
        return createFirstPlan(source: source, repositoryID: repository.id)
    }

    func createFirstPlan(source: String, repositoryID: UUID) -> UUID {
        let plan = BackupPlan(firstBackupOf: source, into: repositoryID)
        createPlan(plan)
        return plan.id
    }

    /// nil leaves it to the sheet.
    func backUpWithoutSheet(source: String, destination: FirstBackupDestination?) -> UUID? {
        guard case let .location(repositoryID) = destination,
              FirstBackupDestination.requirement(
                  source: source, destination: destination, password: "", confirmPassword: "",
                  holdsBackups: false, plans: configuration.plans, repositories: configuration.repositories
              ) == nil,
              fullDiskAccessNotice(for: source) == nil
        else { return nil }
        return createFirstPlan(source: source, repositoryID: repositoryID)
    }
}

private extension BackupPlan {
    init(firstBackupOf source: String, into repositoryID: UUID) {
        self.init()
        path = source
        self.repositoryID = repositoryID
    }
}

/// Where Back Up a Folder…'s sheet puts the backups.
enum FirstBackupDestination: Hashable {
    case location(UUID)
    /// A folder for a new location.
    case folder(String)

    static func initial(onScreen: UUID?, among repositories: [Repository]) -> FirstBackupDestination? {
        if let onScreen, repositories.contains(where: { $0.id == onScreen }) { return .location(onScreen) }
        return repositories.last.map { .location($0.id) }
    }

    /// `holdsBackups` is `EditorRequirements.holdsBackups(atLocalPath:)` for
    /// a folder.
    static func requirement(
        source: String,
        destination: FirstBackupDestination?,
        password: String,
        confirmPassword: String,
        holdsBackups: Bool,
        plans: [BackupPlan],
        repositories: [Repository]
    ) -> String? {
        if source.isEmpty { return "Choose a folder to back up." }
        switch destination {
        case nil:
            return "Choose where the backups go."
        case let .location(id):
            if let repository = repositories.first(where: { $0.id == id }), repository.kind == .local,
               let inside = EditorRequirements.backupsInside(source: source, folder: repository.resolvedLocalPath) {
                return inside
            }
            return EditorRequirements.plan(BackupPlan(firstBackupOf: source, into: id), isNew: true, among: plans)
        case let .folder(folder):
            return EditorRequirements.firstBackup(
                source: source, folder: folder, password: password,
                confirmPassword: confirmPassword, holdsBackups: holdsBackups, among: repositories
            )
        }
    }
}

/// A disk the first-run sheet offers: external, writable, on this Mac.
struct ExternalDisk: Equatable, Sendable {
    let name: String
    let path: String

    /// restic creates it.
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

    static func mounted() -> [ExternalDisk] {
        #if DEBUG
        // A folder, not a disk image: macOS gives an attached image no
        // isInternal, so it is never offered.
        if let path = ProcessInfo.processInfo.environment["SWIFTRESTIC_DISK"] {
            return [ExternalDisk(name: (path as NSString).lastPathComponent, path: path)]
        }
        #endif
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
