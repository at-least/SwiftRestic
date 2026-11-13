import Foundation
import Observation

/// The disk's turn for a plan's Backups tab: what was read of this Mac's
/// disk beside the backups is read again when the disk may have changed
/// (`diskMayHaveChanged`: the tab shown, the app made active, a volume
/// mounted or unmounted).
@MainActor
@Observable
final class DiskWatch {
    static let recheckInterval: Duration = .seconds(15)

    /// Moved by `diskMayHaveChanged`: what was read of the disk in an older
    /// turn is read again.
    private(set) var diskGeneration: UInt64 = 0

    /// The disk may no longer be as it was read: the Backups tab shown
    /// again, the app made active — another app may have changed a folder
    /// meanwhile — or a volume mounted or unmounted.
    func diskMayHaveChanged() {
        diskGeneration += 1
    }
}
