import Foundation
import Testing

@Suite("first backup")
@MainActor
struct FirstBackupTests {
    /// Against the installed restic: the sheet's whole job is what restic
    /// makes on disk.
    private func makeModel() throws -> (model: AppModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFirstBackup-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(store: ConfigStore(directory: root.appendingPathComponent("config")), secrets: .inMemory())
        model.resticSearch = .found(try ResticAvailability.binary(), version: "")
        // Never the daemon: xctest lives under /Applications, so it counts as
        // installed and the first scheduled plan would really register it.
        model.loginItemStateReader = { .off }
        model.loginItemApplier = { _ in }
        return (model, root)
    }

    private func makeSource(in root: URL) throws -> String {
        let source = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "kept".write(to: source.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        return source.path
    }

    @Test("the sheet's greyed Back Up asks in the order it asks: what, where, password")
    func requirementsInOrder() {
        func reason(source: String = "/Users/u/Documents", folder: String = "/Volumes/Disk/SwiftRestic Backups",
                    password: String = "pw", confirm: String = "pw", among: [Repository] = []) -> String? {
            EditorRequirements.firstBackup(
                source: source, folder: folder, password: password, confirmPassword: confirm, among: among
            )
        }
        #expect(reason(source: "", folder: "") == "Choose a folder to back up.")
        #expect(reason(folder: "") == "Choose where the backups go.")
        #expect(reason(password: "") == "Set a repository password to save it.")
        #expect(reason(confirm: "other") == "The passwords don’t match.")
        #expect(reason() == nil)
        var taken = Repository()
        taken.localPath = "/Volumes/Disk/SwiftRestic Backups"
        #expect(reason(among: [taken])?.contains("is already at this location") == true)
    }

    @Test("only a writable external disk on this Mac is offered, in a folder of its own")
    func offeredDisks() {
        func volume(_ name: String, isInternal: Bool = false, isLocal: Bool = true, isReadOnly: Bool = false, isRoot: Bool = false) -> ExternalDisk.Facts {
            .init(name: name, path: "/Volumes/\(name)", isInternal: isInternal, isLocal: isLocal, isReadOnly: isReadOnly, isRoot: isRoot)
        }
        let offered = ExternalDisk.offered(from: [
            volume("Macintosh HD", isInternal: true, isRoot: true),
            volume("Data", isInternal: true),
            volume("NAS", isLocal: false),
            volume("Installer", isReadOnly: true),
            volume("Archive SSD"),
        ])
        #expect(offered == [ExternalDisk(name: "Archive SSD", path: "/Volumes/Archive SSD")])
        #expect(offered.first?.repositoryFolder == "/Volumes/Archive SSD/SwiftRestic Backups")
    }

    @Test("the boot volume is never offered, on the real list")
    func mountedSkipsBootVolume() {
        #expect(!ExternalDisk.mounted().contains { $0.path == "/" })
    }

    @Test("a scheduled plan starts when created, and a Manually one waits for Back Up Now")
    func createdPlanStarts() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        var repository = Repository()
        repository.localPath = root.appendingPathComponent("repo").path
        await model.upsert(repository: repository, password: "pw", providerSecret: nil)

        var scheduled = BackupPlan()
        scheduled.path = try makeSource(in: root)
        scheduled.repositoryID = repository.id
        model.createPlan(scheduled)
        #expect(model.activity[scheduled.id] != nil)
        #expect(model.plan(id: scheduled.id)?.announcesFirstBackup == true)

        var manual = BackupPlan()
        manual.path = root.appendingPathComponent("other").path
        manual.repositoryID = repository.id
        manual.schedule.frequency = .manual
        model.createPlan(manual)
        #expect(model.activity[manual.id] == nil)
        await model.shutdown()
    }

    @Test("with no restic a created plan is saved and does not start")
    func createdPlanWithoutRestic() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let notFound = ResticError.binaryNotFound(searched: [])
        model.resticSearch = .refused(notFound, problem: notFound.localizedDescription)
        var plan = BackupPlan()
        plan.path = root.path
        model.createPlan(plan)
        #expect(model.plan(id: plan.id) != nil)
        #expect(model.activity.isEmpty)
    }

    @Test("Back Up makes the repository, keeps its password, backs up on the defaults and says so once")
    func firstBackupCreatesBoth() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeSource(in: root)
        let folder = root.appendingPathComponent("Disk/SwiftRestic Backups").path

        let planID = try await model.createFirstBackup(source: source, folder: folder, password: "pw")

        #expect(FileManager.default.fileExists(atPath: folder + "/config"))
        #expect(model.configuration.repositories.map(\.localPath) == [folder])
        let repositoryID = try #require(model.configuration.repositories.first?.id)
        let plan = try #require(model.plan(id: planID))
        #expect(plan.path == source)
        #expect(plan.repositoryID == repositoryID)
        #expect(plan.schedule.frequency == BackupPlan().schedule.frequency)
        #expect(plan.retention == BackupPlan().retention)
        #expect(try await model.storedSecrets(for: repositoryID).password == "pw")

        await model.tasks.drain()
        #expect(model.configuration.runs.first { $0.kind == .backup }?.outcome == .succeeded)
        #expect(model.plan(id: planID)?.announcesFirstBackup == false)
        await model.shutdown()
    }

    @Test("a repository already in the folder is joined with its own password, and a wrong one keeps nothing")
    func firstBackupOnAnExistingRepository() async throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Disk/Backups").path
        var existing = Repository()
        existing.localPath = folder
        _ = try await ResticService(runner: model.runner, binary: try ResticAvailability.binary().url)
            .initializeRepository(RepositoryContext(repository: existing, password: "right", providerSecret: nil))

        await #expect(throws: ResticError.self) {
            _ = try await model.createFirstBackup(source: "/a", folder: folder, password: "wrong")
        }
        #expect(model.configuration.repositories.isEmpty && model.configuration.plans.isEmpty)

        _ = try await model.createFirstBackup(source: try makeSource(in: root), folder: folder, password: "right")
        #expect(model.configuration.repositories.map(\.localPath) == [folder])
        await model.shutdown()
    }

    @Test("the first success is announced once, whatever the setting; another plan's is not")
    func firstSuccessAnnouncedOnce() {
        let model = AppModel(store: ConfigStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFirstNotice-\(UUID().uuidString)")), secrets: .inMemory())
        var fresh = BackupPlan()
        fresh.path = "/fresh"
        fresh.announcesFirstBackup = true
        var old = BackupPlan()
        old.path = "/old"
        model.configuration.plans = [fresh, old]
        #expect(!model.configuration.settings.notifyOnSuccess)

        func success(_ plan: BackupPlan) -> RunRecord {
            var record = RunRecord(kind: .backup, planID: plan.id, planName: plan.path, repositoryID: nil)
            record.outcome = .succeeded
            return record
        }
        #expect(!model.wantsNotification(for: success(old)))
        let first = success(fresh)
        #expect(model.wantsNotification(for: first))
        model.notify(about: first)
        #expect(model.plan(id: fresh.id)?.announcesFirstBackup == false)
        #expect(!model.wantsNotification(for: success(fresh)))
    }

    @Test("a first backup that ended with warnings keeps the announcement for the first success")
    func warningKeepsAnnouncement() {
        let model = AppModel(store: ConfigStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFirstNotice-\(UUID().uuidString)")), secrets: .inMemory())
        var plan = BackupPlan()
        plan.path = "/fresh"
        plan.announcesFirstBackup = true
        model.configuration.plans = [plan]
        var warned = RunRecord(kind: .backup, planID: plan.id, planName: plan.path, repositoryID: nil)
        warned.outcome = .completedWithErrors
        model.append(record: warned)
        model.notify(about: warned)
        #expect(model.plan(id: plan.id)?.announcesFirstBackup == true)
    }

    @Test("the announcement says when the next backup is, or how a Manually plan runs")
    func firstBackupWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var plan = BackupPlan()
        plan.path = "/Users/u/Documents"
        plan.schedule.frequency = .hourly
        plan.lastRunAt = now
        let scheduled = AppModel.firstBackupNotification(plan: plan, among: [plan], now: now)
        #expect(scheduled.title == "“Documents” is backed up")
        #expect(scheduled.body.hasPrefix("Next backup: "))
        plan.schedule.frequency = .manual
        #expect(AppModel.firstBackupNotification(plan: plan, among: [plan], now: now).body
            == "It backs up again when you click Back Up Now.")
    }

    @Test("a configuration saved before the announcement existed never announces, and a stored one survives an edit")
    func announcementDecodesOff() throws {
        let decoded = try JSONDecoder().decode(BackupPlan.self, from: Data(#"{"path":"/a"}"#.utf8))
        #expect(!decoded.announcesFirstBackup)
        var stored = decoded
        stored.announcesFirstBackup = true
        #expect(stored.merging(draft: decoded).announcesFirstBackup)
    }
}

@Suite("finding restic again")
@MainActor
struct FindResticAgainTests {
    private let workingVersion = "restic 0.19.1 compiled with go1.27.1 on darwin/arm64"

    private func makeModel(pathExists: Bool) throws -> (model: AppModel, root: URL, program: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFindAgain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let program = root.appendingPathComponent("restic")
        if pathExists { try install(program) }
        let model = AppModel(store: ConfigStore(directory: root), secrets: .inMemory())
        model.configuration.settings.resticPathOverride = program.path
        return (model, root, program)
    }

    private func install(_ program: URL) throws {
        try "#!/bin/sh\necho '\(workingVersion)'\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    }

    @Test("coming back after installing restic clears the block, with no relaunch")
    func activationFindsInstalledRestic() async throws {
        let (model, root, program) = try makeModel(pathExists: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.resolveBinary()
        #expect(!model.isResticAvailable)
        await model.findResticIfRefused()
        #expect(!model.isResticAvailable, "nothing installed yet")

        try install(program)
        await model.findResticIfRefused()
        #expect(model.isResticAvailable)
    }

    @Test("a working restic is not looked for again on every activation")
    func activationLeavesAWorkingRestic() async throws {
        let (model, root, program) = try makeModel(pathExists: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.resolveBinary()
        #expect(model.isResticAvailable)
        try FileManager.default.removeItem(at: program)
        await model.findResticIfRefused()
        #expect(model.isResticAvailable, "only a refusal looks again")
    }

    @Test("without restic neither form that needs it opens")
    func formsWaitForRestic() async throws {
        let (model, root, program) = try makeModel(pathExists: false)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.resolveBinary()
        var commands = model.repositoryCommands(for: nil)
        #expect(!commands.canAddRepository && !commands.canNewPlan)

        // A plan needs no restic to save into a repository that exists.
        model.configuration.repositories = [Repository()]
        commands = model.repositoryCommands(for: nil)
        #expect(!commands.canAddRepository && commands.canNewPlan)

        try install(program)
        await model.findResticAgain()
        #expect(model.repositoryCommands(for: nil).canAddRepository)
    }

    @Test("a missing restic says what to do, and an old one how to update")
    func setupWords() {
        #expect(ResticAbsence.missing.headline == "SwiftRestic needs restic to back up.")
        #expect(ResticAbsence.missing.guidance == "Install it, then come back. SwiftRestic finds it on its own.")
        #expect(ResticAbsence.missing.installCommand == "brew install restic")
        #expect(ResticAbsence.needsUpdate.installCommand == "brew upgrade restic")
        #expect(ResticAbsence.unusable.installCommand == nil && ResticAbsence.unusable.guidance == nil)
    }
}
