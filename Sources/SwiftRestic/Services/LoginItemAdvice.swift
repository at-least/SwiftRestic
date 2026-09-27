import Foundation

/// What to say about starting at login, and where. The scheduler lives in
/// the app's process, so a schedule stops at the first restart or logout
/// unless the app comes back by itself; the plan editor and the Overview's
/// Next runs card say so, from these rules.
enum LoginItemAdvice {
    enum Offer: Equatable, Sendable {
        /// Registering would work: one click.
        case startAtLogin
        /// A registration exists and waits for the user in System Settings.
        case awaitingApproval
        /// Registering from here is refused (a build folder, Downloads).
        case moveToApplications
    }

    /// Confirms a click on the editor's Start at Login — the words the
    /// Settings caption uses for the same state.
    static let enabledConfirmation = "SwiftRestic will start at login."

    /// Nothing once the app starts at login. Otherwise the one step left:
    /// approving a registration that already exists comes before where the
    /// copy lives, since approving is all that registration still needs.
    static func offer(startsAtLogin: Bool, needsApproval: Bool, isInstallable: Bool) -> Offer? {
        if startsAtLogin { return nil }
        if needsApproval { return .awaitingApproval }
        if !isInstallable { return .moveToApplications }
        return .startAtLogin
    }

    /// Whether the scheduler runs this plan by itself at all. A timed pause
    /// still counts: it ends by itself, and the schedule behind it dies
    /// with the process like any other.
    static func isScheduled(_ plan: BackupPlan) -> Bool {
        plan.isEnabled && plan.schedule.frequency != .manual
    }

    /// The plan editor's offer: only when saving turns a schedule on — a
    /// new scheduled plan, or a manual or paused one whose draft is
    /// scheduled. An ordinary edit of a plan already on its schedule says
    /// nothing; the Next runs card covers the steady state.
    static func editorOffer(
        draft: BackupPlan,
        initial: BackupPlan?,
        isNew: Bool,
        startsAtLogin: Bool,
        needsApproval: Bool,
        isInstallable: Bool
    ) -> Offer? {
        guard isScheduled(draft), isNew || !(initial.map(isScheduled) ?? false) else { return nil }
        return offer(startsAtLogin: startsAtLogin, needsApproval: needsApproval, isInstallable: isInstallable)
    }

    static func caption(for offer: Offer) -> String {
        switch offer {
        case .startAtLogin:
            "Scheduled backups run only while SwiftRestic is open, and it won't reopen after a restart or logout."
        case .awaitingApproval:
            "SwiftRestic starts at login once you allow it in System Settings › General › Login Items. Until then, scheduled backups stop after a restart or logout."
        case .moveToApplications:
            "Scheduled backups run only while SwiftRestic is open. It can start at login once it is in your Applications folder."
        }
    }
}
