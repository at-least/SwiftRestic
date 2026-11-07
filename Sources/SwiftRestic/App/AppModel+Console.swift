import Foundation

extension AppModel {
    func consoleDidAppear() {
        console.appear(repositoryID: configuration.repositories.first?.id)
    }

    /// Points the console at a repository before opening its window — the
    /// window's appear fills only an empty picker, so a route left to it
    /// would open on whichever repository the console last had, or the first.
    func pointConsole(at repositoryID: UUID) {
        console.repositoryID = repositoryID
    }

    /// No `--json` is added: the console exists to show restic's own output,
    /// and the human-readable form is what the user came for.
    ///
    /// A command that may change the backups (`mayChangeSnapshots`: a
    /// forget, a rewrite, a tag, a copy…) re-reads the repository's listing
    /// afterwards, however it ended — a forget can fail part-way — as a
    /// check or prune does, so the sidebar, the Files tabs and the counts
    /// do not list what restic no longer holds until the next refresh.
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
