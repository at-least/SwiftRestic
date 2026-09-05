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

/// Reads and writes `config.json` under Application Support.
///
/// Writes are atomic and serialised through the actor, so a crash mid-save
/// cannot leave a half-written configuration behind. The two previous
/// generations are kept alongside (`config.json.1`, `config.json.2`): the
/// configuration is rewritten wholesale on every edit, so a bad write — or an
/// edit that silently decoded to defaults — would otherwise be one save away
/// from unrecoverable.
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

    func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return AppConfiguration()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateBackups()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: fileURL, options: [.atomic])
    }

    var configurationFileURL: URL { fileURL }

    /// Best effort: insurance must never keep the live write from happening.
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
            try? FileManager.default.moveItem(at: fileURL, to: firstBackup)
        }
    }
}
