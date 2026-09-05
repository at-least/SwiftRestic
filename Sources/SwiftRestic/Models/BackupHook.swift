import Foundation

/// A shell command run around a plan's backup, or around a repository's
/// check and prune.
///
/// Hooks are given their context through environment variables rather than a
/// template language: it is the native idiom for shell scripts, needs no parser,
/// and quoting stays the shell's problem rather than ours.
///
/// The type name predates repository hooks; the stored shape is identical for
/// both, so it was kept rather than migrating every config on disk.
struct BackupHook: Identifiable, Codable, Sendable, Hashable {
    enum Event: String, Codable, Sendable, CaseIterable, Identifiable {
        // Plan events.
        case beforeBackup
        case afterSuccess
        case afterWarning
        case afterFailure
        /// Runs after every backup, whatever the outcome.
        case afterAny

        // Repository events, around `check` and `prune`.
        case beforeMaintenance
        case afterMaintenanceSuccess
        case afterMaintenanceFailure
        /// Runs after every check or prune, whatever the outcome.
        case afterAnyMaintenance

        var id: String { rawValue }

        /// The events a plan's hooks can be attached to.
        static let backupEvents: [Event] = [.beforeBackup, .afterSuccess, .afterWarning, .afterFailure, .afterAny]
        /// The events a repository's hooks can be attached to.
        static let maintenanceEvents: [Event] = [
            .beforeMaintenance, .afterMaintenanceSuccess, .afterMaintenanceFailure, .afterAnyMaintenance,
        ]

        var displayName: String {
            switch self {
            case .beforeBackup: "Before backup"
            case .afterSuccess: "After success"
            case .afterWarning: "After warnings"
            case .afterFailure: "After failure"
            case .afterAny: "After every backup"
            case .beforeMaintenance: "Before check or prune"
            case .afterMaintenanceSuccess: "After a successful check or prune"
            case .afterMaintenanceFailure: "After a failed check or prune"
            case .afterAnyMaintenance: "After every check or prune"
            }
        }

        /// Only a hook that runs first can call the run off.
        var canAbort: Bool { self == .beforeBackup || self == .beforeMaintenance }

        var isMaintenanceEvent: Bool { Self.maintenanceEvents.contains(self) }
    }

    enum FailureBehaviour: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Record the failure and carry on.
        case ignore
        /// Do not start the backup, check or prune at all. The raw value keeps
        /// its original spelling so existing configs still decode.
        case abortBackup

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .ignore: "Record it and carry on"
            case .abortBackup: "Cancel the run"
            }
        }
    }

    var id: UUID = UUID()
    var name: String = ""
    var event: Event = .afterSuccess
    var command: String = ""
    var failureBehaviour: FailureBehaviour = .ignore
    var timeoutSeconds: Int = 60
    var isEnabled: Bool = true

    var isRunnable: Bool {
        isEnabled && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A hook can only abort a run that has not started yet.
    var abortsRunOnFailure: Bool {
        failureBehaviour == .abortBackup && event.canAbort
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled hook" : name
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "")
        event = c.value(.event, default: .afterSuccess)
        command = c.value(.command, default: "")
        failureBehaviour = c.value(.failureBehaviour, default: .ignore)
        timeoutSeconds = c.value(.timeoutSeconds, default: 60)
        isEnabled = c.value(.isEnabled, default: true)
    }
}
