import Foundation

struct NotificationChannel: Identifiable, Codable, Sendable, Hashable {
    /// Read from the address alone: the user pastes a link and picks nothing.
    enum Kind: Equatable, Sendable {
        case webhook
        case slack
        case discord
        /// A dead-man's switch: silence is the alarm.
        case healthchecks

        /// The start ping arms Healthchecks' timer; for the others a
        /// "started" message is noise.
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

    var displayName: String {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.host() ?? "Address"
    }

    var hasUsableURL: Bool {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    /// `notifyOnSuccess` is shared with the macOS notifications.
    func wants(_ stage: NotificationEvent.Stage, notifyOnSuccess: Bool) -> Bool {
        switch stage {
        case .started: kind.usesStartPing
        // A monitor needs every success: a missing ping is its alarm.
        case .succeeded: kind.usesStartPing || notifyOnSuccess
        case .warned, .failed: true
        // Whoever cancelled it already knows.
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

struct NotificationEvent: Sendable, Equatable {
    enum Stage: String, Sendable, Equatable {
        case started, succeeded, warned, failed
        case cancelled
        /// A drive or server the run needs was away.
        case skipped
    }

    var stage: Stage
    var planName: String
    var repositoryName: String
    var kind: RunRecord.Kind
    var snapshotID: String?
    var errorMessage: String?
    /// The first few only; counting them would tell a chat room "5 warnings"
    /// about a run that hit 500.
    var warnings: [String] = []
    /// `nil` when nobody counted (a hand-built event, or nothing to count).
    var warningCount: Int?
    /// "macOS blocked 1 item: SwiftRestic needs Full Disk Access." From
    /// restic's item errors only.
    var hint: String?
    var filesNew: Int = 0
    var bytesProcessed: Int64 = 0
    var dataAdded: Int64 = 0
    var duration: TimeInterval = 0

    var summary: String {
        // A check or prune carries the repository in `planName` too;
        // `planWithRepository` says a repeated name once.
        let subject = planName.isEmpty
            ? repositoryName
            : RunRecordPresentation.planWithRepository(planName, repositoryName: repositoryName)
        let operation = kind.displayName
        switch stage {
        case .started:
            return "\(operation) started: \(subject)"
        case .succeeded:
            let added = kind == .backup ? " — \(Format.bytes(dataAdded)) of new data" : ""
            return "\(operation) succeeded: \(subject)\(added) in \(Format.duration(duration))"
        case .warned:
            // A retention line is appended to `itemErrors` after
            // `itemErrorCount` is set: in the sample, never in a count.
            let counted = warningCount ?? warnings.filter { !$0.hasPrefix(RunRecord.retentionSkippedOnScreenPrefix) }.count
            return "\(operation) \(counted > 0 ? "completed with \(Format.plural(counted, "warning"))" : "completed with warnings"): \(subject)"
                + (warnings.first.map { " — \($0)" } ?? "")
                + (hint.map { "\n" + $0 } ?? "")
        case .failed:
            return "\(operation) failed: \(subject) — \(errorMessage ?? "no details")"
        case .cancelled:
            return "\(operation) stopped: \(subject)"
        case .skipped:
            return "\(operation) skipped: \(subject)" + (errorMessage.map { " — \($0)" } ?? "")
        }
    }
}
