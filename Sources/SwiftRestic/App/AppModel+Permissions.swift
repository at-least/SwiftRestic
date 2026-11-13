import AppKit
import Foundation

extension AppModel {
    /// Probes the grant again, off the main actor (the first TCC-checked
    /// open is a round trip to tccd), and writes the answer only when it
    /// changed, so an activation that finds nothing new re-renders nothing.
    /// Returns what this probe found — the value a backup record is stamped
    /// with, even if an older probe lands on `fullDiskAccess` after it.
    ///
    /// Asked at launch, whenever the app becomes active — coming back from
    /// System Settings is the only sign the grant changed — when Settings
    /// appears, and as every backup is delivered.
    ///
    /// Every probe that finds it granted backs up again the plans whose
    /// newest backup missed files without it
    /// (`rerunBackupsMissingFullDiskAccess`) — on every such probe, not only
    /// on a change: one during launch can find the grant before the
    /// configuration is loaded, and bootstrap's own probe comes after.
    @discardableResult
    func refreshFullDiskAccess() async -> FullDiskAccessStatus {
        let probe = fullDiskAccessProbe
        let status = await Task.detached(priority: .utility) { probe() }.value
        if fullDiskAccess != status { fullDiskAccess = status }
        if status == .granted { rerunBackupsMissingFullDiskAccess() }
        return status
    }

    /// Shown where the path is chosen, rather than after a backup comes back
    /// with files skipped. String comparisons only, so a view may ask on every
    /// render.
    func fullDiskAccessNotice(for path: String) -> String? {
        guard fullDiskAccess != .granted, ProtectedLocations.needsFullDiskAccess(path, home: NSHomeDirectory()) else {
            return nil
        }
        return "Without Full Disk Access, macOS keeps parts of “\((path as NSString).abbreviatingWithTildeInPath)” out of its backups."
    }

    /// The Full Disk Access list in System Settings. Turning SwiftRestic on
    /// there is the user's step: the grant cannot be requested by prompt.
    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(FullDiskAccess.settingsURL)
    }
}
