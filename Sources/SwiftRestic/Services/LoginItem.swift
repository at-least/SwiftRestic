import Foundation
import ServiceManagement

/// The login item's state as the model mirrors it: one daemon read answers
/// both "does it start at login" and "is it waiting for approval".
enum LoginItemState: Sendable, Equatable {
    case enabled, off, needsApproval, notFound
}

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

    /// Said while macOS waits for the user to allow the login item: the
    /// scheduler lives in this process, so a schedule does not survive a
    /// restart or logout by itself.
    static let approvalNeeded = "SwiftRestic starts at login once you allow it in Login Items. Until then, scheduled backups stop after a restart or logout."

    /// Whether this copy of the app is somewhere a login item can point at.
    ///
    /// A build folder's bundle changes every compile, so a login item
    /// registered from there ends up pointing at a binary that no longer
    /// exists — and the stale entry outlives the build.
    /// Only an app bundle: a test runner's xctest sits in Xcode, inside
    /// /Applications, and must never be registered.
    static func isInstallableLocation(_ path: String) -> Bool {
        guard path.hasSuffix(".app"), !path.contains("/DerivedData/"), !path.contains("/Build/Products/") else {
            return false
        }
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    static var isInInstallableLocation: Bool {
        isInstallableLocation(Bundle.main.bundleURL.resolvingSymlinksInPath().path)
    }

    /// What to set the login item to, or nil to leave it: registered while
    /// any plan has a schedule, unregistered once none has (user decision —
    /// there is no switch; turning it off is System Settings ▸ General ▸
    /// Login Items). An item waiting for approval counts as registered: the
    /// answer is the user's to give there. Never registered from outside
    /// the Applications folder.
    static func change(hasScheduledPlan: Bool, state: LoginItemState, isInstallable: @autoclosure () -> Bool) -> Bool? {
        let isRegistered = state == .enabled || state == .needsApproval
        guard hasScheduledPlan != isRegistered else { return nil }
        if hasScheduledPlan, !isInstallable() { return nil }
        return hasScheduledPlan
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    @MainActor
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
