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
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// `status` in the model's terms — one XPC round trip for both mirrors,
    /// where a caller would otherwise read `status` twice.
    static var state: LoginItemState {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .notFound: .notFound
        case .notRegistered: .off
        @unknown default: .off
        }
    }

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
