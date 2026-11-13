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

    private(set) var diskGeneration: UInt64 = 0

    /// The app made active counts: another app may have changed a folder
    /// meanwhile.
    func diskMayHaveChanged() {
        diskGeneration += 1
    }
}
