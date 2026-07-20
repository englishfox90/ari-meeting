//
//  LLMClient.swift — the provider protocol (plan §2.2, ← ari-engine/src/summary/llm_client.rs).
//
//  `generate_summary`'s 12-argument free function (llm_client.rs:119) collapses into a Sendable
//  request value (`LLMRequest`) + a Sendable protocol (`LLMClient`) whose conformer already holds
//  its own config (`ProviderConfig`). `ProviderFactory.make(config:)` (ProviderFactory.swift)
//  replaces the Rust `match provider` block.
//
import Foundation

/// One LLM backend. `generate` is the single-shot port of `generate_summary`; `stream` is the
/// port of `generate_summary_stream` (llm_stream.rs). Sendable so it crosses actor boundaries
/// freely — the SummaryService, the recall Orchestrator, and a background task can all hold
/// `any LLMClient` without isolation ceremony.
public protocol LLMClient: Sendable {
    var kind: ProviderKind { get }

    /// ← `generate_summary`. Returns the full completion. Cooperative cancellation is the
    /// caller's job (`Task.checkCancellation()` inside the conformer's request loop).
    func generate(_ request: LLMRequest) async throws -> String

    /// ← `generate_summary_stream` (`llm_stream.rs`). Yields incremental text deltas, then
    /// finishes (or finishes with an error).
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

public extension LLMClient {
    /// Graceful non-streaming fallback (← `llm_stream.rs:69-97`, the ClaudeCLI/FoundationModels
    /// path): run the full `generate`, emit its result once, then finish. Conformers that CAN
    /// stream token-by-token (the HTTP/MLX conformers) override this.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let full = try await generate(request)
                    if !full.isEmpty {
                        continuation.yield(full)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ← the free arguments of `generate_summary` (`llm_client.rs:119`): `system_prompt`/`user_prompt`
/// plus the tunables that only `CustomOpenAI` actually applies (`llm_client.rs:260`,
/// `llm_stream.rs:171`) — every other HTTP provider ignores them, matching Rust exactly.
public struct LLMRequest: Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?

    public init(
        system: String,
        user: String,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil
    ) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
    }
}

/// ← `LLMProvider` (`llm_client.rs:66`), minus `BuiltInAI` (the llama-helper sidecar — RETIRED,
/// replaced by `.mlx`; `swift-migration-plan.md:98,297`).
public enum ProviderKind: String, Sendable, CaseIterable {
    case openAI
    case claude
    case groq
    case ollama
    case openRouter
    case customOpenAI
    case claudeCLI
    case appleFoundation
    case mlx

    /// Case-insensitive parse (← `LLMProvider::from_str`, `llm_client.rs:84`), including the
    /// legacy `"builtin-ai"` / `"local-llama"` / `"localllama"` aliases — Rust mapped these to the
    /// now-retired `BuiltInAI`; here they map to `.mlx`, its Swift successor.
    public static func from(_ s: String) -> ProviderKind? {
        switch s.lowercased() {
        case "openai": .openAI
        case "claude": .claude
        case "groq": .groq
        case "ollama": .ollama
        case "openrouter": .openRouter
        case "custom-openai": .customOpenAI
        case "claude-cli": .claudeCLI
        case "apple-foundation": .appleFoundation
        case "builtin-ai", "local-llama", "localllama", "mlx": .mlx
        default: nil
        }
    }
}

/// The error surface for provider construction and generation (← the `String` errors
/// `generate_summary` returns, given real, matchable cases instead of ad hoc strings).
public enum LLMError: Error, Sendable {
    /// Missing/invalid API key, endpoint, or model for the requested provider.
    case notConfigured(String)
    /// The configured Ollama endpoint is not on this device (§7 — the loopback-only invariant).
    case loopbackViolation
    /// HTTP/transport/parse failure talking to the provider.
    case requestFailed(String)
    /// ← `"Summary generation was cancelled"`.
    case cancelled
    /// MLX/FoundationModels (or any on-device backend) is not available on this device
    /// (No-Fake-State — the factory never substitutes a fake client for an unavailable one).
    case providerUnavailable(String)
}
