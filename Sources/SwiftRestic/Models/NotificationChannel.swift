import Foundation

struct NotificationChannel: Identifiable, Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
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

        /// The service a pasted address names; nil for anything else, a
        /// self-hosted one included, which the picker still reaches: a
        /// self-hosted Healthchecks posted as a plain webhook would ping
        /// "alive" on a failure.
        init?(inferringFrom url: String) {
            guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)), let host = parsed.host()?.lowercased() else { return nil }
            switch host {
            case "hooks.slack.com": self = .slack
            case "discord.com", "discordapp.com": self = .discord
            case "hc-ping.com": self = .healthchecks
            default: return nil
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind = .webhook
    var url: String = ""
    /// Failures and warnings always go; a monitor hears everything.
    var notifyOnSuccess: Bool = false

    /// The address's host: a person pastes a link, and names nothing.
    var displayName: String {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.host() ?? kind.displayName
    }

    var hasUsableURL: Bool {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    func wants(_ stage: NotificationEvent.Stage) -> Bool {
        switch stage {
        case .started: kind.usesStartPing
        case .succeeded: kind.usesStartPing || notifyOnSuccess
        case .warned, .failed: true
        // A cancelled backup did not happen: only a dead-man's switch needs
        // to hear of it, and whoever cancelled it already knows.
        case .cancelled, .skipped: kind.usesStartPing
        }
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .webhook)
        url = c.value(.url, default: "")
        notifyOnSuccess = c.value(.notifyOnSuccess, default: true)
    }
}

/// A channel as a configuration holds it. Nil for one switched off in an older
/// build: it must not start sending.
struct StoredChannel: Decodable {
    var channel: NotificationChannel?

    private enum LegacyKeys: String, CodingKey { case isEnabled }

    init(from decoder: any Decoder) throws {
        if try decoder.container(keyedBy: LegacyKeys.self).value(.isEnabled, default: true) {
            channel = try NotificationChannel(from: decoder)
        }
    }
}

struct NotificationEvent: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case started, succeeded, warned, failed
        /// The user stopped the run. Chat channels stay quiet, but a monitor
        /// waiting for a check-in has still missed one.
        case cancelled
        /// A drive or server the run needs was away. Like a cancel,
        /// only a monitor waiting for a check-in needs to hear of it.
        case skipped
    }

    var stage: Stage
    var planName: String
    var repositoryName: String
    var kind: RunRecord.Kind
    var snapshotID: String?
    var errorMessage: String?
    /// Excerpts only — the first few warnings, for the message body. The full
    /// count lives in `warningCount`; a summary that counted the sample would
    /// tell a chat room "5 warnings" about a run that hit 500.
    var warnings: [String] = []
    /// Every warning the run reported. `nil` when nobody counted (a
    /// hand-built event, or a run with nothing to count).
    var warningCount: Int?
    /// What to do about the warnings, when the app can tell — "macOS
    /// blocked 1 item: SwiftRestic needs Full Disk Access." Built from
    /// restic's item errors only, like `warnings`.
    var hint: String?
    var filesNew: Int = 0
    var bytesProcessed: Int64 = 0
    var dataAdded: Int64 = 0
    var duration: TimeInterval = 0

    var summary: String {
        // The subject follows the app's one run-naming rule: the plan with
        // its repository ("Documents (NAS)"). A check or prune reports the
        // repository in `planName` too, and the rule's same-name guard says
        // it once. The webhook's separate plan/repository keys keep their
        // own values; this is only the sentence.
        let subject = planName.isEmpty
            ? repositoryName
            : RunRecordPresentation.planWithRepository(planName, repositoryName: repositoryName)
        let operation = kind.channelSummaryName
        switch stage {
        case .started:
            return "\(operation) started: \(subject)"
        case .succeeded:
            // Only a backup adds data; a check's or a cleanup's 0 is not news.
            let added = kind == .backup ? " — \(Format.bytes(dataAdded)) added" : ""
            return "\(operation) succeeded: \(subject)\(added) in \(Format.duration(duration))"
        case .warned:
            // A retention line is appended to `itemErrors` after
            // `itemErrorCount` is set, so it can sit in the sample without
            // being in any count — not a warning, and never counted one.
            let counted = warningCount ?? warnings.filter { !$0.hasPrefix(RunRecord.retentionSkippedPrefix) }.count
            return "\(operation) \(counted > 0 ? "completed with \(Format.plural(counted, "warning"))" : "completed with warnings"): \(subject)"
                + (warnings.first.map { " — \($0)" } ?? "")
                + (hint.map { "\n" + $0 } ?? "")
        case .failed:
            return "\(operation) failed: \(subject) — \(errorMessage ?? "no details")"
        case .cancelled:
            return "\(operation) cancelled: \(subject)"
        case .skipped:
            return "\(operation) skipped: \(subject)" + (errorMessage.map { " — \($0)" } ?? "")
        }
    }
}
