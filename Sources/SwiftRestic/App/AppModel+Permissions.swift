import AppKit
import Foundation

extension AppModel {
    // MARK: - Full Disk Access

    /// Probes the grant again, off the main actor (the first TCC-checked
    /// open is a round trip to tccd), and writes the answer only when it
    /// changed, so an activation that finds nothing new re-renders nothing.
    /// Returns what this probe found — the value a backup record is stamped
    /// with, even if an older probe lands on `fullDiskAccess` after it.
    ///
    /// Asked at launch, whenever the app becomes active — coming back from
    /// System Settings is the only sign the grant changed — when Settings
    /// appears, and as every backup is delivered.
    @discardableResult
    func refreshFullDiskAccess() async -> FullDiskAccessStatus {
        let probe = fullDiskAccessProbe
        let status = await Task.detached(priority: .utility) { probe() }.value
        if fullDiskAccess != status { fullDiskAccess = status }
        return status
    }

    /// The Full Disk Access list in System Settings. Turning SwiftRestic on
    /// there is the user's step: the grant cannot be requested by prompt.
    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
