import Foundation
import Testing

/// File ▸ Export Settings and Import Settings: what the file holds, what an
/// import takes from it and what stays with the Mac, the files it refuses,
/// and what the import does to the app around the configuration.
@MainActor
@Suite("settings export and import")
struct SettingsTransferTests {
    private let suiteName = "SwiftResticSettingsTransferTests"

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeModel(in directory: URL, secrets: SecretStore = .inMemory()) -> AppModel {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppModel(store: ConfigStore(directory: directory), secrets: secrets, defaults: defaults)
    }

    /// Whole seconds: the file's dates are ISO 8601, which keeps no
    /// fraction, and the round trips below compare whole values.
    private let stamp = Date(timeIntervalSince1970: 1_761_000_000)

    private func makeRepository(_ name: String) -> Repository {
        var repository = Repository()
        repository.kind = .local
        repository.localPath = "/Volumes/\(name)/restic"
        repository.createdAt = stamp
        return repository
    }

    private func makePlan(_ name: String, on repositoryID: UUID?) -> BackupPlan {
        var plan = BackupPlan()
        plan.repositoryID = repositoryID
        plan.path = "/Users/someone/\(name)"
        return plan
    }

    private func write(_ text: String, to directory: URL, name: String = "settings.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("an export holds the repositories, plans and settings, and leaves out the run history, the console's commands and the Pause Backups hold")
    func exportLeavesTheMachineState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory.appendingPathComponent("config"))
        let repository = makeRepository("NAS")
        var plan = makePlan("Documents", on: repository.id)
        plan.lastRunAt = stamp
        var channel = NotificationChannel()
        channel.url = "https://hc-ping.com/abc"
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        model.configuration.runs = [RunRecord(planID: plan.id, planName: "Documents")]
        model.configuration.settings.staleAlertDays = 3
        model.configuration.settings.notificationChannels = [channel]
        model.configuration.settings.networkShares = [NetworkShare(volumeName: "NAS", url: "smb://me@nas.local/NAS")]
        model.configuration.settings.consoleHistory = ["snapshots --json"]
        model.configuration.settings.schedulePause = SchedulePause(until: nil)

        let url = directory.appendingPathComponent("SwiftRestic Settings.json")
        model.exportSettings(to: url)

        let saved = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((saved["runs"] as? [Any])?.isEmpty == true)
        let settings = try #require(saved["settings"] as? [String: Any])
        #expect((settings["consoleHistory"] as? [Any])?.isEmpty == true)
        #expect(settings["schedulePause"] == nil)

        let read = try SettingsFile.read(from: url)
        #expect(read.name == "SwiftRestic Settings.json")
        #expect(read.configuration.repositories == [repository])
        #expect(read.configuration.plans == [plan])
        #expect(read.configuration.settings.staleAlertDays == 3)
        #expect(read.configuration.settings.notificationChannels == [channel])
        #expect(read.configuration.settings.networkShares == model.configuration.settings.networkShares)

        let banner = try #require(model.banners.first)
        #expect(banner.title == "Exported “SwiftRestic Settings.json”")
        #expect(banner.message == "The passwords SwiftRestic keeps in this Mac’s Keychain aren’t in it.")
        #expect(banner.revealPaths == [url.path])
        #expect(!banner.isError)
    }

    @Test("an export that cannot be written says so")
    func exportFailureIsReported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory.appendingPathComponent("config"))

        model.exportSettings(to: directory.appendingPathComponent("missing/SwiftRestic Settings.json"))

        let banner = try #require(model.banners.first)
        #expect(banner.title == "Could not export settings")
        #expect(banner.isError)
    }

    @Test("an import takes the file's repositories, plans and settings, keeps this Mac's history, console commands and hold, and one already here keeps this Mac's stamps")
    func importingKeepsTheMachineState() {
        let lastCheck = stamp.addingTimeInterval(86_400)
        let lastRun = stamp.addingTimeInterval(3_600)
        var mac = AppConfiguration()
        var here = makeRepository("NAS")
        here.maintenance.lastCheckAt = lastCheck
        var herePlan = makePlan("Documents", on: here.id)
        herePlan.lastRunAt = lastRun
        mac.repositories = [here]
        mac.plans = [herePlan]
        mac.runs = [RunRecord(planID: herePlan.id, planName: "Documents")]
        mac.settings.consoleHistory = ["check"]
        mac.settings.schedulePause = SchedulePause(until: stamp)

        var file = AppConfiguration()
        var moved = here
        moved.localPath = "/Volumes/Backup/restic"
        moved.maintenance.lastCheckAt = stamp
        moved.maintenance.checkIntervalDays = 14
        let added = makeRepository("Cloud")
        var changedPlan = herePlan
        changedPlan.lastRunAt = stamp
        changedPlan.excludePatterns = ["*.tmp"]
        var addedPlan = makePlan("Photos", on: added.id)
        addedPlan.lastRunAt = stamp
        file.repositories = [moved, added]
        file.plans = [changedPlan, addedPlan]
        file.runs = [RunRecord(planID: addedPlan.id, planName: "Photos")]
        file.settings.consoleHistory = ["forget"]
        file.settings.staleAlertDays = 9

        let imported = mac.importing(file)

        var expectedMoved = moved
        expectedMoved.maintenance.lastCheckAt = lastCheck
        #expect(imported.repositories == [expectedMoved, added])
        var expectedPlan = changedPlan
        expectedPlan.lastRunAt = lastRun
        #expect(imported.plans == [expectedPlan, addedPlan])
        #expect(imported.runs == mac.runs)
        #expect(imported.settings.consoleHistory == ["check"])
        #expect(imported.settings.schedulePause == mac.settings.schedulePause)
        #expect(imported.settings.staleAlertDays == 9)
    }

    @Test("a file that is not a settings file, or holds a setting that does not read, imports nothing")
    func unreadableFilesAreRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Tolerant decoding would read each of these as an empty
        // configuration.
        for text in ["{}", "[]", "not json", #"{"name": "package", "version": "1.0.0"}"#] {
            #expect(throws: SettingsFile.ReadError.notSettings, "\(text)") {
                try SettingsFile.read(from: write(text, to: directory))
            }
        }
        #expect(SettingsFile.ReadError.notSettings.localizedDescription == "It isn’t a SwiftRestic settings file.")

        let empty = try SettingsFile.read(from: write(#"{"repositories": [], "plans": []}"#, to: directory))
        #expect(empty.configuration.repositories.isEmpty)

        let damaged = try write(#"{"repositories": [], "plans": [], "settings": {"staleAlertDays": "seven"}}"#, to: directory)
        do {
            _ = try SettingsFile.read(from: damaged)
            Issue.record("a setting that does not read must refuse the file")
        } catch let SettingsFile.ReadError.unreadableSettings(fields) {
            #expect(fields == ["settings.staleAlertDays"])
            // The fields alone: the launch's note goes on "— the default (7)
            // is used", and nothing is used here.
            #expect(SettingsFile.ReadError.unreadableSettings(fields).localizedDescription
                == "Some of its settings can’t be read: “settings.staleAlertDays”.")
        }
    }

    @Test("a file that does not read posts why, under its name")
    func unreadableFileIsReported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory.appendingPathComponent("config"))

        #expect(model.settingsFile(at: try write("{}", to: directory, name: "notes.json")) == nil)

        let banner = try #require(model.banners.first)
        #expect(banner.title == "Could not import “notes.json”")
        #expect(banner.message == "It isn’t a SwiftRestic settings file.")
        #expect(banner.isError)
    }

    @Test("the confirmation names what the file holds and the work an import would stop")
    func confirmationWords() {
        let model = makeModel(in: FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsTransferTests-\(UUID().uuidString)"))
        let repository = makeRepository("NAS")
        var file = AppConfiguration()
        file.repositories = [repository]
        file.plans = [makePlan("Documents", on: repository.id), makePlan("Photos", on: repository.id)]
        let settings = SettingsFile(name: "SwiftRestic Settings.json", configuration: file)
        let idle = "Your repositories, plans and settings are replaced with the file’s: 1 repository and 2 plans. "
            + "Backups already written to repositories are not deleted. "
            + "A repository whose password isn’t on this Mac waits until you enter it in the repository editor."

        #expect(model.confirmationCopy(for: .importSettings(settings)) == ConfirmationCopy(
            title: "Replace your settings with “SwiftRestic Settings.json”?",
            message: idle
        ))

        let running = makePlan("Desktop", on: repository.id)
        model.configuration.plans = [running]
        model.activity[running.id] = PlanActivity()
        #expect(model.confirmationCopy(for: .importSettings(settings))?.message == idle
            + "\n\nA backup is running\nImporting stops the work in progress.")
    }

    @Test("an import replaces this Mac's repositories and plans, keeps its history, and deletes no password")
    func importReplacesTheConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = makeRepository("NAS")
        let removed = makeRepository("Old")
        let share = NetworkShare(volumeName: "Old", url: "smb://me@nas.local/Old")
        let secrets = SecretStore.inMemory([
            kept.id: (password: "kept-password", providerSecret: nil),
            removed.id: (password: "removed-password", providerSecret: "removed-secret"),
        ])
        try await secrets.saveSharePassword(share.id, "share-password")
        let model = makeModel(in: directory.appendingPathComponent("config"), secrets: secrets)
        let keptPlan = makePlan("Documents", on: kept.id)
        let removedPlan = makePlan("Archive", on: removed.id)
        let runs = [RunRecord(planID: removedPlan.id, planName: "Archive")]
        model.configuration.repositories = [kept, removed]
        model.configuration.plans = [keptPlan, removedPlan]
        model.configuration.runs = runs
        model.configuration.settings.networkShares = [share]
        model.snapshots[kept.id] = [try ResticMessageDecoder.jsonDecoder.decode(
            Snapshot.self,
            from: Data(#"{"id":"a1","time":"2026-10-02T02:00:00Z","paths":["/Users/someone/Documents"]}"#.utf8)
        )]
        // Delete Plan's bookkeeping, set with no run in flight, so its
        // removal below can only be the import's doing.
        model.problemsSeenAt[removedPlan.id] = .now

        let added = makeRepository("Cloud")
        let addedPlan = makePlan("Photos", on: added.id)
        // A plan whose repository the file does not hold: as at launch,
        // it is deleted.
        let strayPlan = makePlan("Stray", on: UUID())
        var file = AppConfiguration()
        file.repositories = [kept, added]
        file.plans = [keptPlan, addedPlan, strayPlan]
        model.importSettings(SettingsFile(name: "SwiftRestic Settings.json", configuration: file))

        #expect(model.configuration.repositories == [kept, added])
        #expect(model.configuration.plans == [keptPlan, addedPlan])
        #expect(model.configuration.settings.networkShares.isEmpty)
        #expect(model.configuration.runs == runs)
        #expect(model.problemsSeenAt[removedPlan.id] == nil)
        // A repository the file keeps is read again with its settings.
        #expect(model.snapshots(for: kept.id).isEmpty)
        #expect(model.banners.first?.title == "Imported “SwiftRestic Settings.json”")

        // Shut down first: it drains the background lane a removal deletes
        // passwords on. The Keychain may hold a repository's only copy.
        await model.shutdown()
        let stored = try await secrets.load(removed.id)
        #expect(stored.password == "removed-password")
        #expect(stored.providerSecret == "removed-secret")
        #expect(try await secrets.loadSharePassword(share.id) == "share-password")
    }

    @Test("Export Settings and Import Settings wait for the configuration, and stay off one that could not be read")
    func transferNeedsAReadableConfiguration() {
        let model = makeModel(in: FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsTransferTests-\(UUID().uuidString)"))
        #expect(!model.canTransferSettings)
        model.isLoaded = true
        #expect(model.canTransferSettings)
        model.isConfigurationUnreadable = true
        #expect(!model.canTransferSettings)
    }
}
