import Foundation

extension AppModel {
    /// The first success is announced whatever the notification setting.
    func createPlan(_ plan: BackupPlan) {
        var plan = plan
        plan.announcesFirstBackup = true
        upsert(plan: plan)
        backUpIfScheduled(plan)
    }

    private func backUpIfScheduled(_ plan: BackupPlan) {
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
        let existed = try await service.repositoryExists(context, timeout: EditorRequirements.probeTimeout)
        if !existed {
            _ = try await service.initializeRepository(context)
        }
        await upsert(repository: repository, password: password, providerSecret: nil)
        await flushSave()
        if existed {
            // Read before the plan is made: it may continue a history here.
            await refreshListing(repositoryID: repository.id)
        } else {
            scheduleSnapshotRefresh(repositoryID: repository.id)
        }
        return createFirstPlan(source: source, repositoryID: repository.id)
    }

    /// Continues the folder's own history in the location when it has one
    /// (`continuedGroup`), as Continue Backups would; otherwise a new plan.
    func createFirstPlan(source: String, repositoryID: UUID) -> UUID {
        guard let group = continuedGroup(source: source, repositoryID: repositoryID),
              let draft = continuingDraft(repositoryID: repositoryID, group: group)
        else {
            let plan = BackupPlan(firstBackupOf: source, into: repositoryID)
            createPlan(plan)
            return plan.id
        }
        adopt(draft: draft)
        backUpIfScheduled(draft)
        return draft.id
    }

    /// A former plan's backups in the location, every one made on this Mac
    /// of exactly `source`. Nothing looser: retention runs per plan tag, so
    /// a tag two Macs back up under would have each remove the other's
    /// backups.
    private func continuedGroup(source: String, repositoryID: UUID) -> OtherBackupsGroup? {
        shelves(for: repositoryID).adoptableGroups(localHost: localHostname).first { group in
            guard case let .plan(_, snapshots) = group else { return false }
            return snapshots.allSatisfy { $0.hostname == localHostname && $0.paths == [source] }
        }
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
