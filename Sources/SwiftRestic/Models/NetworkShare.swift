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
    enum Outcome: Equatable, Sendable {
        case reconnected
        /// Why not, in a clause that follows "Reconnecting “NAS” failed: ".
        case failed(String)
    }

    var volumeName: String
    var url: String
    var outcome: Outcome

    /// The run log's line.
    var logLine: String {
        switch outcome {
        case .reconnected: "Reconnected the network share \(url) at /Volumes/\(volumeName)."
        case let .failed(reason): "Could not reconnect the network share \(url): \(reason)."
        }
    }
}
