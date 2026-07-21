//
//  SummarySettings.swift — injected settings/secrets seams for `SummaryService` (plan §9(1)).
//
//  Resolved decision (the Opus gate, §9(1)): define a small `SettingsReading` + `SecretsReading`
//  PROTOCOL pair here, injected into `SummaryService`. Do NOT build a Keychain or a settings DB
//  table in this slice — the concrete backing (Keychain for API keys, a settings table/UserDefaults
//  for the rest) is the app target's job, later. This mirrors the same deferred-Settings-layer
//  seam Recall flagged (`arikit-recall.md §9(1)`).
//
//  ← the `SettingsRepository` reads scattered through `ari-engine/src/summary/service.rs:353-463`:
//  the API key column, the Ollama endpoint, the Custom OpenAI config blob, and the two dynamic
//  per-model context-size probes (Ollama's `ModelMetadataCache`, the MLX/BuiltInAI model registry).
//  Those last two are genuine HTTP/registry lookups out of scope for this port (§8 notes MLX itself
//  is a separate slice/target) — the protocol exposes them as an injection seam returning `nil` on
//  "unknown", so `SummaryService` can apply the exact same Rust fallback defaults (4000 / 1748).
//
import Foundation

/// Injected settings reader for provider/model/endpoint/token-threshold resolution.
public protocol SettingsReading: Sendable {
    /// ← `SettingsRepository::get_model_config(pool).ollama_endpoint` (`service.rs:374-385`).
    /// `nil` lets the caller fall back to the provider's own default endpoint (`localhost:11434`).
    /// Rust swallows a read failure here (info-logs, falls back to `None`) rather than hard-failing
    /// the whole summary — this port asks conformers to do the same (never throw for "unset";
    /// `SummaryService` also tolerates a thrown error the same way).
    func ollamaEndpoint() async throws -> String?

    /// ← `SettingsRepository::get_custom_openai_config` (`service.rs:388-414`). `nil` means Custom
    /// OpenAI was selected but never configured — the caller surfaces `LLMError.notConfigured`.
    func customOpenAIConfig() async throws -> CustomOpenAIConfig?

    /// ← the Ollama dynamic-context-size probe (`ModelMetadataCache.get_or_fetch`,
    /// `service.rs:424-434`) — an HTTP call to the Ollama host itself, out of scope for this port.
    /// Returning `nil` (the common/default case for any conformer that doesn't implement the
    /// probe) makes `SummaryService` fall back to the Rust "context fetch failed" default of 4000.
    func ollamaContextSize(forModel model: String) async -> Int?

    /// ← the MLX/BuiltInAI model-registry context-size lookup (`service.rs:443-463`). `nil` falls
    /// back to the Rust "unknown model" default of 1748 (`2048 - 300` overhead reserve).
    func mlxContextSize(forModel model: String) async -> Int?

    /// ← `SettingsRepository::get_model_config(pool)` (`persons/extraction.rs:86`,
    /// `persons/reconciliation.rs:111`) — the CURRENTLY CONFIGURED summarization provider+model,
    /// read directly from settings. Unlike `SummaryService` (which receives provider/model as
    /// EXPLICIT per-call arguments already resolved by the caller, `SummaryProcessRequest`),
    /// Persons extraction/reconciliation resolve their own provider from settings — the same read
    /// shape already built for recall (`RecallSettingsReading.modelConfig()`,
    /// `Recall/Orchestrator/RecallSettings.swift`), added here as the `Engine`-side mirror since
    /// Persons depends on `Engine`'s `SettingsReading`/`SecretsReading` for the rest of its
    /// provider resolution (Phase 3.4 Track H, `arikit-engine-extras.md` §2.2/§6-7). `nil` means
    /// unconfigured.
    func summaryModelConfig() async throws -> SummaryModelConfig?
}

/// ← the currently-configured summarization provider+model (`service.rs`'s `ModelConfig`, read
/// via `SettingsRepository::get_model_config`). Mirrors `RecallModelConfig`'s shape (Recall's
/// analogous read) without the `ollamaEndpoint` field — `ProviderConfigResolution.resolve(...)`
/// already calls `SettingsReading.ollamaEndpoint()` itself when the resolved kind is `.ollama`.
public struct SummaryModelConfig: Sendable, Equatable {
    /// The raw settings-lookup provider key (e.g. `"ollama"`, `"claude"`) — parsed via
    /// `ProviderKind.from(_:)`, same as `SummaryProcessRequest.modelProviderKey`.
    public var providerKey: String
    public var model: String

    public init(providerKey: String, model: String) {
        self.providerKey = providerKey
        self.model = model
    }
}

/// ← the Custom OpenAI settings blob (`service.rs:388-414`).
public struct CustomOpenAIConfig: Sendable, Equatable {
    public var endpoint: String
    public var apiKey: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(
        endpoint: String,
        apiKey: String? = nil,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

/// Injected secrets reader for API keys. NOT a Keychain implementation — the app target supplies a
/// real Keychain-backed conformer later (§9(1)).
public protocol SecretsReading: Sendable {
    /// ← `SettingsRepository::get_api_key(pool, provider)` (`service.rs:358-371`). `providerKey` is
    /// the raw settings-lookup key (e.g. `"openai"`, `"claude"`) — the same string
    /// `ProviderKind.from(_:)` parses.
    func apiKey(forProvider providerKey: String) async throws -> String?
}
