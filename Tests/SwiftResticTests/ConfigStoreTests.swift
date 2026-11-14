import Foundation
import Testing

/// A throwaway configuration directory, unique per call so a leaked one
/// stays attributable; `prefix` names the suite to blame.
private func temporaryDirectory(prefix: String = "SwiftResticConfig") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

@Suite("Configuration persistence")
struct ConfigStoreTests {
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
        repository.kind = .sftp
        repository.sftpHost = "nas.local"
        repository.sftpPath = "/volume1/restic"

        var plan = BackupPlan()
        plan.repositoryID = repository.id
        plan.path = "/Users/someone/Documents"
        plan.lastRunAt = Date(timeIntervalSince1970: 1_756_000_000)

        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        configuration.plans = [plan]
        configuration.runs = [RunRecord(planID: plan.id, planName: "Documents")]

        try await store.save(configuration)
        let loaded = try await store.load().configuration

        #expect(loaded.repositories.first?.sftpHost == "nas.local")
        #expect(loaded.plans.first?.path == "/Users/someone/Documents")
        #expect(loaded.plans.first?.lastRunAt == plan.lastRunAt)
        #expect(loaded.runs.count == 1)
    }

    @Test("a repository's extra environment stays out of config.json and is not read from it")
    func extraEnvironmentIsNotStored() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)
        var repository = Repository()
        repository.localPath = "/tmp/repo"
        repository.extraEnvironment = ["SWIFTRESTIC_STUB": "default"]
        var configuration = AppConfiguration()
        configuration.repositories = [repository]
        try await store.save(configuration)

        let written = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(!written.contains("extraEnvironment"))
        #expect(!written.contains("SWIFTRESTIC_STUB"))
        let decoded = try JSONDecoder().decode(
            Repository.self, from: Data(#"{"kind":"local","localPath":"/tmp/repo","extraEnvironment":{"A":"b"}}"#.utf8)
        )
        #expect(decoded.extraEnvironment.isEmpty)
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
            "path": "/tmp/src", "excludePatterns": [],
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
            plan.path = "/Users/someone/generation \(generation)"
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
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("no default exclude reaches into a Git repository, for new plans or ones saved without the key")
    func defaultExcludesSpareGit() throws {
        let decoded = try decode(BackupPlan.self, #"{"name":"Docs"}"#)
        for plan in [BackupPlan(), decoded] {
            #expect(plan.excludesToPass.contains(".DS_Store"), "the defaults must still apply")
            #expect(!plan.excludesToPass.contains { $0.contains(".git") })
        }
    }

    @Test("every default, pinned in order, and a new plan passes all of them and every developer rule, its own list empty")
    func defaultExcludesArePinned() {
        // The whole list, so a pattern typoed here fails this test instead
        // of only a real backup.
        #expect(ExcludeRule.defaults.map(\.pattern) == [
            ".DS_Store",
            "~/Library/Caches",
            "~/Library/Containers/*/Data/Library/Caches",
            "~/.Trash",
            "~/Library/Application Support/Steam",
            "~/Library/Logs",
            "~/Library/Metadata/CoreSpotlight",
            "~/Library/Saved Application State",
            "~/Library/HTTPStorages",
            "~/Library/Group Containers/*/Library/Caches",
            "~/Library/Mail/V*/MailData/Envelope Index*",
            "~/Pictures/*.photoslibrary/database/search",
            "~/Pictures/*.photoslibrary/resources/caches",
            "/Volumes/*/.Spotlight-V100",
            "/Volumes/*/.fseventsd",
            "/Volumes/*/.Trashes",
            "/Volumes/*/.DocumentRevisions-V100",
            "/Volumes/*/.TemporaryItems",
            "/System",
            "/private/var/vm",
            "/private/var/folders",
            "/private/tmp",
            "/Library/Caches",
            "/Library/Logs",
        ])
        // Whatever the path: a rule naming nothing under it matches nothing.
        var plan = BackupPlan()
        plan.path = "~/dotfiles"
        #expect(plan.excludePatterns.isEmpty)
        #expect(BackupPlan.appliedExcludes == (ExcludeRule.defaults + ExcludeRule.developer).map(\.pattern))
        #expect(plan.excludesToPass == BackupPlan.appliedExcludes)
    }

    @Test("every plan's applied rules make the run, beside the plan's own patterns, each once")
    func appliedRulesMakeTheRun() {
        var plan = BackupPlan()
        plan.excludePatterns = ["*.iso", "**/.venv"]
        #expect(plan.excludesToPass == BackupPlan.appliedExcludes + ["*.iso"])
        #expect(BackupPlan.withoutAppliedRules(plan.excludePatterns) == ["*.iso"])
    }

    @Test("a run leaves out the rules that name its source or a folder above it, and only those")
    func rulesCoveringTheSourceAreNotPassed() {
        let home = "/Users/probe"
        func covers(_ pattern: String, _ source: String) -> Bool {
            ResticService.pattern(ResticService.expandTilde(pattern, home: home), covers: source)
        }
        #expect(covers("~/Library/Caches", "/Users/probe/Library/Caches"))
        #expect(covers("~/Library/Caches", "/Users/probe/Library/Caches/com.example"))
        #expect(covers("/Volumes/*/.Trashes", "/Volumes/T7/.Trashes"))
        #expect(covers("/System", "/System/Library"))
        #expect(!covers("~/Library/Caches", "/Users/probe"))
        #expect(!covers("~/Library/Caches", "/Users/probe/Library/Logs"))
        #expect(!covers("/Volumes/*/.Trashes", "/Volumes/T7"))
        #expect(!covers(".DS_Store", "/Users/probe"))
        #expect(!covers("**/node_modules", "/Users/probe/web/node_modules"))
        // The path as given, as restic matches it: /var is a symlink restic
        // does not resolve.
        #expect(covers("/private/var/folders", "/private/var/folders/v5/T/src"))
        #expect(!covers("/private/var/folders", "/var/folders/v5/T/src"))
    }

    @Test("each developer group's rules, pinned in order")
    func developerExcludesArePinned() {
        // Pinned group by group in the list's own order, each group's folder
        // patterns before the home folder's, so a typoed or dropped pattern
        // fails here instead of only in a real backup.
        let groups: [(ExcludeCategory, folders: [String], home: [String])] = [
            (.python,
             ["**/.venv", "**/venv", "**/__pycache__", "**/.mypy_cache", "**/.pytest_cache", "**/.ruff_cache", "**/.tox", "**/.nox"],
             ["~/.cache/uv", "~/.local/share/uv/python", "~/.pyenv/versions",
              "~/miniconda3/pkgs", "~/miniforge3/pkgs", "~/anaconda3/pkgs"]),
            (.javascript,
             ["**/node_modules", "**/.next", "**/.nuxt", "**/.svelte-kit", "**/.parcel-cache", "**/.turbo", "**/.angular/cache"],
             ["~/.npm", "~/Library/pnpm/store", "~/.bun/install/cache", "~/.yarn/berry/cache", "~/.nvm/versions", "~/.volta/tools/image"]),
            (.apple,
             ["**/DerivedData", "**/.build", "**/Pods", "**/Carthage/Build"],
             ["~/.cocoapods/repos/trunk", "~/.cocoapods/repos/master", "~/Library/Developer/Xcode/*DeviceSupport",
              "~/Library/Developer/CoreDevice/DeviceFS"]),
            (.rust, [], ["~/.cargo/registry", "~/.cargo/git", "~/.rustup/toolchains"]),
            (.go, [], ["~/go/pkg/mod", "~/.goenv/versions"]),
            (.jvm, [],
             ["~/.m2/repository", "~/.gradle/caches", "~/.gradle/wrapper", "~/.gradle/jdks", "~/.gradle/daemon",
              "~/.konan/dependencies", "~/Library/Android/sdk"]),
            (.dart, ["**/.dart_tool"], ["~/.pub-cache", "~/fvm/versions"]),
            (.ruby, ["**/vendor/bundle"],
             ["~/.gem/ruby", "~/.gem/specs", "~/.bundle/cache", "~/.rbenv/versions", "~/.rubies", "~/.rvm/rubies", "~/.rvm/gems"]),
            (.php, ["**/.phpunit.cache", "**/.phpunit.result.cache", "**/.php-cs-fixer.cache"], ["~/.composer/cache"]),
            (.dotnet, [], ["~/.nuget/packages"]),
            (.elixir, ["**/_build", "**/.elixir_ls"], ["~/.hex/packages", "~/.cache/rebar3"]),
            (.haskell, ["**/.stack-work", "**/dist-newstyle"],
             ["~/.stack/programs", "~/.stack/snapshots", "~/.stack/pantry", "~/.cabal/packages", "~/.cabal/store",
              "~/.cache/cabal/packages", "~/.local/state/cabal/store", "~/.ghcup/ghc", "~/.ghcup/cache"]),
            (.scala, ["**/.bloop", "**/.metals", "**/.bsp"], ["~/.ivy2/cache", "~/.sbt/boot"]),
            (.julia, [],
             ["~/.julia/packages", "~/.julia/artifacts", "~/.julia/compiled", "~/.julia/registries", "~/.julia/juliaup"]),
            (.r, ["**/renv/library", "**/*.Rcheck"], []),
            (.cpp, ["**/cmake-build-*", "**/.cache/clangd", "**/.ccls-cache", "**/vcpkg_installed"], ["~/.conan2/p", "~/.conan/data"]),
            (.zig, ["**/.zig-cache", "**/zig-cache", "**/zig-out"], ["~/.cache/zig"]),
            (.ocaml, ["**/_opam"], ["~/.opam/download-cache"]),
            (.otherTools, ["**/.terraform", "**/.direnv"],
             ["~/.cache/pre-commit", "~/.asdf/installs", "~/.local/share/mise/installs", "~/.sdkman/candidates"]),
        ]
        for (group, folders, home) in groups {
            #expect(ExcludeRule.developer.filter { $0.category == group }.map(\.pattern) == folders + home, "\(group)")
        }
        #expect(ExcludeRule.developer.map(\.pattern) == groups.flatMap { $0.folders + $0.home })
        // Rust's target and .NET's obj go by their markers.
        #expect(ExcludeRule.developerMarkers.map(\.pattern) == [".rustc_info.json", "project.assets.json"])
    }

    @Test("every rule the app offers is labelled, once, and sits in an app category")
    func everyOfferedRuleIsLabelled() {
        let rules = ExcludeRule.defaults + ExcludeRule.developer + ExcludeRule.developerMarkers
        #expect(Set(rules.map(\.pattern)).count == rules.count)
        for rule in rules {
            #expect(!rule.what.isEmpty && !rule.why.isEmpty, "\(rule.pattern)")
        }
        let developerCategories = Set((ExcludeRule.developer + ExcludeRule.developerMarkers).map(\.category))
        #expect(ExcludeRule.defaults.allSatisfy { !developerCategories.contains($0.category) })
    }

    @Test("a plan's list sheds the rules the app now passes itself, keeping the user's own patterns")
    func listsShedAppliedRulesAtLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let home = NSHomeDirectory()
        let defaults = String(decoding: try JSONEncoder().encode(ExcludeRule.defaults.map(\.pattern)), as: UTF8.self)
        let python = String(decoding: try JSONEncoder().encode(["*.iso"] + ExcludeRule.developer.map(\.pattern)), as: UTF8.self)
        let json = """
        {
          "repositories": [{"id": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "kind": "local", "localPath": "/tmp/repo"}],
          "plans": [
            {"id": "5B0E7C2D-0000-4000-8000-000000000001", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "\(home)/dotfiles",
             "excludePatterns": [".DS_Store", "**/node_modules", "~/Library/Caches", "~/elsewhere/cache", "*.log"]},
            {"id": "5B0E7C2D-0000-4000-8000-000000000002", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~", "excludePatterns": \(defaults)},
            {"id": "5B0E7C2D-0000-4000-8000-000000000003", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Documents", "excludePatterns": \(defaults)},
            {"id": "5B0E7C2D-0000-4000-8000-000000000004", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "\(home)/Music"},
            {"id": "5B0E7C2D-0000-4000-8000-000000000005", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "\(home)/Library", "excludePatterns": []},
            {"id": "5B0E7C2D-0000-4000-8000-000000000006", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Code", "excludePatterns": \(python)},
            {"id": "5B0E7C2D-0000-4000-8000-000000000007", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Notes", "excludePatterns": [".DS_Store"], "skipsFinderFiles": false, "skipsSystemFiles": true}
          ],
          "runs": [],
          "settings": {}
        }
        """
        let file = directory.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: file)
        let store = ConfigStore(directory: directory)
        let loaded = try await store.load()
        #expect(loaded.decodeNotes.isEmpty)
        let plans = loaded.configuration.plans
        #expect(plans.map(\.excludePatterns) == [
            // The applied rules leave the list, whatever the path — the
            // developer rule **/node_modules among them; the user's own
            // stay, in their order.
            ["~/elsewhere/cache", "*.log"],
            [],
            [],
            [],
            [],
            // The developer rules leave the list too.
            ["*.iso"],
            // Passed by every plan, so a typed copy leaves the list.
            [],
        ])

        try await store.save(loaded.configuration)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let saved = try #require((object["plans"] as? [[String: Any]])?.first)
        #expect(saved["skipsFinderFiles"] == nil)
        #expect(saved["excludeCaches"] == nil)
        let reloaded = try await store.load().configuration.plans
        #expect(reloaded.map(\.excludePatterns) == plans.map(\.excludePatterns))
        #expect(reloaded.map(\.excludesToPass) == plans.map(\.excludesToPass))
    }

    @Test("a history saved before stretches were stored gets them at load; a stored one stands")
    func problemStretchesFilledAtLoad() throws {
        let plan = UUID()
        func backup(_ outcome: RunRecord.Outcome, stretch: Int? = nil) -> RunRecord {
            var run = RunRecord(kind: .backup, planID: plan)
            run.outcome = outcome
            if outcome == .completedWithErrors {
                run.exitCode = 3
                run.itemErrors = ["/a: open /a: permission denied"]
                run.itemErrorCount = 1
            }
            run.problemStretch = stretch
            return run
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var configuration = AppConfiguration()
        // Newest first, as stored: two warnings since a success, two before it.
        configuration.runs = [
            backup(.completedWithErrors), backup(.completedWithErrors), backup(.succeeded),
            backup(.completedWithErrors), backup(.completedWithErrors),
        ]
        let legacy = String(decoding: try encoder.encode(configuration), as: UTF8.self)
        #expect(!legacy.contains("problemStretch"))
        #expect(try decode(AppConfiguration.self, legacy).runs.map(\.problemStretch) == [2, 1, nil, 2, 1])

        // A stretch already stored is not counted again — what it counted may
        // be trimmed since — and the backup after it continues it.
        configuration.runs = [backup(.completedWithErrors), backup(.completedWithErrors, stretch: 7)]
        let stored = String(decoding: try encoder.encode(configuration), as: UTF8.self)
        #expect(try decode(AppConfiguration.self, stored).runs.map(\.problemStretch) == [8, 7])
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
        let legacy = try decode(
            RunRecord.self,
            #"{"bytesProcessed":250000,"dataAdded":900,"filesChanged":1,"filesNew":0,"filesUnmodified":16,"finishedAt":"2026-09-25T18:00:10Z","hookMessages":[],"id":"44444444-4444-4444-8444-000000000005","itemErrorCount":0,"itemErrors":[],"kind":"backup","outcome":"succeeded","planID":"22222222-2222-4222-8222-222222222222","planName":"Documents","repositoryID":"11111111-1111-4111-8111-111111111111","snapshotID":"abf728998814d029436dc76f64e5204a4d2336134e43b921a53e52e53144137f","startedAt":"2026-09-25T18:00:00Z"}"#
        )
        #expect(legacy.filesChanged == 1)
        #expect(legacy.exitCode == nil)
        #expect(legacy.resticVersion == nil)
        #expect(legacy.snapshotTime == nil)
        #expect(legacy.sourcePath == nil)
        #expect(legacy.destinationPath == nil)
        #expect(legacy.filesRestored == 0)
        #expect(legacy.filesSkipped == 0)

        var restore = RunRecord(kind: .restore, planName: "Budget.numbers")
        restore.snapshotID = "abf72899"
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

        let partial = try decode(RunRecord.self, #"{"kind":"backup","itemErrorTally":{"blockedByMacOS":2}}"#)
        #expect(partial.itemErrorTally == ItemErrorDiagnosis.Tally(blockedByMacOS: 2, deniedByFilePermissions: 0))
    }

    @Test("a plan's old timed pause and hour count are ignored")
    func oldPlanPauseFieldsDecode() throws {
        let on = try decode(BackupPlan.self, #"{"path":"/a","repositoryID":"7A1B0C2D-0000-4000-8000-000000000001","isEnabled":true,"pausedUntil":"2099-01-01T00:00:00Z","schedule":{"frequency":"hourly","intervalHours":12}}"#)
        #expect(on.schedule.frequency == .hourly)
        #expect(on.schedule.interval == 3600)
        #expect(on.runsOnSchedule)

        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(on)) as? [String: Any])
        #expect(written["isEnabled"] == nil && written["pausedUntil"] == nil)
        let schedule = try #require(written["schedule"] as? [String: Any])
        #expect(schedule["intervalHours"] == nil)
    }

    @Test("pause fields round-trip; missing reads as not paused; a pause without a readable end reads as not paused, never as forever")
    func pauseFieldsDecodeFailSafe() async throws {
        #expect(try decode(AppSettings.self, "{}").schedulePause == nil)

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
        var configuration = AppConfiguration()
        configuration.settings.schedulePause = SchedulePause(until: until)
        try await store.save(configuration)
        let loaded = try await store.load()
        #expect(loaded.decodeNotes.isEmpty)
        #expect(loaded.configuration.settings.schedulePause == SchedulePause(until: until))
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

        let plan = try decode(BackupPlan.self, #"{"schedule":{"frequency":"invented"}}"#)
        #expect(plan.schedule.frequency == .daily)

        let record = try decode(
            RunRecord.self,
            #"{"kind":"invented","outcome":"invented","planName":"Docs"}"#
        )
        #expect(record.kind == .backup)
        #expect(record.outcome == .succeeded)
        #expect(record.planName == "Docs")

        // The defaults above are substitutions, not readings: each one must
        // be reported so the app can surface what a newer build's fields
        // became when this older build read them.
        let recorded = notes.notes.joined(separator: "\n")
        #expect(recorded.contains("kind"))
        #expect(recorded.contains("frequency"))
        #expect(recorded.contains("outcome"))
        #expect(notes.notes.count == 4)
    }

    @Test("a field of the wrong type falls back to that field's default, neighbours survive")
    func wrongTypedValues() throws {
        let plan = try decode(
            BackupPlan.self,
            #"{"path":"/Users/someone/Documents","schedule":"not an object"}"#
        )
        #expect(plan.path == "/Users/someone/Documents")
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
        let directory = temporaryDirectory(prefix: "SwiftResticTolerant")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let json = """
        {
          "repositories": [{"name": "NAS", "kind": "local", "localPath": "/tmp/repo"}],
          "plans": [{"path": "/Users/someone/Documents", "schedule": "corrupted"}],
          "runs": []
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))

        let loaded = try await ConfigStore(directory: directory).load()
        #expect(loaded.configuration.repositories.first?.localPath == "/tmp/repo")
        let plan = try #require(loaded.configuration.plans.first)
        #expect(plan.path == "/Users/someone/Documents")
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
        repository.localPath = "/Users/someone/Survivor"
        configuration.repositories = [repository]
        try await store.save(configuration)
        // A second save is what puts the "Survivor" generation into .1.
        try await store.save(AppConfiguration())

        // The interrupted-save signature: the live file is gone, the previous
        // generation is all that is left. The store must read it and say so.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("config.json"))
        let loaded = try await store.load()
        #expect(loaded.recoveredFrom == "config.json.1")
        #expect(loaded.configuration.repositories.first?.localPath == "/Users/someone/Survivor")
    }

    @Test("a corrupt live file falls back to the newest generation that reads")
    func corruptLiveFileFallsBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConfigStore(directory: directory)

        var configuration = AppConfiguration()
        var repository = Repository()
        repository.localPath = "/Users/someone/Survivor"
        configuration.repositories = [repository]
        // After three saves the live file and .1 are empty, and .2 is the
        // first save's "Survivor".
        try await store.save(configuration)
        try await store.save(AppConfiguration())
        try await store.save(AppConfiguration())

        for name in ["config.json", "config.json.1"] {
            try Data("{ not json".utf8).write(to: directory.appendingPathComponent(name))
        }
        let loaded = try await store.load()
        #expect(loaded.recoveredFrom == "config.json.2")
        #expect(loaded.configuration.repositories.first?.localPath == "/Users/someone/Survivor")
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
            #expect(error.localizedDescription.contains("couldn’t be read"))
        }
    }

}

@Suite("configuration dates")
struct ConfigurationDateTests {
    @Test("dates keep their milliseconds through the file, and a file of whole seconds still reads")
    func millisecondsRoundTrip() throws {
        var plan = BackupPlan()
        let time = try #require(ResticDateFormat.parse("2026-09-05T00:53:25.22662+08:00"))
        plan.lastSuccessAt = time
        var configuration = AppConfiguration()
        configuration.plans = [plan]
        let data = try ConfigStore.encoded(configuration)
        #expect(String(decoding: data, as: UTF8.self).contains("\"2026-09-04T16:53:25.226Z\""))
        #expect(try ConfigStore.decoded(data).0.plans[0].lastSuccessAt == time)

        let older = Data(#"{"plans":[{"path":"/Users/someone/Documents","lastSuccessAt":"2026-09-04T16:53:25Z"}]}"#.utf8)
        #expect(try ConfigStore.decoded(older).0.plans[0].lastSuccessAt == Date(timeIntervalSince1970: 1_788_540_805))
    }
}
