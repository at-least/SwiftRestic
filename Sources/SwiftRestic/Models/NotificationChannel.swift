import Foundation

struct NotificationChannel: Identifiable, Codable, Sendable, Hashable {
    /// The service an address belongs to, read from the address alone: a
    /// person pastes a link and picks nothing.
    enum Kind: Equatable, Sendable {
        case webhook
        case slack
        case discord
        /// A dead-man's switch: silence is the alarm.
        case healthchecks

        /// Healthchecks needs a ping when a run *starts* — that is what arms the
        /// timer it measures the run against. For the others a "started" message
        /// is just noise.
        var usesStartPing: Bool { self == .healthchecks }

        /// A self-hosted Healthchecks pings at `PING_ENDPOINT`, by default the
        /// site root's /ping/, followed by a UUID or `<ping-key>/<slug>`
        /// (healthchecks.io/docs/self_hosted_configuration). Read as a plain
        /// webhook, its JSON POST would ping "alive" on a failure.
        init(address: String) {
            guard let parsed = URL(string: address.trimmingCharacters(in: .whitespaces)),
                  let host = parsed.host()?.lowercased()
            else {
                self = .webhook
                return
            }
            let path = parsed.pathComponents.filter { $0 != "/" }
            let isSelfHostedPing = path.first == "ping"
                && (path.count == 3 || (path.count == 2 && UUID(uuidString: path[1]) != nil))
            switch host {
            case "hooks.slack.com": self = .slack
            case "discord.com", "discordapp.com": self = .discord
            case "hc-ping.com": self = .healthchecks
            default: self = isSelfHostedPing ? .healthchecks : .webhook
            }
        }
    }

    var id: UUID = UUID()
    var url: String = ""

    var kind: Kind { Kind(address: url) }

    /// The address's host: a person pastes a link, and names nothing.
    var displayName: String {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.host() ?? "Webhook"
    }

    var hasUsableURL: Bool {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    /// `notifyOnSuccess` is the app's one success switch, shared with the
    /// macOS notifications. Failures and warnings always go.
    func wants(_ stage: NotificationEvent.Stage, notifyOnSuccess: Bool) -> Bool {
        switch stage {
        case .started: kind.usesStartPing
        // A monitor needs every success: a missing ping is its alarm.
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
        url = c.value(.url, default: "")
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
            let added = kind == .backup ? " — \(Format.bytes(dataAdded)) of new data" : ""
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
