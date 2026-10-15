import Foundation

/// Where repository secrets come from.
///
/// The real implementation is the login Keychain. It is injectable so the backup
/// path can be exercised in tests without a Keychain prompt, and so a test never
/// writes to the developer's own login keychain.
struct SecretStore: Sendable {
    /// Failures throw rather than read as `nil`: a Keychain failure (an
    /// authorisation prompt the user declined, `errSecInteractionNotAllowed`
    /// while the Mac is still locked) must not wear the "no password stored"
    /// costume — the app would say "add a password in the repository
    /// settings" about a password that is sitting right there, and a
    /// scheduled backup's diagnosis would point nowhere near the truth.
    var load: @Sendable (UUID) async throws -> (password: String?, providerSecret: String?)
    var save: @Sendable (UUID, String?, String?) async throws -> Void
    var remove: @Sendable (UUID) async -> Void
    /// A network share's password, by the share's ID (`NetworkShare`).
    var loadSharePassword: @Sendable (UUID) async throws -> String?
    /// Stores a share's password; nil or empty removes it.
    var saveSharePassword: @Sendable (UUID, String?) async throws -> Void

    /// `SecItem*` calls block and macOS may put an authorisation dialog in front
    /// of them, so every one of them is pushed off the caller's actor.
    static let keychain = SecretStore(
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
            await Task.detached(priority: .userInitiated) {
                KeychainStore.deleteAll(repositoryID: repositoryID)
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

    /// The app's store: the login Keychain — or, in a debug build, a
    /// capture run's environment (`injectedForCapture`).
    static var standard: SecretStore {
        #if DEBUG
        if let injected = injectedForCapture { return injected }
        #endif
        return .keychain
    }

    #if DEBUG
    /// A capture run's password from the environment in the Keychain's
    /// place — `SWIFTRESTIC_REPO_PASSWORD`, with `SWIFTRESTIC_REPO_SECRET` —
    /// only while `SWIFTRESTIC_CONFIG_DIR` points the run at a throwaway
    /// configuration, so a stale variable in a developer's shell cannot
    /// silently feed the wrong password to a normal debug run; nil
    /// otherwise. One store for every reader of "what password this
    /// repository has" — the run path and the repository editor — which
    /// would otherwise disagree about whether a password exists. A network
    /// share's password is `SWIFTRESTIC_SHARE_PASSWORD`, none when unset.
    /// Saves and removals go nowhere: a scratch run never touches the login
    /// Keychain.
    static var injectedForCapture: SecretStore? {
        let environment = ProcessInfo.processInfo.environment
        guard let password = environment["SWIFTRESTIC_REPO_PASSWORD"], !password.isEmpty,
              environment["SWIFTRESTIC_CONFIG_DIR"] != nil
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

    /// In-memory store for tests.
    static func inMemory(_ initial: [UUID: (password: String, providerSecret: String?)] = [:]) -> SecretStore {
        let box = InMemorySecrets(initial)
        return SecretStore(
            // Non-throwing: an in-memory read cannot fail, and a
            // non-throwing closure satisfies the throwing requirement.
            load: { await box.load($0) },
            save: { await box.save($0, $1, $2) },
            remove: { await box.remove($0) },
            loadSharePassword: { await box.sharePassword($0) },
            saveSharePassword: { await box.saveSharePassword($0, $1) }
        )
    }
}

private actor InMemorySecrets {
    private var storage: [UUID: (password: String?, providerSecret: String?)]

    init(_ initial: [UUID: (password: String, providerSecret: String?)]) {
        storage = initial.mapValues { ($0.password, $0.providerSecret) }
    }

    func load(_ id: UUID) -> (password: String?, providerSecret: String?) {
        storage[id] ?? (nil, nil)
    }

    func save(_ id: UUID, _ password: String?, _ providerSecret: String?) {
        var entry = storage[id] ?? (nil, nil)
        if let password, !password.isEmpty { entry.password = password }
        if let providerSecret { entry.providerSecret = providerSecret }
        storage[id] = entry
    }

    func remove(_ id: UUID) { storage[id] = nil }

    private var sharePasswords: [UUID: String] = [:]

    func sharePassword(_ id: UUID) -> String? { sharePasswords[id] }

    func saveSharePassword(_ id: UUID, _ password: String?) {
        sharePasswords[id] = password.flatMap { $0.isEmpty ? nil : $0 }
    }
}
