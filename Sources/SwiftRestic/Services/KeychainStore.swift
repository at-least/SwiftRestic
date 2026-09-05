import Foundation
import Security

/// Stores repository passwords and provider secret keys in the login Keychain.
///
/// Secrets never touch `config.json`; only the repository UUID is written there,
/// and it is used as the Keychain account name.
enum KeychainStore {
    static let service = "com.newlix.SwiftRestic"

    enum Slot: String {
        /// The restic repository password (`RESTIC_PASSWORD`).
        case repositoryPassword = "repository-password"
        /// The backend secret: AWS secret access key, B2 application key, …
        case providerSecret = "provider-secret"
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

    static func account(for repositoryID: UUID, slot: Slot) -> String {
        "\(repositoryID.uuidString).\(slot.rawValue)"
    }

    static func read(repositoryID: UUID, slot: Slot) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: repositoryID, slot: slot),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Writes a secret, or removes it when `value` is `nil` or empty.
    static func write(_ value: String?, repositoryID: UUID, slot: Slot) throws {
        let account = account(for: repositoryID, slot: slot)
        guard let value, !value.isEmpty else {
            try delete(repositoryID: repositoryID, slot: slot)
            return
        }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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

    static func delete(repositoryID: UUID, slot: Slot) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: repositoryID, slot: slot),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every secret belonging to a repository that is being deleted.
    static func deleteAll(repositoryID: UUID) {
        for slot in [Slot.repositoryPassword, .providerSecret] {
            try? delete(repositoryID: repositoryID, slot: slot)
        }
    }
}
