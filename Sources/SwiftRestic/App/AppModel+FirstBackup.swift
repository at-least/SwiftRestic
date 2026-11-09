import Foundation

extension AppModel {
    /// A plan the user just created: it starts now, and its first success is
    /// announced whatever the notification setting. A Manually plan waits for
    /// its Back Up Now.
    func createPlan(_ plan: BackupPlan) {
        var plan = plan
        plan.announcesFirstBackup = true
        upsert(plan: plan)
        if plan.isScheduled, isResticAvailable {
            runBackup(planID: plan.id)
        }
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
        return createFirstPlan(source: source, repositoryID: repository.id)
    }

    /// A plan for `source` on today's defaults, into `repositoryID`: one the
    /// sheet just created, one the repository editor created for it, or one
    /// already set up that the sheet's destination named.
    func createFirstPlan(source: String, repositoryID: UUID) -> UUID {
        let plan = BackupPlan(firstBackupOf: source, into: repositoryID)
        createPlan(plan)
        return plan.id
    }
}

private extension BackupPlan {
    /// Today's defaults for `source`: what the first-run sheet creates and
    /// checks.
    init(firstBackupOf source: String, into repositoryID: UUID) {
        self.init()
        path = source
        self.repositoryID = repositoryID
    }
}

/// Where Back Up a Folder…'s sheet puts the backups.
enum FirstBackupDestination: Hashable {
    /// A location already set up.
    case location(UUID)
    /// A folder for a new location: a disk's, or one chosen with Other….
    case folder(String)

    /// What the sheet opens on with locations set up: the one whose page is
    /// on screen, else the one added last (the only one, when there is one).
    static func initial(onScreen: UUID?, among repositories: [Repository]) -> FirstBackupDestination? {
        if let onScreen, repositories.contains(where: { $0.id == onScreen }) { return .location(onScreen) }
        return repositories.last.map { .location($0.id) }
    }

    /// The sheet's greyed Back Up, in the order it asks: what, where, the
    /// password. `holdsBackups` is `EditorRequirements.holdsBackups(atLocalPath:)`
    /// for a folder.
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
        #if DEBUG
        // The UI tests' disk (SwiftResticUITests): a folder standing in for the
        // only disk on the Mac. Not a disk image: macOS gives an attached image
        // no isInternal, so it is never offered.
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
