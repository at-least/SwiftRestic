import Foundation

/// A file Import Settings read, waiting for its confirmation: the document
/// Export Settings writes (`AppConfiguration.exported`). Equal by `id`,
/// one per read.
struct SettingsFile: Hashable, Identifiable, Sendable {
    let id = UUID()
    /// The file's name, as the confirmation and the banner say it.
    let name: String
    let configuration: AppConfiguration

    static func == (lhs: SettingsFile, rhs: SettingsFile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    enum ReadError: LocalizedError, Equatable {
        case notSettings
        case unreadable(detail: String)
        case unreadableSettings([String])

        var errorDescription: String? {
            switch self {
            case .notSettings:
                "It isn’t a SwiftRestic settings file."
            case let .unreadable(detail):
                "It can’t be read (\(detail))."
            case let .unreadableSettings(fields):
                "Some of its settings can’t be read: "
                    + fields.prefix(3).map { "“\($0)”" }.joined(separator: ", ") + (fields.count > 3 ? ", …" : ".")
            }
        }
    }

    /// Through `config.json`'s own decoder, so a file an older build wrote
    /// reads as its launch would. A setting tolerant decoding would replace
    /// with its default refuses the whole file: an import that quietly set
    /// something the file did not say would replace the user's with neither.
    static func read(from url: URL) throws -> SettingsFile {
        let data = try Data(contentsOf: url)
        // Tolerant decoding reads any JSON object as an empty configuration,
        // which would replace everything with nothing: every configuration
        // writes these two keys, arrays even when empty.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["repositories"] != nil, object["plans"] != nil
        else { throw ReadError.notSettings }
        let configuration: AppConfiguration
        let notes: DecodeNoteBox
        do {
            (configuration, notes) = try ConfigStore.decoded(data)
        } catch {
            throw ReadError.unreadable(detail: ConfigStore.briefDecodingFailure(error))
        }
        guard notes.fields.isEmpty else { throw ReadError.unreadableSettings(notes.fields) }
        return SettingsFile(name: url.lastPathComponent, configuration: configuration)
    }
}

extension AppConfiguration {
    /// What Export Settings writes: everything but what stays with the Mac.
    var exported: AppConfiguration {
        var exported = self
        exported.keepMachineState(of: AppConfiguration())
        return exported
    }

    /// The configuration once `file` is imported: the file's repositories,
    /// plans and settings, and this Mac's own state. A repository or plan
    /// already here (same id) keeps this Mac's stamps — when it last ran,
    /// was checked, was cleaned up — by the editors' save rule
    /// (`merging(draft:)`): they say what this Mac did, the file's what the
    /// Mac that wrote it did.
    func importing(_ file: AppConfiguration) -> AppConfiguration {
        var imported = file
        imported.repositories = file.repositories.map { incoming in
            repository(id: incoming.id)?.merging(draft: incoming) ?? incoming
        }
        imported.plans = file.plans.map { incoming in
            plans.first { $0.id == incoming.id }?.merging(draft: incoming) ?? incoming
        }
        imported.keepMachineState(of: self)
        return imported
    }

    /// What stays with the Mac when settings move: its run history, the
    /// console's commands, and the Pause Backups hold — a hold carried to
    /// another Mac would stop its backups with nobody there having paused
    /// them.
    private mutating func keepMachineState(of mac: AppConfiguration) {
        runs = mac.runs
        settings.consoleHistory = mac.settings.consoleHistory
        settings.schedulePause = mac.settings.schedulePause
    }
}
