import Foundation

/// A network share SwiftRestic reconnects before a backup that needs it —
/// the volume a local repository's folder or a plan's source lives on, as
/// macOS mounted it under /Volumes. The URL is the volume's own remount
/// URL (`URLResourceKey.volumeURLForRemountingKey`), read while it was
/// mounted, so nobody types it; the password is in the Keychain
/// (`KeychainStore.Slot.sharePassword`, under `id`). A record exists only
/// once a password was entered for it.
struct NetworkShare: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    /// The folder it mounts as under /Volumes: "NAS" for /Volumes/NAS.
    var volumeName: String
    /// What to mount, as macOS reported it: "smb://me@nas.local/NAS" —
    /// never with a password.
    var url: String
}

/// What reconnecting one share before a backup came to.
struct ShareReconnect: Equatable, Sendable {
    /// Why not, in a clause that follows "Reconnecting “NAS” failed: ".
    enum Outcome: Equatable, Sendable {
        case reconnected
        /// A cause that may pass by itself — the server out of reach, or an
        /// error macOS did not explain: a run waits for the share as for a
        /// drive that is away.
        case unreachable(String)
        /// A cause only the user clears — the share refused the saved
        /// password, has no share by that name, refused access, mounted
        /// beside a leftover folder, or no password came from the Keychain.
        case refused(String)
    }

    var volumeName: String
    var url: String
    var outcome: Outcome

    /// Why it stayed away; nil when it was reconnected.
    var failureReason: String? {
        switch outcome {
        case .reconnected: nil
        case let .unreachable(reason), let .refused(reason): reason
        }
    }

    var isRefusal: Bool {
        if case .refused = outcome { true } else { false }
    }

    /// The run log's line.
    var logLine: String {
        guard let failureReason else { return "Reconnected the network share \(url) at /Volumes/\(volumeName)." }
        return "Could not reconnect the network share \(url): \(failureReason)."
    }
}

extension [ShareReconnect] {
    /// Each share's reason by volume name — what a run's words read
    /// (`RunRecord.skippedReason(sources:reconnectFailures:)`).
    var reasonsByVolume: [String: String] {
        var reasons: [String: String] = [:]
        for answer in self { reasons[answer.volumeName] = answer.failureReason }
        return reasons
    }
}
