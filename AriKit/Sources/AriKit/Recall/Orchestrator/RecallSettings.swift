//
//  RecallSettings.swift — the injected settings/secrets seam for the recall orchestrator
//  (plan §9(1), Slice 8).
//
//  Resolved decision (the Opus gate, shared with `Engine.SummarySettings`): a small injected
//  protocol pair, no Keychain / settings-table built here — the concrete backing is the app
//  target's job, later.
//
//  Distinct from `Engine`'s `SettingsReading`/`SecretsReading` (`Engine/Summary/SummarySettings.
//  swift`): `SummaryService` receives its provider/model as EXPLICIT per-call arguments (the
//  frontend already resolved them), whereas Ask Meetings reads the CURRENTLY CONFIGURED
//  provider/model directly from Settings (← `SettingsRepository::get_model_config`, `shell.rs:
//  293-296`) — "the same summary model configured in Settings" (`shell.rs:297-299`). That is a
//  different read shape, so recall gets its own minimal protocol rather than overloading
//  `Engine`'s.
//
import Foundation

/// The recall orchestrator's one settings read: whatever provider/model/endpoint is currently
/// configured for local-model use (← `SettingsRepository::get_model_config`).
public struct RecallModelConfig: Sendable, Equatable {
    /// The raw settings-lookup provider key (e.g. `"ollama"`, `"claude"`) — parsed via
    /// `ProviderKind.from(_:)`, same as `Engine`'s `SummaryProcessRequest.modelProviderKey`.
    public var provider: String
    public var model: String
    public var ollamaEndpoint: String?

    public init(provider: String, model: String, ollamaEndpoint: String? = nil) {
        self.provider = provider
        self.model = model
        self.ollamaEndpoint = ollamaEndpoint
    }
}

/// Injected settings reader for the recall orchestrator (← the `SettingsRepository` reads in
/// `shell.rs:293-316` / `stream.rs:79-97`).
public protocol RecallSettingsReading: Sendable {
    /// ← `SettingsRepository::get_model_config(pool)` (`shell.rs:293`). `nil` → "Configure
    /// Built-in AI or Ollama before asking meetings." (the caller's job to surface that message).
    func modelConfig() async throws -> RecallModelConfig?
}

/// Injected secrets reader for the recall orchestrator's API key lookup (← `SettingsRepository::
/// get_api_key(pool, provider)`, `shell.rs:312-316`). Rust treats a read failure as "no key"
/// (`.ok().flatten().unwrap_or_default()`) rather than failing the whole ask — conformers may
/// throw for a genuine transport error, but `RecallEngine` itself never treats "no key" as fatal
/// for keyless providers.
public protocol RecallSecretsReading: Sendable {
    func apiKey(forProvider providerKey: String) async throws -> String?
}

#if DEBUG
    /// Deterministic test double, mirroring `Engine`'s `StubSettingsReading`/`StubSecretsReading`.
    public struct StubRecallSettingsReading: RecallSettingsReading {
        public var config: RecallModelConfig?
        public var error: Error?

        public init(config: RecallModelConfig? = nil, error: Error? = nil) {
            self.config = config
            self.error = error
        }

        public func modelConfig() async throws -> RecallModelConfig? {
            if let error {
                throw error
            }
            return config
        }
    }

    public struct StubRecallSecretsReading: RecallSecretsReading {
        public var apiKeys: [String: String]

        public init(apiKeys: [String: String] = [:]) {
            self.apiKeys = apiKeys
        }

        public func apiKey(forProvider providerKey: String) async throws -> String? {
            apiKeys[providerKey]
        }
    }
#endif
