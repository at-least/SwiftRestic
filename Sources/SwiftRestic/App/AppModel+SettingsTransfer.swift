import Foundation

extension AppModel {
    // MARK: - Export Settings and Import Settings

    /// Once the configuration has loaded, and never over one that could not
    /// be read: nothing imported would be saved (`flushSave`), and an
    /// export would write the empty stand-in.
    var canTransferSettings: Bool { isLoaded && !isConfigurationUnreadable }

    func exportSettings(to url: URL) {
        do {
            try ConfigStore.encoded(configuration.exported).write(to: url, options: [.atomic])
            post(Banner(
                title: "Exported “\(url.lastPathComponent)”",
                message: "The passwords SwiftRestic keeps in this Mac’s Keychain aren’t in it.",
                isError: false,
                revealPaths: [url.path]
            ))
        } catch {
            post(Banner(title: "Could not export settings", message: error.localizedDescription, isError: true))
        }
    }

    /// The file Import Settings chose, read for its confirmation; nil, with
    /// the reason in a banner, when it does not read.
    func settingsFile(at url: URL) -> SettingsFile? {
        do {
            return try SettingsFile.read(from: url)
        } catch {
            post(Banner(
                title: "Could not import “\(url.lastPathComponent)”",
                message: error.localizedDescription,
                isError: true
            ))
            return nil
        }
    }

    func importConfirmationCopy(for file: SettingsFile) -> ConfirmationCopy {
        let incoming = file.configuration
        var message = "Your repositories, plans and settings are replaced with the file’s: "
            + "\(Format.plural(incoming.repositories.count, "repository", "repositories")) and "
            + "\(Format.plural(incoming.plans.count, "plan")). Backups already written to repositories are not deleted. "
            + "A repository whose password isn’t on this Mac waits until you enter it in the repository editor."
        // The quit alert's list of work in flight. Not "Activity records
        // it": a console command never reaches Activity.
        let interruptions = quitInterruptions
        if !interruptions.isEmpty {
            message += "\n\n" + interruptions.joined(separator: "\n") + "\nImporting stops the work in progress."
        }
        return ConfirmationCopy(title: "Replace your settings with “\(file.name)”?", message: message)
    }

    /// Import Settings, confirmed: the file's repositories, plans and
    /// settings take the place of this Mac's (`AppConfiguration.importing`).
    ///
    /// Work in flight stops first, and the runs' unwind records it as
    /// cancelled. Every repository's runtime state goes, a
    /// repository the file keeps too: its listing is read again with the
    /// imported settings. A plan the file does not hold goes through Delete
    /// Plan's bookkeeping, and a repository it does not hold takes its index
    /// files along, as a removal does.
    ///
    /// No password is deleted, unlike a removal: the Keychain may hold a
    /// repository's only copy of its password, and importing a file that
    /// holds the repository again must find it.
    func importSettings(_ file: SettingsFile) {
        let incoming = file.configuration
        tasks.cancelSlots()
        console.cancelRunningCommand()
        // Before the repository list changes, in removal's order.
        for repository in configuration.repositories {
            clearRuntimeState(repositoryID: repository.id)
        }
        let incomingPlanIDs = Set(incoming.plans.map(\.id))
        for plan in configuration.plans where !incomingPlanIDs.contains(plan.id) {
            deletePlan(id: plan.id)
        }
        let incomingRepositoryIDs = Set(incoming.repositories.map(\.id))
        let leaving = configuration.repositories.map(\.id).filter { !incomingRepositoryIDs.contains($0) }
        configuration = configuration.importing(incoming)
        deletePlansWithoutRepository()
        for id in leaving {
            tasks.addBackground(Task { [indexCoordinator] in
                await indexCoordinator.dropRepository(repositoryID: id)
            })
        }
        Task { await refreshAllSnapshots() }
        post(Banner(title: "Imported “\(file.name)”", message: "", isError: false))
    }
}
