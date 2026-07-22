//
//  SecretsStoring.swift — the injected read/write secrets seam for `SettingsViewModel`
//  (docs/plans/settings-ui.md §2.3).
//
//  Distinct from `AriKit.Engine`'s `SecretsReading` / `AriKit.Recall`'s `RecallSecretsReading`
//  (both read-only, provider-key-keyed lookups the engine/recall orchestrators consume): this is
//  the Settings SCREEN's own read/write surface, keyed by a plain provider string the VM never
//  interprets. The concrete conformer (`Ari/App/Settings/KeychainSecretStore.swift`) backs all
//  three protocols at once — one Keychain-backed struct, three narrow seams.
//
//  API keys never round-trip through this VM as visible text: `SettingsViewModel.hasAPIKey(for:)`
//  is presence-only (No-Fake-State's mirror image — never LEAK real secret state either).
//
import Foundation

public protocol SecretsStoring: Sendable {
    /// The stored API key for `providerKey`, or `nil` if none is set. Callers besides
    /// `hasAPIKey(for:)` should not surface this value in UI.
    func apiKey(for providerKey: String) async -> String?

    func setAPIKey(_ key: String, for providerKey: String) async throws

    func deleteAPIKey(for providerKey: String) async throws
}

#if DEBUG
    /// Deterministic in-memory test double for headless `swift test` (no Keychain access) —
    /// mirrors `Engine`'s `StubSettingsReading`/`Recall`'s `StubRecallSecretsReading`.
    public actor StubSecretsStoring: SecretsStoring {
        private var storage: [String: String]

        public init(initial: [String: String] = [:]) {
            storage = initial
        }

        public func apiKey(for providerKey: String) async -> String? {
            storage[providerKey]
        }

        public func setAPIKey(_ key: String, for providerKey: String) async throws {
            storage[providerKey] = key
        }

        public func deleteAPIKey(for providerKey: String) async throws {
            storage.removeValue(forKey: providerKey)
        }
    }
#endif
