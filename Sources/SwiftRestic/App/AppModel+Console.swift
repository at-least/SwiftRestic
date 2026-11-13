import Foundation

extension AppModel {
    func consoleDidAppear() {
        console.appear(repositoryID: configuration.repositories.first?.id)
    }

    /// Call before opening the window: its appear fills only an empty
    /// picker.
    func pointConsole(at repositoryID: UUID) {
        console.repositoryID = repositoryID
    }

    /// No `--json`: the console shows restic's human-readable output. The
    /// listing is re-read however the command ended: a forget can fail
    /// part-way.
    func runConsoleCommand(repositoryID: UUID, arguments: [String]) async -> String {
        // `self-update` would overwrite the bundled restic and break the
        // app's signature. Both the official and Homebrew's 0.19.1 have it.
        if CommandLineTokenizer.updatesRestic(arguments) {
            return "restic updates come with SwiftRestic."
        }
        guard let repository = repository(id: repositoryID) else {
            return "No such backup location."
        }
        defer {
            if CommandLineTokenizer.mayChangeSnapshots(arguments) { scheduleSnapshotRefresh(repositoryID: repositoryID) }
        }
        do {
            let (service, context) = try await resticContext(for: repository)
            let result = try await service.runRaw(context, arguments: arguments)
            return result.isEmpty ? "(no output)" : result
        } catch {
            noteAuthFailure(error, repositoryID: repositoryID)
            return error.localizedDescription
        }
    }
}
