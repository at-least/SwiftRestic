import Foundation

/// Why Locate kept a repository where it was. Nothing is repointed on a
/// guess: every plan of the repository would back up into what it finds.
enum LocateRefusal: LocalizedError, Equatable {
    case neverRead(name: String)
    case differentRepository(name: String)
    case noRepository
    case wrongPassword(name: String)
    case alreadySetUp(other: String)
    case busy

    var errorDescription: String? {
        switch self {
        case let .neverRead(name):
            "SwiftRestic hasn’t read “\(name)” on this Mac, so it can’t tell whether this is the same repository. Add it where it is now as a new repository."
        case let .differentRepository(name):
            "This folder holds a different repository, so “\(name)” stays where it was."
        case .noRepository:
            "No repository is in this folder."
        case let .wrongPassword(name):
            "The password saved for “\(name)” doesn’t open the repository in this folder."
        case let .alreadySetUp(other):
            "“\(other)” is already at this location."
        case .busy:
            BackupPlan.busyRepositoryReason
        }
    }
}

extension AppModel {
    /// Called with what a successful listing could read. A failure is left
    /// to the next listing to ask again; until then Locate refuses and says
    /// why (`LocateRefusal.neverRead`).
    func recordResticID(of repositoryID: UUID, service: any ResticClient, context: RepositoryContext) async {
        guard let id = try? await service.resticID(context, timeout: Self.refreshTimeout) else { return }
        updateRepository(repositoryID) { $0.resticID = id }
    }

    /// A disk repository that moved: `path` becomes its location once restic
    /// says the repository there is this one. The index is keyed by the
    /// app's own ID and holds the backups' paths, never the location, so it
    /// stays good; restic keys its cache by the same ID checked here.
    func locateRepository(id: UUID, atPath path: String) async throws {
        guard let repository = repository(id: id), repository.kind == .local else {
            throw ResticError.repositoryMissing
        }
        var moved = repository
        moved.localPath = path
        let name = label(of: repository)
        if let other = configuration.repositories.first(where: {
            $0.id != id && ResticPath.normalized($0.resticRepositoryString) == ResticPath.normalized(moved.resticRepositoryString)
        }) {
            throw LocateRefusal.alreadySetUp(other: label(of: other))
        }
        guard !busyRepositoryIDs.contains(id) else { throw LocateRefusal.busy }
        guard let expected = repository.resticID else { throw LocateRefusal.neverRead(name: name) }

        let service = try service()
        let context = try await Self.dragContext(repository: moved, label: name, secrets: secrets)
        let found: String
        do {
            found = try await service.resticID(context, timeout: EditorRequirements.probeTimeout)
        } catch let ResticError.commandFailed(code, _) where code == ResticError.repositoryMissingCode {
            throw LocateRefusal.noRepository
        } catch let ResticError.commandFailed(code, _) where code == ResticError.wrongPasswordCode {
            throw LocateRefusal.wrongPassword(name: name)
        }
        guard found == expected else { throw LocateRefusal.differentRepository(name: name) }

        updateRepository(id) { $0.localPath = path }
        forgetContext(id)
        await flushSave()
        scheduleSnapshotRefresh(repositoryID: id)
    }
}
