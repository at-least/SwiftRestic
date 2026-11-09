import Foundation

/// A shell command run around a plan's backup.
///
/// Hooks are given their context through environment variables rather than a
/// template language: it is the native idiom for shell scripts, needs no parser,
/// and quoting stays the shell's problem rather than ours.
struct BackupHook: Identifiable, Encodable, Sendable, Hashable {
    enum Event: String, Encodable, Sendable, CaseIterable, Identifiable {
        case beforeBackup
        /// Every end but a stop: the script reads `SWIFTRESTIC_OUTCOME`.
        case afterBackup

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .beforeBackup: "Before backup"
            case .afterBackup: "After backup"
            }
        }

        /// As a configuration holds it. Older builds split the end of a backup
        /// by outcome, and ran other events around a repository's upkeep,
        /// which no longer run: nil, or a check's script would run at a backup.
        init?(stored: String) {
            switch stored {
            case "beforeBackup": self = .beforeBackup
            case "afterBackup", "afterSuccess", "afterWarning", "afterFailure", "afterAny": self = .afterBackup
            default: return nil
            }
        }
    }

    var id: UUID = UUID()
    var event: Event = .afterBackup
    var command: String = ""

    var isRunnable: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A script before the backup that fails always stops it (user
    /// decision); after the backup there is nothing left to stop.
    var abortsRunOnFailure: Bool {
        event == .beforeBackup
    }

    /// The program it runs, for the run's record and log. The program alone,
    /// never the line: a run's log is what a user copies whole to ask for help,
    /// and a command's arguments and leading `VAR=` hold its tokens.
    var displayName: String {
        let program = command.split(whereSeparator: \.isWhitespace).first { !$0.contains("=") }
        return program.map { ($0 as NSString).lastPathComponent } ?? "Untitled Hook"
    }

    init() {}
}

/// A hook as a plan's configuration holds it. Nil for what must not start
/// running: a hook switched off in an older build, and an event no backup has.
struct StoredHook: Decodable {
    var hook: BackupHook?

    private enum CodingKeys: String, CodingKey {
        case id, event, command, isEnabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.value(.isEnabled, default: true) else { return }
        let stored: String = c.value(.event, default: "")
        guard let event = BackupHook.Event(stored: stored) else {
            DecodeNotes.current?.add(field: "hooks.event", "“\(stored)” isn’t a time a backup runs a script — the script was left out")
            return
        }
        var hook = BackupHook()
        hook.id = c.value(.id, default: UUID())
        hook.event = event
        hook.command = c.value(.command, default: "")
        self.hook = hook
    }
}
