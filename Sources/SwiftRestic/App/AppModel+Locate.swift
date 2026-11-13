import Foundation

/// Nothing is repointed on a guess: every plan of the repository would
/// back up into what it finds.
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
            "SwiftRestic hasn’t read “\(name)” on this Mac, so it can’t tell whether this is the same backup location. Add it where it is now as a new one."
        case let .differentRepository(name):
            "This folder holds different backups, so “\(name)” stays where it was."
        case .noRepository:
            "No backups are in this folder."
        case let .wrongPassword(name):
            "The password saved for “\(name)” doesn’t open the backups in this folder."
        case let .alreadySetUp(other):
            "“\(other)” is already at this location."
        case .busy:
            BackupPlan.busyRepositoryReason
        }
    }
}

extension AppModel {
    /// A failure is left to the next listing; until then Locate refuses
    /// with `LocateRefusal.neverRead`.
    func recordResticID(of repositoryID: UUID, service: any ResticClient, context: RepositoryContext) async {
        guard let id = try? await service.resticID(context, timeout: Self.refreshTimeout) else { return }
        updateRepository(repositoryID) { $0.resticID = id }
    }

    /// The index is keyed by the app's ID and never holds the location, so
    /// it stays good; restic keys its cache by the ID checked here.
    func locateRepository(id: UUID, atPath path: String) async throws {
        guard let repository = repository(id: id), repository.kind == .local else {
            throw ResticError.repositoryRemoved
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
        let context = try await Self.readContext(for: moved, label: name, secrets: secrets)
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
        rerunFailedBackups(in: id)
    }
}
