import Foundation

/// The login Keychain, injectable so a test never prompts for or writes to
/// the developer's own login keychain.
struct SecretStore: Sendable {
    /// Failures throw rather than read as `nil`: a declined authorisation
    /// prompt or `errSecInteractionNotAllowed` on a locked Mac is not "no
    /// password stored", and reading it as one sends the user to add a
    /// password that is already there.
    var load: @Sendable (UUID) async throws -> (password: String?, providerSecret: String?)
    var save: @Sendable (UUID, String?, String?) async throws -> Void
    var remove: @Sendable (UUID) async throws -> Void
    var loadSharePassword: @Sendable (UUID) async throws -> String?
    /// Stores a share's password; nil or empty removes it.
    var saveSharePassword: @Sendable (UUID, String?) async throws -> Void

    /// `SecItem*` calls block and macOS may put an authorisation dialog in front
    /// of them, so every one of them is pushed off the caller's actor.
    private static let keychain = SecretStore(
        load: { repositoryID in
            try await Task.detached(priority: .userInitiated) {
                (
                    try KeychainStore.read(ownerID: repositoryID, slot: .repositoryPassword),
                    try KeychainStore.read(ownerID: repositoryID, slot: .providerSecret)
                )
            }.value
        },
        save: { repositoryID, password, providerSecret in
            try await Task.detached(priority: .userInitiated) {
                if let password, !password.isEmpty {
                    try KeychainStore.write(password, ownerID: repositoryID, slot: .repositoryPassword)
                }
                if let providerSecret {
                    try KeychainStore.write(providerSecret, ownerID: repositoryID, slot: .providerSecret)
                }
            }.value
        },
        remove: { repositoryID in
            try await Task.detached(priority: .userInitiated) {
                try KeychainStore.deleteAll(repositoryID: repositoryID)
            }.value
        },
        loadSharePassword: { shareID in
            try await Task.detached(priority: .userInitiated) {
                try KeychainStore.read(ownerID: shareID, slot: .sharePassword)
            }.value
        },
        saveSharePassword: { shareID, password in
            try await Task.detached(priority: .userInitiated) {
                try KeychainStore.write(password, ownerID: shareID, slot: .sharePassword)
            }.value
        }
    )

    static var standard: SecretStore {
        #if DEBUG
        if let injected = injectedForCapture { return injected }
        #endif
        return .keychain
    }

    #if DEBUG
    /// A capture run's secrets from the environment in the Keychain's place,
    /// only while `SWIFTRESTIC_CONFIG_DIR` points at a throwaway
    /// configuration, so a stale variable in a developer's shell cannot feed
    /// a normal debug run. One store for every reader — the run path and the
    /// repository editor — so they agree on whether a password exists.
    /// Saves and removals go nowhere.
    private static var injectedForCapture: SecretStore? {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["SWIFTRESTIC_REPO_PASSWORD"], !password.isEmpty,
              environment["SWIFTRESTIC_CONFIG_DIR"]?.isEmpty == false
        else { return nil }
        let providerSecret = environment["SWIFTRESTIC_REPO_SECRET"]
        let sharePassword = environment["SWIFTRESTIC_SHARE_PASSWORD"]
        return SecretStore(
            load: { _ in (password, providerSecret) },
            save: { _, _, _ in },
            remove: { _ in },
            loadSharePassword: { _ in sharePassword },
            saveSharePassword: { _, _ in }
        )
    }
    #endif
}
