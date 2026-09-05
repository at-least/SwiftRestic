import Foundation

/// Where repository secrets come from.
///
/// The real implementation is the login Keychain. It is injectable so the backup
/// path can be exercised in tests without a Keychain prompt, and so a test never
/// writes to the developer's own login keychain.
struct SecretStore: Sendable {
    var load: @Sendable (UUID) async -> (password: String?, providerSecret: String?)
    var save: @Sendable (UUID, String?, String?) async throws -> Void
    var remove: @Sendable (UUID) async -> Void

    /// `SecItem*` calls block and macOS may put an authorisation dialog in front
    /// of them, so every one of them is pushed off the caller's actor.
    static let keychain = SecretStore(
        load: { repositoryID in
            await Task.detached(priority: .userInitiated) {
                (
                    try? KeychainStore.read(repositoryID: repositoryID, slot: .repositoryPassword),
                    try? KeychainStore.read(repositoryID: repositoryID, slot: .providerSecret)
                )
            }.value
        },
        save: { repositoryID, password, providerSecret in
            try await Task.detached(priority: .userInitiated) {
                if let password, !password.isEmpty {
                    try KeychainStore.write(password, repositoryID: repositoryID, slot: .repositoryPassword)
                }
                if let providerSecret {
                    try KeychainStore.write(providerSecret, repositoryID: repositoryID, slot: .providerSecret)
                }
            }.value
        },
        remove: { repositoryID in
            await Task.detached(priority: .userInitiated) {
                KeychainStore.deleteAll(repositoryID: repositoryID)
            }.value
        }
    )

    /// In-memory store for tests.
    static func inMemory(_ initial: [UUID: (password: String, providerSecret: String?)] = [:]) -> SecretStore {
        let box = InMemorySecrets(initial)
        return SecretStore(
            load: { await box.load($0) },
            save: { await box.save($0, $1, $2) },
            remove: { await box.remove($0) }
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
}
