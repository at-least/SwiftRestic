import Foundation
import ServiceManagement

/// Starting SwiftRestic at login.
///
/// The scheduler only runs while the app is running, so for a plan to fire
/// reliably the app has to come back after a restart. `SMAppService` is the
/// modern way to ask for that — no LaunchAgent plist and no helper tool.
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// What to tell the user about the current state.
    static var statusDescription: String {
        switch status {
        case .enabled: "SwiftRestic will start at login."
        case .notRegistered: "SwiftRestic will not start at login, so scheduled backups only run while it is open."
        case .requiresApproval: "Waiting for approval in System Settings › General › Login Items."
        case .notFound: "macOS could not find this copy of the app. Move it to /Applications and try again."
        @unknown default: "Unknown state."
        }
    }

    static var needsApproval: Bool { status == .requiresApproval }

    /// Whether this copy of the app is somewhere a login item can point at.
    ///
    /// A build running out of DerivedData gets a fresh bundle on every compile,
    /// so a login item registered from there ends up pointing at a binary that no
    /// longer exists — and that stale entry outlives the build it came from.
    static func isInstallableLocation(_ path: String) -> Bool {
        guard !path.contains("/DerivedData/"), !path.contains("/Build/Products/") else {
            return false
        }
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    static var isInInstallableLocation: Bool {
        isInstallableLocation(Bundle.main.bundleURL.resolvingSymlinksInPath().path)
    }

    static let notInstalledMessage =
        "Move SwiftRestic to your Applications folder first. A login item registered "
            + "from a build folder points at a copy that will not be there next time."

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the pane where the user can approve or remove the login item.
    @MainActor
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
