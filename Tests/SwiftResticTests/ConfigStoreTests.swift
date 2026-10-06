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
        // The "chartIndex" above is a stored key the model does not
        // declare; a config carrying it must still load.

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

    @Test("no default exclude reaches into a Git repository, for new plans or ones saved without the key")
    func defaultExcludesSpareGit() throws {
        let decoded = try decode(BackupPlan.self, #"{"name":"Docs"}"#)
        for patterns in [BackupPlan().excludePatterns, decoded.excludePatterns] {
            #expect(!patterns.isEmpty, "the defaults must still apply")
            #expect(!patterns.contains { $0.contains(".git") })
        }
    }

    @Test("a run record from before the exit code was stored never claims a complete snapshot")
    func legacyRunRecordsNeverClaimComplete() throws {
        // Without an exit code, restic's per-item errors are the only trace
        // of an exit 3, and their absence proves nothing either way.
        let flagged = try decode(RunRecord.self, #"{"kind":"backup","snapshotID":"73d9b51d","itemErrorCount":1}"#)
        #expect(flagged.exitCode == nil)
        #expect(flagged.snapshotCompleteness == .incomplete)
        let silent = try decode(RunRecord.self, #"{"kind":"backup","snapshotID":"abf72899","itemErrorCount":0}"#)
        #expect(silent.snapshotCompleteness == .unknown)
        let clean = try decode(RunRecord.self, #"{"kind":"backup","snapshotID":"abf72899","exitCode":0}"#)
        #expect(clean.snapshotCompleteness == .complete)
        // A restore names the snapshot it read, never the state it was
        // written in; a backup that wrote nothing has no snapshot to judge.
        let restore = try decode(RunRecord.self, #"{"kind":"restore","snapshotID":"abf72899","exitCode":0}"#)
        #expect(restore.snapshotCompleteness == nil)
        let nothing = try decode(RunRecord.self, #"{"kind":"backup","exitCode":3}"#)
        #expect(nothing.snapshotCompleteness == nil)

        var partial = RunRecord()
        partial.snapshotID = "cafe0000"
        partial.exitCode = 3
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTripped = try decode(RunRecord.self, String(decoding: try encoder.encode(partial), as: UTF8.self))
        #expect(roundTripped.exitCode == 3)
        #expect(roundTripped.snapshotCompleteness == .incomplete)
    }

    @Test("a run record saved before logs and restore details decodes with safe defaults")
    func runRecordLogAndRestoreFieldsDefault() throws {
        // A verbatim record from a build that stored none of the log and
        // restore fields.
        let legacy = try decode(
            RunRecord.self,
            #"{"bytesProcessed":250000,"dataAdded":900,"filesChanged":1,"filesNew":0,"filesUnmodified":16,"finishedAt":"2026-09-25T18:00:10Z","hookMessages":[],"id":"44444444-4444-4444-8444-000000000005","itemErrorCount":0,"itemErrors":[],"kind":"backup","outcome":"succeeded","planID":"22222222-2222-4222-8222-222222222222","planName":"Documents","repositoryID":"11111111-1111-4111-8111-111111111111","snapshotID":"abf728998814d029436dc76f64e5204a4d2336134e43b921a53e52e53144137f","startedAt":"2026-09-25T18:00:00Z"}"#
        )
        #expect(legacy.filesChanged == 1)
        #expect(legacy.hasLog == false)
        #expect(legacy.exitCode == nil)
        #expect(legacy.resticVersion == nil)
        #expect(legacy.snapshotTime == nil)
        #expect(legacy.sourcePath == nil)
        #expect(legacy.destinationPath == nil)
        #expect(legacy.filesRestored == 0)
        #expect(legacy.filesSkipped == 0)

        var restore = RunRecord(kind: .restore, planName: "Budget.numbers")
        restore.snapshotID = "abf72899"
        restore.hasLog = true
        restore.exitCode = 0
        restore.resticVersion = "restic 0.19.1 compiled with go1.26.5 on darwin/arm64"
        restore.snapshotTime = Date(timeIntervalSince1970: 1_790_359_200)
        restore.sourcePath = "/src/Documents/Budget.numbers"
        restore.destinationPath = "/tmp/restored/Budget.numbers"
        restore.filesRestored = 1
        restore.filesSkipped = 2
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let roundTripped = try decode(RunRecord.self, String(decoding: try encoder.encode(restore), as: UTF8.self))
        #expect(roundTripped.hasLog)
        #expect(roundTripped.exitCode == 0)
        #expect(roundTripped.resticVersion == restore.resticVersion)
        #expect(roundTripped.snapshotTime == restore.snapshotTime)
        #expect(roundTripped.sourcePath == restore.sourcePath)
        #expect(roundTripped.destinationPath == restore.destinationPath)
        #expect(roundTripped.filesRestored == 1)
        #expect(roundTripped.filesSkipped == 2)
    }

    @Test("a run record saved before the Full Disk Access diagnosis decodes without one")
    func runRecordDiagnosisFieldsDefault() throws {
        // Absent must stay absent: a record without the tally or the stamp
        // reads nil, never a zero tally or a made-up state.
        let legacy = try decode(RunRecord.self, #"{"kind":"backup","itemErrorCount":1,"itemErrors":["open /x/locked.pdf: permission denied"]}"#)
        #expect(legacy.itemErrorTally == nil)
        #expect(legacy.fullDiskAccessAtRun == nil)

        var record = RunRecord()
        record.itemErrorTally = ItemErrorDiagnosis.Tally(blockedByMacOS: 60, deniedByFilePermissions: 1)
        record.fullDiskAccessAtRun = .notGranted
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        // The spellings config.json carries.
        #expect(json.contains(#""fullDiskAccessAtRun":"notGranted""#), "json was \(json)")
        let roundTripped = try decode(RunRecord.self, json)
        #expect(roundTripped.itemErrorTally == record.itemErrorTally)
        #expect(roundTripped.fullDiskAccessAtRun == .notGranted)

        // A tally written without one of its counts keeps the other.
        let partial = try decode(RunRecord.self, #"{"kind":"backup","itemErrorTally":{"blockedByMacOS":2}}"#)
        #expect(partial.itemErrorTally == ItemErrorDiagnosis.Tally(blockedByMacOS: 2, deniedByFilePermissions: 0))
    }

    @Test("pause fields round-trip; missing reads as not paused; an unreadable pause date reads as not paused, never as forever")
    func pauseFieldsDecodeFailSafe() async throws {
        #expect(try decode(BackupPlan.self, #"{"name":"Docs"}"#).pausedUntil == nil)
        #expect(try decode(AppSettings.self, "{}").schedulePause == nil)
        // An empty pause is the stored form of Until I Resume: no end.
        #expect(try decode(AppSettings.self, #"{"schedulePause":{}}"#).schedulePause == SchedulePause(until: nil))

        // A present date that does not read must not become "no end" — that
        // would stop every scheduled backup without a word. It reads as not
        // paused, and says so.
        let notes = DecodeNoteBox()
        let corrupt = try DecodeNotes.$current.withValue(notes) {
            try decode(AppSettings.self, #"{"schedulePause":{"until":"garbage"}}"#)
        }
        #expect(corrupt.schedulePause == nil)
        #expect(notes.notes.count == 1)
        #expect(notes.notes.first?.contains("schedulePause") == true, "notes were \(notes.notes)")

        // Whole seconds: config.json's ISO 8601 dates drop fractions.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)
        let until = Date(timeIntervalSince1970: 1_790_400_000)
        var plan = BackupPlan()
        plan.name = "Docs"
        plan.pausedUntil = until.addingTimeInterval(3600)
        var configuration = AppConfiguration()
        configuration.plans = [plan]
        configuration.settings.schedulePause = SchedulePause(until: until)
        try await store.save(configuration)
        let loaded = try await store.load()
        #expect(loaded.decodeNotes.isEmpty)
        #expect(loaded.configuration.settings.schedulePause == SchedulePause(until: until))
        #expect(loaded.configuration.plans.first?.pausedUntil == until.addingTimeInterval(3600))

        // And the open-ended pause survives a round trip as open-ended.
        configuration.settings.schedulePause = SchedulePause(until: nil)
        try await store.save(configuration)
        #expect(try await store.load().configuration.settings.schedulePause == SchedulePause(until: nil))
    }

    @Test("a run record stored with restic's trailing newline reads without it")
    func runRecordItemErrorsLoseTrailingWhitespace() throws {
        // config.json can hold item-error lines with their trailing newline;
        // only the tail goes — an item's own path at the head is never
        // touched. Every surface reads the lines through this decoder.
        let legacy = try decode(
            RunRecord.self,
            #"{"kind":"backup","itemErrorCount":2,"itemErrors":["/Users/u/Library/Safari: can not obtain extended attribute com.apple.macl for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.macl: operation not permitted\n"," /odd name : open  /odd name : permission denied\r\n","Retention skipped: repository is already locked \n"]}"#
        )
        #expect(legacy.itemErrors == [
            "/Users/u/Library/Safari: can not obtain extended attribute com.apple.macl for /Users/u/Library/Safari: xattr.get /Users/u/Library/Safari com.apple.macl: operation not permitted",
            " /odd name : open  /odd name : permission denied",
            "Retention skipped: repository is already locked",
        ])
        #expect(Array(legacy.unreadableItems) == Array(legacy.itemErrors.prefix(2)))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = String(decoding: try encoder.encode(legacy), as: UTF8.self)
        #expect(!saved.contains(#"\n"#), "saved again, the newline is gone: \(saved)")
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

    @Test("out-of-range schedule values clamp to the nearest runnable time, and say so")
    func outOfRangeScheduleClamps() throws {
        // A hand-edited "hour": 25 decodes cleanly and then never matches a
        // wall-clock time — the plan would silently never run. Clamping keeps
        // the plan alive at the nearest valid time and reports the edit.
        let decoder = JSONDecoder()
        let notes = DecodeNoteBox()
        let plan = try DecodeNotes.$current.withValue(notes) {
            try decoder.decode(
                BackupPlan.self,
                from: Data(#"{"schedule":{"frequency":"weekly","hour":25,"minute":99,"weekday":9}}"#.utf8)
            )
        }
        #expect(plan.schedule.hour == 23)
        #expect(plan.schedule.minute == 59)
        #expect(plan.schedule.weekday == 7)
        // A huge interval would trap the scheduler's `intervalHours * 3600`
        // the next time it ticks; zero renders "Every 0 hours".
        let hourly = try DecodeNotes.$current.withValue(notes) {
            try decoder.decode(
                BackupPlan.self,
                from: Data(#"{"schedule":{"frequency":"hourly","intervalHours":9000000000000000}}"#.utf8)
            )
        }
        #expect(hourly.schedule.intervalHours == 24)
        // The clamped plan schedules without trapping.
        _ = hourly.schedule.nextRunDate(after: nil, now: Date.now)
        let zeroPlan = try decoder.decode(
            BackupPlan.self,
            from: Data(#"{"schedule":{"frequency":"hourly","intervalHours":0}}"#.utf8)
        )
        #expect(zeroPlan.schedule.intervalHours == 1)
        let recorded = notes.notes.joined(separator: " · ")
        #expect(recorded.contains("hour"))
        #expect(recorded.contains("minute"))
        #expect(recorded.contains("weekday"))
        #expect(recorded.contains("intervalHours"))

        // In-range values pass through without a word.
        let quiet = try decoder.decode(
            BackupPlan.self,
            from: Data(#"{"schedule":{"frequency":"daily","hour":8,"minute":30}}"#.utf8)
        )
        #expect(quiet.schedule.hour == 8)
        #expect(quiet.schedule.minute == 30)
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
