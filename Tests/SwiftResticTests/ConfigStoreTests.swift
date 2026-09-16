import Foundation
import Testing

@Suite("Configuration persistence")
struct ConfigStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticConfig-\(UUID().uuidString)")
    }

    @Test("a missing config file is not an error")
    func missingFile() async throws {
        let store = ConfigStore(directory: temporaryDirectory())
        let loaded = try await store.load()
        #expect(loaded.configuration.plans.isEmpty)
        #expect(loaded.configuration.repositories.isEmpty)
        #expect(loaded.recoveredFrom == nil)
        #expect(loaded.decodeNotes.isEmpty)
    }

    @Test("configuration survives a save/load round trip")
    func roundTrip() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)

        var repository = Repository()
        repository.name = "NAS"
        repository.kind = .sftp
        repository.sftpHost = "nas.local"
        repository.sftpPath = "/volume1/restic"

        var plan = BackupPlan()
        plan.name = "Documents"
        plan.repositoryID = repository.id
        plan.sources = ["/Users/someone/Documents"]
        plan.lastRunAt = Date(timeIntervalSince1970: 1_756_000_000)

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.runs = [RunRecord(planID: plan.id, planName: plan.name)]
        configuration.settings.uploadLimitKiBps = 512

        try await store.save(configuration)
        let loaded = try await store.load().configuration

        #expect(loaded.repositories.first?.sftpHost == "nas.local")
        #expect(loaded.plans.first?.name == "Documents")
        #expect(loaded.plans.first?.lastRunAt == plan.lastRunAt)
        #expect(loaded.runs.count == 1)
        #expect(loaded.settings.uploadLimitKiBps == 512)
    }

    @Test("a hand-written config decodes: every stored key must be accepted")
    func handWrittenConfig() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let json = """
        {
          "repositories": [{
            "id": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "name": "Smoke Repo", "kind": "local",
            "createdAt": "2026-09-05T00:00:00Z", "localPath": "/tmp/repo",
            "sftpUser": "", "sftpHost": "", "sftpPath": "",
            "s3Endpoint": "s3.amazonaws.com", "s3Bucket": "", "s3Prefix": "", "s3AccessKeyID": "",
            "b2Bucket": "", "b2Prefix": "", "b2AccountID": "", "restURL": "",
            "extraEnvironment": {}
          }],
          "plans": [{
            "id": "340CA842-C653-4E2D-B61F-D7653D70A521", "name": "Smoke Plan",
            "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
            "sources": ["/tmp/src"], "excludePatterns": [],
            "excludeCaches": true, "oneFileSystem": false, "tags": [],
            "schedule": {"frequency": "hourly", "intervalHours": 1, "hour": 2, "minute": 0, "weekday": 2},
            "retention": {"isEnabled": true, "keepLast": 3, "keepHourly": 0, "keepDaily": 0,
                          "keepWeekly": 0, "keepMonthly": 0, "keepYearly": 0, "runPrune": false},
            "isEnabled": true, "chartIndex": 2
          }],
          "runs": [],
          "settings": {"resticPathOverride": "", "showMenuBarExtra": true, "notifyOnSuccess": false,
                       "notifyOnFailure": true, "maxRunHistory": 300, "uploadLimitKiBps": 0,
                       "downloadLimitKiBps": 0, "pauseOnBattery": false}
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let loaded = try await ConfigStore(directory: directory).load().configuration
        #expect(loaded.repositories.count == 1)
        #expect(loaded.plans.count == 1)
        #expect(loaded.plans.first?.schedule.frequency == .hourly)
        // A plan's palette slot is stored, so its colour survives relaunch.
        #expect(loaded.plans.first?.chartIndex == 2)

        // A plan that has never run and is on an interval schedule must be due
        // straight away, which is what makes the app back up shortly after launch.
        let due = Scheduler.duePlans(
            in: loaded.plans,
            existingRepositoryIDs: Set(loaded.repositories.map(\.id))
        )
        #expect(due.count == 1)
    }

    @Test("the two previous generations survive behind the live file")
    func rotatingBackups() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)

        func save(generation: Int) async throws {
            var configuration = AppConfiguration()
            var plan = BackupPlan()
            plan.name = "generation \(generation)"
            configuration.plans = [plan]
            try await store.save(configuration)
        }

        try await save(generation: 0)
        try await save(generation: 1)
        try await save(generation: 2)

        func text(of file: String) throws -> String {
            try String(
                data: Data(contentsOf: directory.appendingPathComponent(file)),
                encoding: .utf8
            ) ?? ""
        }

        #expect(try text(of: "config.json").contains("generation 2"))
        #expect(try text(of: "config.json.1").contains("generation 1"))
        #expect(try text(of: "config.json.2").contains("generation 0"))
    }
}

/// The hand-written config above covers *missing* keys. These cover *malformed*
/// ones: a value of the wrong type, or an enum case a newer build invented, must
/// fall back to the field's default instead of failing the whole document — and
/// the substitution must be reported, never silent.
@Suite("Tolerant decoding")
struct TolerantDecodingTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticConfig-\(UUID().uuidString)")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("an unknown enum raw value falls back to the default case, and says so")
    func unknownEnumCases() throws {
        let decoder = JSONDecoder()
        let notes = DecodeNoteBox()

        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
            try DecodeNotes.$current.withValue(notes) {
                try decoder.decode(T.self, from: Data(json.utf8))
            }
        }

        let repository = try decode(
            Repository.self,
            #"{"name":"NAS","kind":"invented-by-a-newer-build"}"#
        )
        #expect(repository.kind == .local)
        #expect(repository.name == "NAS")

        let plan = try decode(BackupPlan.self, #"{"schedule":{"frequency":"invented"}}"#)
        #expect(plan.schedule.frequency == .daily)

        let record = try decode(
            RunRecord.self,
            #"{"kind":"invented","outcome":"invented","planName":"Docs"}"#
        )
        #expect(record.kind == .backup)
        #expect(record.outcome == .succeeded)
        #expect(record.planName == "Docs")

        let channel = try decode(
            NotificationChannel.self,
            #"{"kind":"invented","url":"https://example.com"}"#
        )
        #expect(channel.kind == .webhook)
        #expect(channel.url == "https://example.com")

        let hook = try decode(
            BackupHook.self,
            #"{"event":"invented","failureBehaviour":"invented","command":"true"}"#
        )
        #expect(hook.event == .afterSuccess)
        #expect(hook.failureBehaviour == .ignore)
        #expect(hook.command == "true")

        // The defaults above are substitutions, not readings: each one must
        // be reported so the app can surface what a newer build's fields
        // became when this older build read them.
        let recorded = notes.notes.joined(separator: "\n")
        #expect(recorded.contains("kind"))
        #expect(recorded.contains("frequency"))
        #expect(recorded.contains("outcome"))
        #expect(recorded.contains("failureBehaviour"))
        #expect(notes.notes.count == 7)
    }

    @Test("a field of the wrong type falls back to that field's default, neighbours survive")
    func wrongTypedValues() throws {
        // keepLast is a string; keepDaily is untouched next to it.
        let plan = try decode(
            BackupPlan.self,
            #"{"name":"Documents","retention":{"keepLast":"many"},"schedule":"not an object"}"#
        )
        #expect(plan.name == "Documents")
        #expect(plan.retention.keepLast == 0)
        #expect(plan.retention.keepDaily == 7)
        #expect(plan.schedule == Schedule())

        let repository = try decode(
            Repository.self,
            #"{"name":"NAS","maintenance":42,"localPath":"/tmp/repo"}"#
        )
        #expect(repository.maintenance == MaintenancePolicy())
        #expect(repository.localPath == "/tmp/repo")
    }

    @Test("a config file with a malformed field still loads through the store")
    func malformedConfigLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftResticTolerant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let json = """
        {
          "repositories": [{"name": "NAS", "kind": "local", "localPath": "/tmp/repo"}],
          "plans": [{"name": "Documents", "schedule": "corrupted"}],
          "runs": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let loaded = try await ConfigStore(directory: directory).load()
        #expect(loaded.configuration.repositories.first?.localPath == "/tmp/repo")
        let plan = try #require(loaded.configuration.plans.first)
        #expect(plan.name == "Documents")
        #expect(plan.schedule == Schedule())
        #expect(plan.retention == RetentionPolicy())
        // Tolerance is not silence: the substitution the plan's corrupted
        // schedule needed must be one of the load's notes.
        #expect(loaded.decodeNotes.contains { $0.contains("plans[0].schedule") })
    }

    @Test("a live file gone missing recovers from the previous generation")
    func missingLiveFileRecoversFromBackup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)

        var configuration = AppConfiguration()
        var repository = Repository()
        repository.name = "Survivor"
        configuration.repositories = [repository]
        try await store.save(configuration)
        // A second save is what puts the "Survivor" generation into .1.
        try await store.save(AppConfiguration())

        // The interrupted-save signature: the live file is gone, the previous
        // generation is all that is left. The store must read it and say so.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
        let loaded = try await store.load()
        #expect(loaded.recoveredFrom == "config.json.1")
        #expect(loaded.configuration.repositories.first?.name == "Survivor")
    }

    @Test("a corrupt live file falls back to the newest generation that reads")
    func corruptLiveFileFallsBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)

        var configuration = AppConfiguration()
        var repository = Repository()
        repository.name = "Survivor"
        configuration.repositories = [repository]
        try await store.save(configuration)
        try await store.save(AppConfiguration())  // generation .1: an empty config
        try await store.save(AppConfiguration())  // generation .2: the "Survivor" config

        // Corrupt both the live file and .1: .2 still holds "Survivor".
        for name in ["config.json", "config.json.1"] {
            try Data("{ not json".utf8).write(to: directory.appendingPathComponent(name))
        }
        let loaded = try await store.load()
        #expect(loaded.recoveredFrom == "config.json.2")
        #expect(loaded.configuration.repositories.first?.name == "Survivor")
    }

    @Test("no readable generation anywhere is an error naming the failure")
    func nothingReadableThrows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("config.json"))

        do {
            _ = try await ConfigStore(directory: directory).load()
            Issue.record("a corrupt configuration must not load as anything")
        } catch let error as ConfigStore.ConfigError {
            #expect(error.localizedDescription.contains("could not be read"))
        }
    }
}
