import Foundation

/// A share SwiftRestic reconnects before a backup that needs it: the volume
/// under /Volumes a local repository's folder or a plan's source lives on.
/// The password is in the Keychain (`KeychainStore.Slot.sharePassword`,
/// under `id`). A record exists only once a password was entered for it.
struct NetworkShare: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    /// The folder it mounts as under /Volumes: "NAS" for /Volumes/NAS.
    var volumeName: String
    /// `URLResourceKey.volumeURLForRemountingKey`, read while mounted:
    /// "smb://me@nas.local/NAS", never with a password.
    var url: String
}

struct ShareReconnect: Equatable, Sendable {
    /// A failure's text is a clause that follows "Reconnecting “NAS” failed: ".
    enum Outcome: Equatable, Sendable {
        case reconnected
        /// May pass by itself (server out of reach, an unexplained macOS
        /// error): a run waits for the share as for a drive that is away.
        case unreachable(String)
        /// Only the user clears it: a refused password or access, no share
        /// by that name, a leftover folder at the mount point, no password
        /// in the Keychain.
        case refused(String)
    }

    var volumeName: String
    var url: String
    var outcome: Outcome

    var failureReason: String? {
        switch outcome {
        case .reconnected: nil
        case let .unreachable(reason), let .refused(reason): reason
        }
    }

    var isRefusal: Bool {
        if case .refused = outcome { true } else { false }
    }

    var logLine: String {
        guard let failureReason else { return "Reconnected the network share \(url) at /Volumes/\(volumeName)." }
        return "Couldn’t reconnect the network share \(url): \(failureReason)."
    }
}

extension [ShareReconnect] {
    var reasonsByVolume: [String: String] {
        var reasons: [String: String] = [:]
        for answer in self { reasons[answer.volumeName] = answer.failureReason }
        return reasons
    }
}
