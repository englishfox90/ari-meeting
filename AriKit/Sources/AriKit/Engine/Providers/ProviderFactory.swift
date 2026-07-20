//
//  ProviderFactory.swift — constructs an `LLMClient` conformer from a `ProviderConfig`
//  (plan §2.2, ← the Rust `match provider` dispatch inside `generate_summary`,
//  `llm_client.rs:181-238`).
//
//  SLICE B UPDATE: the OpenAI-compatible family (`OpenAICompatibleClient` — OpenAI/Groq/
//  OpenRouter/Ollama/CustomOpenAI) and `AnthropicClient` (Claude) are now real conformers. The
//  loopback gate for `.ollama` (§7, a load-bearing invariant) still runs BEFORE construction, same
//  as Slice A.
//  SLICE C UPDATE: `.claudeCLI` now constructs a real `ClaudeCLIClient` on macOS (`#if
//  os(macOS)`); on iOS it honestly throws `.providerUnavailable` (the kind is absent from the
//  factory there, plan §2.3). `MLXClient` is injected (§8: it lives in the separate
//  `AriKitEngineMLX` product, which depends on `AriKit`, not vice versa, so it can't be constructed
//  directly in this file) — unset → `.mlx` honestly throws `.providerUnavailable`.
//  SLICE D UPDATE: `.appleFoundation` now constructs a real `FoundationModelsClient`.
//  Construction always succeeds (it only validates `config.kind`); the actual on-device-availability
//  gate runs inside `generate()` — mirroring how `.claudeCLI`'s binary resolution is deferred to
//  `generate` too, and matching Rust's shape (`apple/helper.rs::summarize` checks availability at
//  call time, not at provider-selection time). No-Fake-State: an unavailable device still never
//  gets a fake client — `generate()` throws `.providerUnavailable` honestly instead.
//
import Foundation

public enum ProviderFactory {
    /// Constructs an `MLXClient` for a resolved config. Injected by the app (or `AriKitEngineMLX`)
    /// at launch — `MLXClient` lives in a separate product so core `AriKit` stays Metal-toolchain-
    /// free and headlessly `swift test`-able (§8). Left `nil` → `.mlx` throws
    /// `.providerUnavailable`.
    public typealias MLXClientProvider = @Sendable (ProviderConfig) -> any LLMClient

    /// ← the `match provider` dispatch in `generate_summary` (`llm_client.rs:181-238`). `session`
    /// lets callers (and tests) inject a stubbed `URLSession` for the HTTP conformers; defaults to
    /// `.shared` for production use.
    public static func make(
        config: ProviderConfig,
        session: URLSession = .shared,
        mlxClientProvider: MLXClientProvider? = nil
    ) throws -> any LLMClient {
        // ← the model-required guard applies to every kind EXCEPT `.claudeCLI`: Rust
        // (`claude_cli.rs:109-110,139-140`) treats an empty/"default" model as "use the CLI's
        // configured default" and omits `--model` entirely (see `ClaudeCLIClient.arguments`), so an
        // empty model there is a valid configuration, not a `.notConfigured` error.
        if config.kind != .claudeCLI {
            guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LLMError.notConfigured("model is required for \(config.kind)")
            }
        }

        switch config.kind {
        case .ollama:
            // ← `is_loopback_ollama_endpoint` gate (`shell.rs:302`) — applied here in the summary
            // path too, so a local-only Ollama configuration can never silently point off-device.
            // Runs BEFORE construction, matching Rust's shape (the gate lives outside
            // `generate_summary` in the caller, `shell.rs:302`, but the invariant is the same).
            guard Recall.isLoopbackOllamaEndpoint(config.ollamaEndpoint) else {
                throw LLMError.loopbackViolation
            }
            return try OpenAICompatibleClient(config: config, session: session)

        case .customOpenAI:
            guard let endpoint = config.customOpenAIEndpoint,
                  !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw LLMError.notConfigured("customOpenAIEndpoint is required for .customOpenAI")
            }
            return try OpenAICompatibleClient(config: config, session: session)

        case .openAI, .groq, .openRouter:
            return try OpenAICompatibleClient(config: config, session: session)

        case .claude:
            return try AnthropicClient(config: config, session: session)

        case .claudeCLI:
            #if os(macOS)
                return try ClaudeCLIClient(config: config)
            #else
                // ← the kind is absent from the factory on iOS (plan §2.3, Slice C) — `Process`
                // spawn / login-shell resolution have no iOS equivalent.
                throw LLMError.providerUnavailable("ClaudeCLI is unavailable on this platform")
            #endif

        case .appleFoundation:
            return try FoundationModelsClient(config: config)

        case .mlx:
            guard let mlxClientProvider else {
                throw LLMError.providerUnavailable(
                    "MLX client not registered (AriKitEngineMLX not linked) — see plan §8"
                )
            }
            return mlxClientProvider(config)
        }
    }
}
