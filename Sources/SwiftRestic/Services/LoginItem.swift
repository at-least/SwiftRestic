import Foundation
import ServiceManagement

/// The login item's state as the model mirrors it: one daemon read answers
/// both "does it start at login" and "is it waiting for approval".
enum LoginItemState: Sendable, Equatable {
    case enabled, off, needsApproval, notFound
}

/// Starting SwiftRestic at login.
///
/// The scheduler only runs while the app is running, so a plan fires reliably
/// only if the app comes back after a restart. `SMAppService` registers that
/// without a LaunchAgent plist or helper tool.
enum LoginItem {
    /// The daemon's answer in the model's terms: a synchronous XPC round
    /// trip, so callers read it off the main actor.
    static var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notFound: .notFound
        case .notRegistered: .off
        @unknown default: .off
        }
    }

    /// What to tell the user about a state.
    static func description(of state: LoginItemState) -> String {
        switch state {
        case .enabled: "SwiftRestic will start at login."
        case .off: "SwiftRestic will not start at login, so scheduled backups only run while it is open."
        case .needsApproval: "Waiting for approval in System Settings › General › Login Items."
        case .notFound: "macOS could not find this copy of SwiftRestic. Move it to your Applications folder and try again."
        }
    }

    /// Whether this copy of the app is somewhere a login item can point at.
    ///
    /// A build folder's bundle changes every compile, so a login item
    /// registered from there ends up pointing at a binary that no longer
    /// exists — and the stale entry outlives the build.
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
