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
        #expect(reason(password: "") == "Set a password to save it.")
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
        await eventually(within: 5) { model.plan(id: planID)?.announcesFirstBackup == false }
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
    func firstSuccessAnnouncedOnce() async {
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
        await eventually(within: 5) { model.plan(id: fresh.id)?.announcesFirstBackup == false }
        #expect(model.plan(id: fresh.id)?.announcesFirstBackup == false)
        #expect(!model.wantsNotification(for: success(fresh)))
    }

    @Test("with notifications not allowed the announcement waits, and the first success after they are allowed says it once")
    func announcementWaitsForPermission() async {
        let model = AppModel(store: ConfigStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticFirstNotice-\(UUID().uuidString)")), secrets: .inMemory())
        var plan = BackupPlan()
        plan.path = "/fresh"
        plan.announcesFirstBackup = true
        model.configuration.plans = [plan]
        func success() -> RunRecord {
            var record = RunRecord(kind: .backup, planID: plan.id, planName: plan.path, repositoryID: nil)
            record.outcome = .succeeded
            return record
        }

        var refused = 0
        model.notificationPoster = { _ in
            refused += 1
            throw AppModel.NotificationProblem.permissionDenied
        }
        model.notify(about: success())
        await eventually(within: 5) { refused == 1 && !model.banners.isEmpty }
        #expect(refused == 1)
        #expect(model.plan(id: plan.id)?.announcesFirstBackup == true)

        var posted: [String] = []
        model.notificationPoster = { posted.append($0.content.body) }
        model.notify(about: success())
        await eventually(within: 5) { model.plan(id: plan.id)?.announcesFirstBackup == false }
        #expect(posted.count == 1)
        #expect(posted.first == AppModel.firstBackupNotification(plan: plan, among: [plan], now: .now).body)

        model.notify(about: success())
        try? await Task.sleep(for: .milliseconds(200))
        #expect(posted.count == 1)
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

@Suite("locating a moved repository")
@MainActor
struct LocateRepositoryTests {
    private static let password = "pw"

    private func makeModel() async throws -> (model: AppModel, root: URL, repository: Repository) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLocate-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var repository = Repository()
        repository.localPath = root.appendingPathComponent("Old Home/repo").path
        let model = AppModel(
            store: ConfigStore(directory: root.appendingPathComponent("config")),
            secrets: .inMemory([repository.id: (password: Self.password, providerSecret: nil)])
        )
        model.resticSearch = .found(try ResticAvailability.binary(), version: "")
        _ = try await ResticAvailability.service().initializeRepository(
            RepositoryContext(repository: repository, password: Self.password, providerSecret: nil)
        )
        model.configuration.repositories = [repository]
        return (model, root, repository)
    }

    private func move(_ repository: Repository, in root: URL) throws -> String {
        let new = root.appendingPathComponent("New Home").path
        try FileManager.default.moveItem(atPath: repository.localPath, toPath: new)
        return new
    }

    @Test("the first listing records restic's ID, once, and an edit's draft can't lose it")
    func listingRecordsTheID() async throws {
        let (model, root, repository) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(repository.resticID == nil)
        await model.refreshSnapshots(repositoryID: repository.id)
        let recorded = try #require(model.repository(id: repository.id)?.resticID)
        #expect(recorded.count == 64)
        await model.upsert(repository: repository, password: nil, providerSecret: nil)
        #expect(model.repository(id: repository.id)?.resticID == recorded)
        await model.shutdown()
    }

    @Test("a config.json from before the ID decodes without one, and one with it keeps it")
    func idDecodes() throws {
        #expect(try JSONDecoder().decode(Repository.self, from: Data(#"{"localPath":"/a"}"#.utf8)).resticID == nil)
        #expect(try JSONDecoder().decode(Repository.self, from: Data(#"{"resticID":"abc"}"#.utf8)).resticID == "abc")
    }

    @Test("a moved folder fails with Locate as its fix, and Locate brings every backup back")
    func locateFindsTheMovedRepository() async throws {
        let (model, root, repository) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refreshSnapshots(repositoryID: repository.id)
        let new = try move(repository, in: root)

        await model.refreshSnapshots(repositoryID: repository.id)
        guard case let .failed(_, fix) = model.snapshotListingOutcome(for: repository.id) else {
            Issue.record("expected a failed listing")
            return
        }
        #expect(fix == .locate(repository.id))

        try await model.locateRepository(id: repository.id, atPath: new)
        #expect(model.repository(id: repository.id)?.localPath == new)
        await model.tasks.drain()
        await model.refreshSnapshots(repositoryID: repository.id)
        #expect(model.snapshotListingOutcome(for: repository.id) == .loaded)
        await model.shutdown()
    }

    @Test("a folder holding another repository is refused and the location stays")
    func locateRefusesAnotherRepository() async throws {
        let (model, root, repository) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refreshSnapshots(repositoryID: repository.id)
        var other = Repository()
        other.localPath = root.appendingPathComponent("Other").path
        _ = try await ResticAvailability.service().initializeRepository(
            RepositoryContext(repository: other, password: Self.password, providerSecret: nil)
        )
        await #expect(throws: LocateRefusal.differentRepository(name: model.label(of: repository))) {
            try await model.locateRepository(id: repository.id, atPath: other.localPath)
        }
        #expect(model.repository(id: repository.id)?.localPath == repository.localPath)
        await model.shutdown()
    }

    @Test("an empty folder, the wrong password and another location's path are each refused by name")
    func locateRefusals() async throws {
        let (model, root, repository) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.refreshSnapshots(repositoryID: repository.id)
        let name = model.label(of: repository)

        let empty = root.appendingPathComponent("Empty").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        await #expect(throws: LocateRefusal.noRepository) {
            try await model.locateRepository(id: repository.id, atPath: empty)
        }

        var locked = Repository()
        locked.localPath = root.appendingPathComponent("Locked").path
        _ = try await ResticAvailability.service().initializeRepository(
            RepositoryContext(repository: locked, password: "another", providerSecret: nil)
        )
        await #expect(throws: LocateRefusal.wrongPassword(name: name)) {
            try await model.locateRepository(id: repository.id, atPath: locked.localPath)
        }

        var twin = Repository()
        twin.localPath = root.appendingPathComponent("Twin").path
        model.configuration.repositories.append(twin)
        await #expect(throws: LocateRefusal.alreadySetUp(other: model.label(of: twin))) {
            try await model.locateRepository(id: repository.id, atPath: twin.localPath)
        }
        #expect(model.repository(id: repository.id)?.localPath == repository.localPath)
        await model.shutdown()
    }

    @Test("a repository never read here can't be proved the same, so Locate says to add it instead")
    func locateRefusesWithoutAnID() async throws {
        let (model, root, repository) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let new = try move(repository, in: root)
        await #expect(throws: LocateRefusal.neverRead(name: model.label(of: repository))) {
            try await model.locateRepository(id: repository.id, atPath: new)
        }
        #expect(model.repository(id: repository.id)?.localPath == repository.localPath)
    }

    @Test("exit 10 on a disk offers Locate; on a server, a new repository")
    func fixFollowsTheKind() {
        var run = RunRecord(kind: .backup, planID: UUID(), planName: "p", repositoryID: UUID())
        run.outcome = .failed
        run.exitCode = ResticError.repositoryMissingCode
        #expect(RunRecordPresentation.fix(for: run, repositoryExists: true, repositoryBusy: false, repositoryIsLocal: true)
            == .locate(run.repositoryID!))
        #expect(RunRecordPresentation.fix(for: run, repositoryExists: true, repositoryBusy: false, repositoryIsLocal: false)
            == .addRepository)
        #expect(RunFix.locate(UUID()).title == "Locate…")
    }

    @Test("a drive away says what comes next, truthfully for a Manually plan")
    func driveAwayWords() {
        let model = AppModel(store: ConfigStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticLocateWords-\(UUID().uuidString)")), secrets: .inMemory())
        var repository = Repository()
        repository.localPath = "/Volumes/Archive SSD/restic"
        var plan = BackupPlan()
        plan.path = "/a"
        plan.repositoryID = repository.id
        model.configuration.repositories = [repository]
        model.configuration.plans = [plan]
        #expect(model.driveAwayOutcome(repository) == .failed(
            "“Archive SSD” is not connected. Connect it and backups continue on their own.", fix: .locate(repository.id)
        ))
        model.configuration.plans[0].schedule.frequency = .manual
        #expect(model.driveAwayOutcome(repository) == .failed(
            "“Archive SSD” is not connected. Connect it to read its backups.", fix: .locate(repository.id)
        ))
    }
}

@Suite("Back Up Now on a repository's page")
@MainActor
struct RepositoryBackUpNowTests {
    @Test("it reaches every plan that can start, and a repository with none stays grey")
    func repositoryCommands() {
        let model = AppModel(store: ConfigStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticBackUpNow-\(UUID().uuidString)")), secrets: .inMemory())
        model.resticSearch = .found(ResticBinary(url: URL(fileURLWithPath: "/usr/bin/false")), version: "")
        var repository = Repository()
        repository.localPath = "/r"
        var empty = Repository()
        empty.localPath = "/e"
        var plan = BackupPlan()
        plan.path = "/a"
        plan.repositoryID = repository.id
        model.configuration.repositories = [repository, empty]
        model.configuration.plans = [plan]

        let state = model.planCommands(for: .repository(repository.id))
        #expect(state.canBackUp && state.repositoryPlanIDs == [plan.id])
        #expect(state.planID == nil && !state.canStop && !state.canEdit && !state.canDelete)
        #expect(!model.planCommands(for: .repository(empty.id)).canBackUp)
    }

    @Test("each line under the summary names the plan it opens")
    func linesOpenTheirPlan() {
        var plan = BackupPlan()
        plan.path = "/Users/u/Music"
        let row = ProtectionRow(plan: plan, among: [plan], stateText: "No backups yet", isKnown: true, isProtected: false, didFail: false)
        let summary = OverviewMetrics.protectionSummary(
            rows: [row], listingLoaded: true, otherBackupsCount: 0, willNotRun: { _ in nil }, hold: nil, now: .now
        )
        #expect(summary?.attentionLines == [ProtectionLine(planID: plan.id, text: "Music: No backups yet")])
    }
}

@Suite("Show Deleted Items' count")
@MainActor
struct ShowDeletedTitleTests {
    @Test("the checkbox says how many are behind it")
    func title() {
        #expect(FilesTree.showDeletedTitle(hidden: 0) == "Show Deleted Items")
        #expect(FilesTree.showDeletedTitle(hidden: 1) == "Show 1 Deleted Item")
        #expect(FilesTree.showDeletedTitle(hidden: 3) == "Show 3 Deleted Items")
    }
}
