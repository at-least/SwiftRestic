import Foundation

struct AppSettings: Codable, Sendable, Hashable {
    var notifyOnSuccess: Bool = false
    /// The tray's Pause Backups, while it holds: every scheduled backup,
    /// check and prune waits. `nil` when nothing is paused.
    var schedulePause: SchedulePause?
    var notificationChannels: [NotificationChannel] = []
    var networkShares: [NetworkShare] = []
    /// The console's last commands, newest first. Persisted so a command
    /// that worked survives closing the sheet.

    init() {}

    init(from decoder: any Decoder) throws {
        // The property is each field's one default: a literal here would be a
        // second copy that a fresh install and a file missing the key could
        // let drift apart.
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyOnSuccess = c.value(.notifyOnSuccess, default: notifyOnSuccess)
        // A pause whose date does not read throws inside, so this reads as
        // not paused and says so — never as a pause without end.
        schedulePause = c.optional(.schedulePause)
        notificationChannels = c.value(.notificationChannels, default: [StoredChannel]()).compactMap(\.channel)
        networkShares = c.value(.networkShares, default: networkShares)
    }
}

struct AppConfiguration: Codable, Sendable {
    var repositories: [Repository] = []
    var plans: [BackupPlan] = []
    var runs: [RunRecord] = []
    var settings = AppSettings()

    init() {}

    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = c.value(.repositories, default: repositories)
        // The one line that cannot take its property as the fallback: the
        // file stores `StoredPlan`s, whose decode unfolds older builds'
        // `sources` into one plan per folder — read as the property's
        // `[BackupPlan]`, that split would be lost.
        plans = c.value(.plans, default: [StoredPlan]()).flatMap(\.plans)
        // Records written before stretches were stored get theirs here, so
        // every backup problem in memory has one.
        runs = RunRecord.fillingProblemStretches(c.value(.runs, default: runs))
        settings = c.value(.settings, default: settings)
    }

    func repository(id: UUID?) -> Repository? {
        repositories.withID(id)
    }
}

/// A plan as a configuration holds it. Older builds saved a
/// list of folders per plan (`sources`); a plan is one path now, so a list
/// becomes one plan per folder, in its order, each folder once. The first
/// keeps the plan's id — the tag its backups carry, so its history stays
/// its own — and its stamps. The others are new plans with its settings and
/// its slot (`lastRunAt`), so they wait for it instead of all starting at
/// launch; no backup carries their ids yet, so they have no last backup.
/// The plans are saved one path each with the next save. A plan saved with
/// older builds' single developer switch on (`excludeDeveloperFiles`) gets
/// both switches on, so its backups leave out what they did; its list sheds
/// the rules they now pass.
private struct StoredPlan: Decodable {
    var plan: BackupPlan
    var sources: [String] = []
    var legacySkipsDeveloperFiles = false

    private enum LegacyKeys: String, CodingKey {
        case sources
        case excludeDeveloperFiles
    }

    init(from decoder: any Decoder) throws {
        plan = try BackupPlan(from: decoder)
        let c = try decoder.container(keyedBy: LegacyKeys.self)
        sources = BackupPlan.withoutDuplicates(c.value(.sources, default: []))
        legacySkipsDeveloperFiles = c.value(.excludeDeveloperFiles, default: false)
    }

    var plans: [BackupPlan] {
        split.map { plan in
            var plan = plan
            if legacySkipsDeveloperFiles {
                plan.skipsDeveloperFiles = true
                plan.skipsMachines = true
                plan.excludePatterns = plan.withoutSwitchRules(plan.excludePatterns)
            }
            return plan
        }
    }

    private var split: [BackupPlan] {
        guard plan.path.isEmpty, let first = sources.first else { return [plan] }
        var original = plan
        original.path = first
        return [original] + sources.dropFirst().map { source in
            var copy = plan
            copy.id = UUID()
            copy.path = source
            copy.lastSuccessAt = nil
            copy.staleAlertedFor = nil
            return copy
        }
    }
}

/// What one load actually produced. The live file is not the only source:
/// a damaged or missing `config.json` recovers from the generations kept
/// beside it, and tolerance means the decode that succeeded may still have
/// substituted defaults the user should hear about.
struct LoadedConfiguration: Sendable {
    var configuration: AppConfiguration
    /// The generation the configuration really came from, when the live file
    /// could not be read — `nil` for the live file or a fresh install.
    var recoveredFrom: String?
    /// One line per present-but-unreadable field that fell back to its
    /// default, in document order.
    var decodeNotes: [String]
}

/// Writes are atomic and serialised through the actor, so a crash mid-save
/// cannot leave a half-written configuration behind. The two previous
/// generations are kept alongside (`config.json.1`, `config.json.2`): the
/// configuration is rewritten wholesale on every edit, so a bad write — or
/// an edit that silently decoded to defaults — would otherwise be one save
/// away from unrecoverable. `load` walks those generations when the live
/// file will not read.
actor ConfigStore {
    let directory: URL
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.directory = base
        self.fileURL = base.appendingPathComponent("config.json")
    }

    static func defaultDirectory() -> URL {
        // A seam for running the app against a throwaway configuration without
        // touching the real one.
        if let override = ProcessInfo.processInfo.environment["SWIFTRESTIC_CONFIG_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("com.newlix.SwiftRestic", isDirectory: true)
    }

    func load() throws -> LoadedConfiguration {
        // Newest first; the first generation that reads wins. The live file
        // missing while an older generation exists is the signature of an
        // interrupted save (or an external deletion) — recovering it beats
        // starting empty, and only a genuine first install finds no files
        // at all.
        let generations = [
            (name: "config.json", url: fileURL),
            (name: "config.json.1", url: directory.appendingPathComponent("config.json.1")),
            (name: "config.json.2", url: directory.appendingPathComponent("config.json.2")),
        ]
        var lastError: Error?
        for (index, generation) in generations.enumerated() {
            guard FileManager.default.fileExists(atPath: generation.url.path) else { continue }
            do {
                let (configuration, decodeNotes) = try Self.read(from: generation.url)
                return LoadedConfiguration(
                    configuration: configuration,
                    recoveredFrom: index == 0 ? nil : generation.name,
                    decodeNotes: decodeNotes
                )
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw ConfigError.unreadable(detail: Self.briefDecodingFailure(lastError))
        }
        return LoadedConfiguration(configuration: AppConfiguration(), recoveredFrom: nil, decodeNotes: [])
    }

    func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Encode before anything on disk moves: an encode failure (or a crash
        // anywhere below) must find the live file exactly where it was.
        let data = try Self.encoded(configuration)
        rotateBackups()
        try data.write(to: fileURL, options: [.atomic])
    }

    static func encoded(_ configuration: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Milliseconds, as restic's times are read (`ResticDateFormat`), so a
        // stored snapshot time equals the same time read from restic again.
        // Not `.iso8601`, which drops the fraction. A file written before
        // holds whole seconds, which the decoder still reads; an older build
        // cannot read this one.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ResticDateFormat.string(from: date))
        }
        return try encoder.encode(configuration)
    }

    /// Best effort: insurance must never keep the live write from happening.
    ///
    /// The current file is *copied* into `.1`, not moved: every step here
    /// runs before the atomic overwrite of the live file, so a crash between
    /// the rotation and the write leaves a readable live file and its copy,
    /// never the empty configuration a move could strand.
    private func rotateBackups() {
        let firstBackup = directory.appendingPathComponent("config.json.1")
        let secondBackup = directory.appendingPathComponent("config.json.2")
        if FileManager.default.fileExists(atPath: secondBackup.path) {
            try? FileManager.default.removeItem(at: secondBackup)
        }
        if FileManager.default.fileExists(atPath: firstBackup.path) {
            try? FileManager.default.moveItem(at: firstBackup, to: secondBackup)
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.copyItem(at: fileURL, to: firstBackup)
        }
    }

    enum ConfigError: LocalizedError {
        case unreadable(detail: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(detail):
                return "config.json couldn’t be read, and none of its backup copies could either (\(detail))."
            }
        }
    }

    private static func read(from url: URL) throws -> (AppConfiguration, [String]) {
        let (configuration, notes) = try decoded(Data(contentsOf: url))
        return (configuration, notes.notes)
    }

    static func decoded(_ data: Data) throws -> (AppConfiguration, DecodeNoteBox) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ResticDateFormat.decodingStrategy
        let notes = DecodeNoteBox()
        let configuration = try DecodeNotes.$current.withValue(notes) {
            try decoder.decode(AppConfiguration.self, from: data)
        }
        return (configuration, notes)
    }

    /// One short line about why a generation could not be decoded — enough to
    /// name the field, never the whole dumped context.
    static func briefDecodingFailure(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return String(describing: type(of: error))
        }
        let context: DecodingError.Context
        switch decoding {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .keyNotFound(_, c):
            context = c
        case let .dataCorrupted(c):
            context = c
        @unknown default:
            return "the file did not decode"
        }
        let field = context.codingPath.map(keyName).joined(separator: ".")
        switch decoding {
        case .typeMismatch: return "field “\(field)” has an unexpected type"
        case .valueNotFound: return "field “\(field)” was missing a value"
        case .keyNotFound: return "field “\(field)” is absent"
        case .dataCorrupted: return field.isEmpty ? "the file is corrupt" : "field “\(field)” is corrupt"
        @unknown default: return "the file did not decode"
        }
    }

    private static func keyName(_ key: any CodingKey) -> String {
        if let index = key.intValue { return "[\(index)]" }
        return key.stringValue
    }
}
