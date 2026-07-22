//
//  KeychainSecretStore.swift — the ONE real Keychain-backed secrets conformer
//  (docs/plans/settings-ui.md §2.2).
//
//  API keys go to the macOS Keychain, never SQLite, never CloudKit (improving on the Rust
//  plaintext columns). A stateless `Sendable` struct wrapping the `Security` framework's
//  `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`/`SecItemDelete` — no `@unchecked Sendable`
//  needed: it carries no mutable state at all, only the constant `service` string, and every
//  `SecItem*` call is a synchronous, thread-safe system call.
//
//  Backs THREE protocols at once with one Keychain-backed implementation:
//  - `AriKit.SecretsReading` (Engine's read-only provider-keyed lookup, `apiKey(forProvider:)`)
//  - `AriKit.RecallSecretsReading` (Recall's identical read-only shape)
//  - `AriViewModels.SecretsStoring` (the Settings screen's read/write surface)
//
import AriKit
import AriViewModels
import Foundation
import Security

struct KeychainSecretStore: Sendable, SecretsReading, RecallSecretsReading, SecretsStoring {
    /// Keychain "service" namespacing every item this app stores — one item per `providerKey`
    /// ("account" in Keychain terms).
    private let service = "com.arivo.ari"

    // MARK: - AriKit.SecretsReading / AriKit.RecallSecretsReading (read-only, provider-keyed)

    func apiKey(forProvider providerKey: String) async throws -> String? {
        await apiKey(for: providerKey)
    }

    // MARK: - AriViewModels.SecretsStoring (read/write)

    func apiKey(for providerKey: String) async -> String? {
        var query = baseQuery(for: providerKey)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setAPIKey(_ key: String, for providerKey: String) async throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query = baseQuery(for: providerKey)
        var updateStatus: OSStatus = errSecItemNotFound
        // Only attempt an update if something is already there — SecItemUpdate on a
        // nonexistent item returns errSecItemNotFound, which we then fall through to add.
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let attributes = [kSecValueData as String: data]
            updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    func deleteAPIKey(for providerKey: String) async throws {
        let query = baseQuery(for: providerKey)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private func baseQuery(for providerKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerKey
        ]
    }
}

enum KeychainError: Error, Sendable {
    case encodingFailed
    case osStatus(OSStatus)
}
