import Foundation
import Testing

/// The in-memory store's answers must match the Keychain store's: a test
/// written against the double is read as a statement about production.
@Suite("secret store")
struct SecretStoreTests {
    @Test("save matches the Keychain: an empty password keeps the stored one, an empty provider secret removes it")
    func saveMatchesTheKeychain() async throws {
        let id = UUID()
        let secrets = SecretStore.inMemory([id: (password: "kept", providerSecret: "old")])

        // `SecretStore.save`'s guard: an empty password never reaches
        // `KeychainStore.write`, which would delete the stored one.
        try await secrets.save(id, "", nil)
        #expect(try await secrets.load(id).password == "kept")
        #expect(try await secrets.load(id).providerSecret == "old")

        // `KeychainStore.write` deletes on nil or empty, so an empty
        // provider secret clears the stored one rather than storing "".
        try await secrets.save(id, nil, "")
        let stored = try await secrets.load(id)
        #expect(stored.password == "kept")
        #expect(stored.providerSecret == nil)
    }
}
