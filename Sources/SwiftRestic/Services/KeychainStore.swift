import Foundation
import Security

/// Secrets never touch `config.json`; the repository's or share's UUID
/// stored there is the base of the Keychain account name.
enum KeychainStore {
    static let service = "com.newlix.SwiftRestic"

    enum Slot: String {
        /// The restic repository password (`RESTIC_PASSWORD`).
        case repositoryPassword = "repository-password"
        /// The backend secret: AWS secret access key, …
        case providerSecret = "provider-secret"
        case sharePassword = "share-password"
    }

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private static func account(for ownerID: UUID, slot: Slot) -> String {
        "\(ownerID.uuidString).\(slot.rawValue)"
    }

    private static func query(ownerID: UUID, slot: Slot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: ownerID, slot: slot),
        ]
    }

    static func read(ownerID: UUID, slot: Slot) throws -> String? {
        var query = query(ownerID: ownerID, slot: slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            // An item that is not text is a failure, not "nothing stored"
            // (`SecretStore.load`'s rule).
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedStatus(errSecDecode)
            }
            return text
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func write(_ value: String?, ownerID: UUID, slot: Slot) throws {
        guard let value, !value.isEmpty else {
            try delete(ownerID: ownerID, slot: slot)
            return
        }

        let base = query(ownerID: ownerID, slot: slot)
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    private static func delete(ownerID: UUID, slot: Slot) throws {
        let status = SecItemDelete(query(ownerID: ownerID, slot: slot) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func deleteAll(repositoryID: UUID) throws {
        var failure: Error?
        for slot in [Slot.repositoryPassword, .providerSecret] {
            do {
                try delete(ownerID: repositoryID, slot: slot)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }
}
