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
        repository.kind = .sftp
        repository.sftpHost = "nas.local"
        repository.sftpPath = "/volume1/restic"
        repository.uploadLimitKiBps = 512

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
        #expect(loaded.repositories.first?.uploadLimitKiBps == 512)
        #expect(loaded.plans.first?.path == "/Users/someone/Documents")
        #expect(loaded.plans.first?.lastRunAt == plan.lastRunAt)
        #expect(loaded.runs.count == 1)
    }

    @Test("an app-wide rate limit saved by an earlier build moves to the repositories reached over a network, once")
    func appWideRateLimitsMove() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // An earlier build's one pair in Settings held back every
        // repository, a disk on this Mac too.
        let json = """
        {
          "repositories": [
            {"name": "Desk Drive", "kind": "local", "localPath": "/Volumes/Archive SSD/restic"},
            {"name": "Home Folder", "kind": "local", "localPath": "~/restic"},
            {"name": "NAS Share", "kind": "local", "localPath": "/Volumes/NAS/restic"},
            {"name": "NAS", "kind": "sftp", "sftpHost": "nas.local", "sftpPath": "/volume1/restic"},
            {"name": "Cloud", "kind": "b2", "b2Bucket": "photos"}
          ],
          "plans": [],
          "runs": [],
          "settings": {"uploadLimitKiBps": 512, "downloadLimitKiBps": 2048,
                       "networkShares": [{"id": "6A1E1A2B-0000-4000-8000-000000000001",
                                          "volumeName": "NAS", "url": "smb://me@nas.local/NAS"}]}
        }
        """
        let file = directory.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: file)

        // Each repository by what the app calls it — where it is; the names
        // that earlier build stored are not read.
        func limits(_ configuration: AppConfiguration) -> [String: [Int]] {
            Dictionary(uniqueKeysWithValues: configuration.repositories.map {
                ($0.label(among: configuration.repositories), [$0.uploadLimitKiBps, $0.downloadLimitKiBps])
            })
        }
        let store = ConfigStore(directory: directory)
        let loaded = try await store.load()
        var expected = [
            "Archive SSD": [0, 0], "restic": [0, 0],
            "NAS": [512, 2048], "nas.local": [512, 2048], "photos": [512, 2048],
        ]
        #expect(limits(loaded.configuration) == expected)
        #expect(loaded.decodeNotes.isEmpty)

        // Saved by this build, the pair is gone from the settings, so a
        // limit lifted afterwards stays lifted.
        var edited = loaded.configuration
        let cloud = try #require(edited.repositories.firstIndex { $0.kind == .b2 })
        edited.repositories[cloud].uploadLimitKiBps = 0
        try await store.save(edited)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let settings = try #require(saved?["settings"] as? [String: Any])
        #expect(settings["uploadLimitKiBps"] == nil)
        #expect(settings["downloadLimitKiBps"] == nil)
        expected["photos"] = [0, 2048]
        #expect(limits(try await store.load().configuration) == expected)
    }

    @Test("a plan an earlier build saved with several folders becomes one plan per folder; the first keeps its id and stamps")
    func multiFolderPlansSplit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // An earlier build's plan held a list of folders.
        let json = """
        {
          "repositories": [{"id": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "name": "Home Disk",
                            "kind": "local", "localPath": "/tmp/repo"}],
          "plans": [
            {"id": "340CA842-C653-4E2D-B61F-D7653D70A521", "name": "Projects",
             "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "sources": ["/Users/me/Code", "/Users/me/Notes", "/Volumes/Archive SSD/Photos", "/Users/me/Code"],
             "excludePatterns": ["*.log"], "tags": ["work"], "isEnabled": false,
             "schedule": {"frequency": "daily", "intervalHours": 1, "hour": 3, "minute": 30, "weekday": 2},
             "retention": {"isEnabled": true, "keepLast": 3, "keepHourly": 0, "keepDaily": 0,
                           "keepWeekly": 0, "keepMonthly": 0, "keepYearly": 0, "runPrune": false},
             "lastRunAt": "2026-10-17T03:30:00Z", "lastSuccessAt": "2026-10-17T03:31:00Z",
             "lastCompleteBackupAt": "2026-10-10T03:31:00Z", "staleAlertedFor": "2026-10-10T03:31:00Z"},
            {"id": "5B0E7C2D-0000-4000-8000-000000000002", "name": "Music",
             "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "sources": ["/Users/me/Music"]},
            {"id": "5B0E7C2D-0000-4000-8000-000000000003", "name": "Movies",
             "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "path": "/Users/me/Movies"},
            {"id": "5B0E7C2D-0000-4000-8000-000000000004", "name": "Unfinished",
             "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504"}
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

        // One plan per folder, each once, in the list's order, right where
        // the list stood.
        #expect(plans.map(\.path) == [
            "/Users/me/Code", "/Users/me/Notes", "/Volumes/Archive SSD/Photos",
            "/Users/me/Music", "/Users/me/Movies", "",
        ])
        let original = try #require(plans.first)
        let date = ISO8601DateFormatter()
        #expect(original.id == UUID(uuidString: "340CA842-C653-4E2D-B61F-D7653D70A521"))
        #expect(original.lastSuccessAt == date.date(from: "2026-10-17T03:31:00Z"))
        #expect(original.staleAlertedFor == date.date(from: "2026-10-10T03:31:00Z"))

        // The other folders: new plans with the settings copied. Their slot
        // is the original's, so they wait for it; no backup carries their id
        // yet, so nothing says they have one.
        let copies = Array(plans[1 ... 2])
        #expect(Set(copies.map(\.id)).count == 2)
        #expect(!copies.contains { $0.id == original.id })
        for copy in copies {
            #expect(copy.repositoryID == original.repositoryID)
            #expect(copy.excludePatterns == ["*.log"])
            #expect(copy.tags == ["work"])
            #expect(copy.isEnabled == false)
            #expect(copy.schedule == original.schedule)
            #expect(copy.retention == original.retention)
            #expect(copy.lastRunAt == original.lastRunAt)
            #expect(copy.lastSuccessAt == nil)
            #expect(copy.staleAlertedFor == nil)
        }
        #expect(plans[3].id == UUID(uuidString: "5B0E7C2D-0000-4000-8000-000000000002"))

        // Saved by this build: one path per plan, no list, and the split
        // holds — the copies keep the ids they were given.
        try await store.save(loaded.configuration)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let savedPlans = try #require(saved?["plans"] as? [[String: Any]])
        #expect(savedPlans.allSatisfy { $0["sources"] == nil })
        #expect(savedPlans.compactMap { $0["path"] as? String } == plans.map(\.path))
        #expect(try await store.load().configuration.plans.map(\.id) == plans.map(\.id))
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
        for plan in [BackupPlan(), decoded] {
            #expect(plan.skipsFinderFiles && plan.skipsSystemFiles, "the defaults must still apply")
            #expect(!plan.excludesToPass.contains { $0.contains(".git") })
        }
    }

    @Test("every default, pinned in order, and a new plan passes all of them and every developer rule, its own list empty")
    func defaultExcludesArePinned() {
        // The whole list, so a pattern typoed here fails this test instead
        // of only a real backup.
        #expect(BackupPlan.defaultExcludes == [
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
        #expect(BackupPlan.defaultExcludes(in: ExcludeCategory.finderFiles) == [".DS_Store", "~/.Trash"])
        // The two switches cover every default between them.
        #expect(BackupPlan.defaultExcludes(in: ExcludeCategory.finderFiles.union(ExcludeCategory.systemFiles))
            == BackupPlan.defaultExcludes)
        // Whatever the path: a rule naming nothing under it matches nothing.
        var plan = BackupPlan()
        plan.path = "~/dotfiles"
        #expect(plan.excludePatterns.isEmpty)
        #expect(plan.excludesToPass == BackupPlan.defaultExcludes + BackupPlan.developerExcludes)
    }

    @Test("every developer group is ticked for new plans, none for ones saved without the key, and the ticks round-trip")
    func developerFilesOnForNewPlans() throws {
        #expect(BackupPlan().developerGroups == ExcludeCategory.developerGroups)
        #expect(BackupPlan().excludeDeveloperFiles)
        #expect(try decode(BackupPlan.self, #"{"name":"Docs"}"#).developerGroups.isEmpty)
        // No dates in a fresh plan, so no strategy to match the encoder's.
        for groups in [ExcludeCategory.developerGroups, [.python, .rust], []] {
            var plan = BackupPlan()
            plan.developerGroups = groups
            let data = try JSONEncoder().encode(plan)
            #expect(try JSONDecoder().decode(BackupPlan.self, from: data).developerGroups == groups)
            // Under its own key, by name: older builds' key was one switch
            // that meant rules without rows.
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["skipDeveloperGroups"] as? [String] == groups.map(\.rawValue))
            #expect(object["excludeDeveloperFiles"] == nil)
        }
        // A group this build does not know is dropped, the rest kept in
        // the groups' order.
        let read = try decode(BackupPlan.self, #"{"skipDeveloperGroups":["rust","cobol","python"]}"#)
        #expect(read.developerGroups == [.python, .rust])
    }

    @Test("each switch passes its rules while on, beside the plan's own patterns, each once")
    func switchesMakeTheRun() {
        var plan = BackupPlan()
        plan.skipsFinderFiles = false
        plan.skipsSystemFiles = false
        plan.developerGroups = []
        plan.excludePatterns = ["*.iso", "**/.venv"]
        #expect(plan.excludesToPass == ["*.iso", "**/.venv"])

        plan.skipsFinderFiles = true
        #expect(plan.excludesToPass == [".DS_Store", "~/.Trash", "*.iso", "**/.venv"])
        plan.skipsSystemFiles = true
        #expect(plan.excludesToPass == BackupPlan.defaultExcludes + ["*.iso", "**/.venv"])

        // A group's checkbox: its rules, kept in the groups' order whatever
        // order they were ticked in; a rule also typed is passed once.
        plan.skipsSystemFiles = false
        plan.setSkips(.rust, true)
        plan.setSkips(.python, true)
        #expect(plan.developerGroups == [.python, .rust])
        #expect(plan.excludesToPass == [".DS_Store", "~/.Trash"]
            + BackupPlan.developerExcludes(groups: [.python, .rust]) + ["*.iso"])
        // The list itself is the user's, whatever the switches do.
        #expect(plan.excludePatterns == ["*.iso", "**/.venv"])
        #expect(plan.withoutSwitchRules(plan.excludePatterns) == ["*.iso"])

        // The developer switch: every group, or none.
        plan.setSkipsDeveloperFiles(true)
        #expect(plan.developerGroups == ExcludeCategory.developerGroups)
        plan.setSkipsDeveloperFiles(false)
        #expect(!plan.excludeDeveloperFiles)
        #expect(plan.excludesToPass == [".DS_Store", "~/.Trash", "*.iso", "**/.venv"])
    }

    @Test("the switches read back from a list that held their rules: any default on, a group by most of its rules")
    func switchesReadFromRecordedRules() {
        var plan = BackupPlan()
        // One Finder rule, no system one; Python whole, JavaScript but two
        // of its rules, which a user may have typed.
        plan.readSwitches(fromRecorded: ["~/.Trash", "*.iso"]
            + BackupPlan.developerExcludes(groups: [.python])
            + ["**/node_modules", "**/.next"])
        #expect(plan.skipsFinderFiles)
        #expect(!plan.skipsSystemFiles)
        #expect(plan.developerGroups == [.python])
        // A group missing a rule a later build added still reads as ticked.
        plan.readSwitches(fromRecorded: Array(BackupPlan.developerExcludes.dropFirst()))
        #expect(plan.developerGroups == ExcludeCategory.developerGroups)
        #expect(!plan.skipsFinderFiles && !plan.skipsSystemFiles)
    }

    @Test("a run leaves out the rules that name its source or a folder above it, and only those")
    func rulesCoveringTheSourceAreNotPassed() {
        let home = "/Users/probe"
        func covers(_ pattern: String, _ source: String) -> Bool {
            ResticService.pattern(ResticService.expandTilde(pattern, home: home), covers: source)
        }
        // The source itself, a folder above it, `*` within a component.
        #expect(covers("~/Library/Caches", "/Users/probe/Library/Caches"))
        #expect(covers("~/Library/Caches", "/Users/probe/Library/Caches/com.example"))
        #expect(covers("/Volumes/*/.Trashes", "/Volumes/T7/.Trashes"))
        #expect(covers("/System", "/System/Library"))
        // Below the source, beside it, or unanchored: passed.
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
        // The whole list, pinned group by group in the list's own order —
        // each group's folder patterns, then the home folder's: a pattern
        // typoed or dropped here fails this test instead of only a real
        // backup.
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
             ["~/.cocoapods/repos/trunk", "~/.cocoapods/repos/master", "~/Library/Developer/Xcode/*DeviceSupport"]),
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
            (.simulators, [],
             ["~/Library/Developer/CoreSimulator/Devices", "~/Library/Developer/CoreSimulator/Caches",
              "~/Library/Developer/Xcode/UserData/Previews", "~/.android/avd"]),
            (.machines, [],
             ["~/Library/Containers/com.docker.docker/Data/vms", "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
              "~/.lima/*/disk", "~/.lima/*/diffdisk", "~/.lima/*/basedisk",
              "~/.colima/_lima/*/disk", "~/.colima/_lima/*/diffdisk", "~/.colima/_lima/*/basedisk",
              "~/.local/share/containers/podman/machine", "~/.vagrant.d/boxes"]),
        ]
        // Every group has its checkbox, in the list's order.
        #expect(groups.map(\.0) == ExcludeCategory.developerGroups)
        for (group, folders, home) in groups {
            #expect(BackupPlan.developerExcludes(groups: [group]) == folders + home, "\(group)")
        }
        #expect(BackupPlan.developerExcludes == groups.flatMap { $0.folders + $0.home })
        // Rust's target and .NET's obj go by their markers.
        #expect(BackupPlan.developerMarkers(for: ExcludeCategory.developerGroups) == [".rustc_info.json", "project.assets.json"])
        #expect(BackupPlan.developerMarkers(for: [.python, .dotnet]) == ["project.assets.json"])
        #expect(BackupPlan.developerMarkers(for: []).isEmpty)
    }

    @Test("every rule the app offers is labelled, once, and sits in an app category")
    func everyOfferedRuleIsLabelled() {
        let rules = ExcludeRule.defaults + ExcludeRule.developer + ExcludeRule.developerMarkers
        #expect(Set(rules.map(\.pattern)).count == rules.count)
        for rule in rules {
            #expect(!rule.what.isEmpty && !rule.why.isEmpty, "\(rule.pattern)")
        }
        // The defaults sit outside the developer groups, every developer
        // rule and marker inside one.
        #expect(ExcludeRule.defaults.allSatisfy { !ExcludeCategory.developerGroups.contains($0.category) })
        #expect((ExcludeRule.developer + ExcludeRule.developerMarkers)
            .allSatisfy { ExcludeCategory.developerGroups.contains($0.category) })
        #expect(ExcludeRule.developerMarkers.map(\.line)
            == ["Folders holding .rustc_info.json", "Folders holding project.assets.json"])
    }

    @Test("a plan saved before the Skip switches reads them from its list, which keeps only the user's own patterns")
    func listsBecomeSwitchesAtLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let home = NSHomeDirectory()
        let defaults = String(decoding: try JSONEncoder().encode(BackupPlan.defaultExcludes), as: UTF8.self)
        let python = String(decoding: try JSONEncoder().encode(["*.iso"] + BackupPlan.developerExcludes(groups: [.python])), as: UTF8.self)
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
             "sources": ["~", "~/Documents"], "excludePatterns": \(defaults)},
            {"id": "5B0E7C2D-0000-4000-8000-000000000004", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "\(home)/Music"},
            {"id": "5B0E7C2D-0000-4000-8000-000000000005", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "\(home)/Library", "excludePatterns": []},
            {"id": "5B0E7C2D-0000-4000-8000-000000000006", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Code", "excludePatterns": \(python), "skipDeveloperGroups": ["python"]},
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
        #expect(plans.map(\.skipsFinderFiles) == [true, true, true, true, true, false, false, false])
        #expect(plans.map(\.skipsSystemFiles) == [true, true, true, true, true, false, false, true])
        #expect(plans.map(\.excludePatterns) == [
            // The defaults leave the list for their switches, whatever the
            // path; the user's own stay, in their order — **/node_modules,
            // an earlier default, among them, its group unticked.
            ["**/node_modules", "~/elsewhere/cache", "*.log"],
            [],
            // A split plan's folders each.
            [],
            [],
            // Saved without the key: the defaults, so both switches on.
            [],
            // A list emptied by hand: both off, nothing left out.
            [],
            // A ticked group's rules leave the list too.
            ["*.iso"],
            // Saved with the switches: the list as it stands, a typed rule
            // of a switch that is off included.
            [".DS_Store"],
        ])
        #expect(plans[6].developerGroups == [.python])

        // Saved with the switches' keys, and a second load changes nothing.
        try await store.save(loaded.configuration)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let saved = try #require((object["plans"] as? [[String: Any]])?.first)
        #expect(saved["skipsFinderFiles"] as? Bool == true)
        #expect(saved["skipsSystemFiles"] as? Bool == true)
        let reloaded = try await store.load().configuration.plans
        #expect(reloaded.map(\.excludePatterns) == plans.map(\.excludePatterns))
        #expect(reloaded.map(\.excludesToPass) == plans.map(\.excludesToPass))
    }

    @Test("a plan saved with older builds' developer switch on gets every group ticked, the groups' rules leaving its list")
    func legacyDeveloperSwitchBecomesGroupsAtLoad() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let json = """
        {
          "repositories": [{"id": "0753DDAB-181D-4E00-9340-8FDF7FD52504", "kind": "local", "localPath": "/tmp/repo"}],
          "plans": [
            {"id": "5B0E7C2D-0000-4000-8000-000000000001", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~", "excludePatterns": ["*.iso", "**/node_modules"], "excludeDeveloperFiles": true},
            {"id": "5B0E7C2D-0000-4000-8000-000000000002", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Documents", "excludePatterns": ["*.iso"], "excludeDeveloperFiles": false},
            {"id": "5B0E7C2D-0000-4000-8000-000000000003", "repositoryID": "0753DDAB-181D-4E00-9340-8FDF7FD52504",
             "path": "~/Documents", "excludePatterns": ["*.iso"]}
          ],
          "runs": [],
          "settings": {}
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: directory)
        let loaded = try await store.load().configuration
        #expect(loaded.plans.map(\.developerGroups) == [ExcludeCategory.developerGroups, [], []])
        #expect(loaded.plans.map(\.excludePatterns) == [["*.iso"], ["*.iso"], ["*.iso"]])
        #expect(loaded.plans[0].excludesToPass == BackupPlan.developerExcludes + ["*.iso"])

        // Saved under the new keys, read back as they stand.
        try await store.save(loaded)
        let reloaded = try await store.load().configuration
        #expect(reloaded.plans.map(\.developerGroups) == loaded.plans.map(\.developerGroups))
        #expect(reloaded.plans.map(\.excludePatterns) == loaded.plans.map(\.excludePatterns))
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
            #"{"path":"/Users/someone/Documents","retention":{"keepLast":"many"},"schedule":"not an object"}"#
        )
        #expect(plan.path == "/Users/someone/Documents")
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

        // Corrupt both the live file and .1: .2 still holds "Survivor".
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
            #expect(error.localizedDescription.contains("could not be read"))
        }
    }
}
