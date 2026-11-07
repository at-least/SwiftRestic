import Foundation

/// What to say about starting at login, and where: the plan editor's
/// captions, composed from these rules. The scheduler lives in this process,
/// so a schedule does not survive a restart or logout by itself
/// (`LoginItem`).
enum LoginItemAdvice {
    enum Offer: Equatable, Sendable {
        case startAtLogin
        /// A registration exists and waits for the user in System Settings.
        case awaitingApproval
        /// Registering from here is refused (a build folder, Downloads).
        case moveToApplications
    }

    static let registeringOnSave = "SwiftRestic will start at login, so this schedule keeps running after a restart."

    /// Nil once the app starts at login. Otherwise approval comes before
    /// location: an existing registration needs only approving, wherever the
    /// copy lives.
    static func offer(startsAtLogin: Bool, needsApproval: Bool, isInstallable: Bool) -> Offer? {
        if startsAtLogin { return nil }
        if needsApproval { return .awaitingApproval }
        if !isInstallable { return .moveToApplications }
        return .startAtLogin
    }

    /// The plan editor's offer: only when saving turns a schedule on — a
    /// new scheduled plan, or a manual one whose draft is scheduled. An ordinary edit of a plan already on its schedule says
    /// nothing; Settings' switch carries the steady state.
    static func editorOffer(
        draft: BackupPlan,
        initial: BackupPlan?,
        isNew: Bool,
        startsAtLogin: Bool,
        needsApproval: Bool,
        isInstallable: Bool
    ) -> Offer? {
        guard draft.isScheduled, isNew || !(initial.map({ $0.isScheduled }) ?? false) else { return nil }
        return offer(startsAtLogin: startsAtLogin, needsApproval: needsApproval, isInstallable: isInstallable)
    }

    /// The first schedule asks for what a schedule needs, said beside the
    /// button that saves it. Only the first: a later plan never undoes a switch
    /// the user turned off in Settings.
    static func registersOnSave(draft: BackupPlan, among plans: [BackupPlan], offer: Offer?) -> Bool {
        offer == .startAtLogin && draft.isScheduled && !plans.contains(where: { $0.isScheduled })
    }

    static func caption(for offer: Offer) -> String {
        switch offer {
        case .startAtLogin:
            "Scheduled backups run only while SwiftRestic is open, and it won’t reopen after a restart or logout."
        case .awaitingApproval:
            "SwiftRestic starts at login once you allow it in Login Items. Until then, scheduled backups stop after a restart or logout."
        case .moveToApplications:
            "Scheduled backups run only while SwiftRestic is open. It can start at login once it is in your Applications folder."
        }
    }
}
