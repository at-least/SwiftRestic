import Foundation

/// App-wide preferences that are not tied to a single repository or plan.
struct AppSettings: Codable, Sendable, Hashable {
    /// Explicit path to the restic binary; empty means "search the usual places".
    var resticPathOverride: String = ""
    var showMenuBarExtra: Bool = true
    var notifyOnSuccess: Bool = false
    var notifyOnFailure: Bool = true
    /// How many run records to keep before the oldest are dropped.
    var maxRunHistory: Int = 300
    /// 0 means unlimited. Passed to restic as `--limit-upload` / `--limit-download`.
    var uploadLimitKiBps: Int = 0
    var downloadLimitKiBps: Int = 0
    /// Skip scheduled runs while on battery power.
    var pauseOnBattery: Bool = false
    /// Webhook, chat and dead-man's-switch destinations.
    var notificationChannels: [NotificationChannel] = []
    /// The console's last commands, newest first. Persisted so a command that
    /// worked survives closing the sheet — the console is a power user's home,
    /// and retyping from memory is the tax it exists to remove.
    var consoleHistory: [String] = []

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resticPathOverride = c.value(.resticPathOverride, default: "")
        showMenuBarExtra = c.value(.showMenuBarExtra, default: true)
        notifyOnSuccess = c.value(.notifyOnSuccess, default: false)
        notifyOnFailure = c.value(.notifyOnFailure, default: true)
        maxRunHistory = c.value(.maxRunHistory, default: 300)
        uploadLimitKiBps = c.value(.uploadLimitKiBps, default: 0)
        downloadLimitKiBps = c.value(.downloadLimitKiBps, default: 0)
        pauseOnBattery = c.value(.pauseOnBattery, default: false)
        notificationChannels = c.value(.notificationChannels, default: [])
        consoleHistory = c.value(.consoleHistory, default: [])
    }
}

/// Everything the app persists, in one document.
struct AppConfiguration: Codable, Sendable {
    var repositories: [Repository] = []
    var plans: [BackupPlan] = []
    var runs: [RunRecord] = []
    var settings = AppSettings()

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repositories = c.value(.repositories, default: [])
        plans = c.value(.plans, default: [])
        runs = c.value(.runs, default: [])
        settings = c.value(.settings, default: AppSettings())
    }

    func repository(id: UUID?) -> Repository? {
        guard let id else { return nil }
        return repositories.first { $0.id == id }
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

/// Reads and writes `config.json` under Application Support.
///
/// Writes are atomic and serialised through the actor, so a crash mid-save
/// cannot leave a half-written configuration behind. The two previous
/// generations are kept alongside (`config.json.1`, `config.json.2`): the
/// configuration is rewritten wholesale on every edit, so a bad write — or an
/// edit that silently decoded to defaults — would otherwise be one save away
/// from unrecoverable. `load` walks those generations when the live file
/// will not read, so the insurance is something the app does, not something
/// it merely keeps.
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        rotateBackups()
        try data.write(to: fileURL, options: [.atomic])
    }

    var configurationFileURL: URL { fileURL }

    /// Best effort: insurance must never keep the live write from happening.
    ///
    /// The current file is *copied* into `.1`, not moved: every step here runs
    /// before the atomic overwrite of the live file, so a crash between the
    /// rotation and the write leaves both the old live file and its copy
    /// behind instead of nothing at all. (Moving first had a window where a
    /// crash — or a failed encode — left no live file, and the next launch
    /// read an empty configuration.)
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

    // MARK: - Reading

    /// Why the configuration could not be read at all — every generation
    /// tried and failed.
    enum ConfigError: LocalizedError {
        case unreadable(detail: String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(detail):
                return "config.json could not be read, and none of its backup copies could either (\(detail))."
            }
        }
    }

    /// Decodes one generation, collecting what tolerant decoding substituted
    /// along the way.
    private static func read(from url: URL) throws -> (AppConfiguration, [String]) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let notes = DecodeNoteBox()
        let configuration = try DecodeNotes.$current.withValue(notes) {
            try decoder.decode(AppConfiguration.self, from: data)
        }
        return (configuration, notes.notes)
    }

    /// One short line about why a generation could not be decoded — enough to
    /// name the field, never the whole dumped context.
    private static func briefDecodingFailure(_ error: Error) -> String {
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
