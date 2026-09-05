import Foundation

/// Somewhere outside the Mac to tell about a run.
struct NotificationChannel: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        /// A plain JSON POST with the whole event.
        case webhook
        case slack
        case discord
        /// A dead-man's switch: silence is the alarm.
        case healthchecks

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .webhook: "Webhook (JSON)"
            case .slack: "Slack"
            case .discord: "Discord"
            case .healthchecks: "Healthchecks.io"
            }
        }

        var urlPrompt: String {
            switch self {
            case .webhook: "https://example.com/hooks/backup"
            case .slack: "https://hooks.slack.com/services/…"
            case .discord: "https://discord.com/api/webhooks/…"
            case .healthchecks: "https://hc-ping.com/<uuid>"
            }
        }

        /// Healthchecks needs a ping when a run *starts* — that is what arms the
        /// timer it measures the run against. For the others a "started" message
        /// is just noise.
        var usesStartPing: Bool { self == .healthchecks }
    }

    var id: UUID = UUID()
    var name: String = ""
    var kind: Kind = .webhook
    var url: String = ""
    var isEnabled: Bool = true
    var notifyOnSuccess: Bool = true
    var notifyOnWarning: Bool = true
    var notifyOnFailure: Bool = true

    var displayName: String {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? kind.displayName : name
    }

    var isUsable: Bool {
        isEnabled && URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    func wants(_ stage: NotificationEvent.Stage) -> Bool {
        switch stage {
        case .started: kind.usesStartPing
        case .succeeded: notifyOnSuccess
        case .warned: notifyOnWarning
        case .failed: notifyOnFailure
        // A cancelled backup is a backup that did not happen. Only a dead-man's
        // switch needs to hear about it; announcing it in a chat channel would
        // be noise, since the person who cancelled it already knows.
        case .cancelled: kind.usesStartPing && notifyOnFailure
        }
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "")
        kind = c.value(.kind, default: .webhook)
        url = c.value(.url, default: "")
        isEnabled = c.value(.isEnabled, default: true)
        notifyOnSuccess = c.value(.notifyOnSuccess, default: true)
        notifyOnWarning = c.value(.notifyOnWarning, default: true)
        notifyOnFailure = c.value(.notifyOnFailure, default: true)
    }
}

/// What happened, in the terms a notification needs.
struct NotificationEvent: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case started, succeeded, warned, failed
        /// The user stopped the run. Chat channels stay quiet, but a monitor
        /// waiting for a check-in has still missed one.
        case cancelled
    }

    var stage: Stage
    var planName: String
    var repositoryName: String
    var operation: String = "Backup"
    var snapshotID: String?
    var errorMessage: String?
    var warnings: [String] = []
    var filesNew: Int = 0
    var bytesProcessed: Int64 = 0
    var dataAdded: Int64 = 0
    var duration: TimeInterval = 0

    /// One line suitable for a chat message or a Healthchecks log entry.
    var summary: String {
        let subject = planName.isEmpty ? repositoryName : planName
        switch stage {
        case .started:
            return "\(operation) started: \(subject)"
        case .succeeded:
            return "\(operation) succeeded: \(subject) — \(Format.bytes(dataAdded)) added"
                + " in \(Format.duration(duration))"
        case .warned:
            let count = warnings.count
            return "\(operation) finished with \(count) warning(s): \(subject)"
                + (warnings.first.map { " — \($0)" } ?? "")
        case .failed:
            return "\(operation) FAILED: \(subject) — \(errorMessage ?? "no details")"
        case .cancelled:
            return "\(operation) cancelled before finishing: \(subject)"
        }
    }
}
