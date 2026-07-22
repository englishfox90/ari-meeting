//
//  MLXClient.swift — the on-device MLX summary conformer (plan §1.3, docs/plans/
//  arikit-engine-extras.md, Track E).
//
//  ← the S1 spike's proven call shape (`spikes/mlx-swift-s1/Sources/mlx-swift-s1/Entry.swift:
//  99-132`): resolve a `ModelContainer` (via `ModelHost`, warm-cached), build a `ChatSession`
//  with `request.system` as `instructions` + `additionalContext: ["enable_thinking": false]`
//  (the hard Qwen3.x gotcha — omitting it leaks `<think>` blocks into the summary), then
//  `respond(to:)`/`streamResponse(to:)`.
//
//  Text-only — no `MLXVLM` (the spike's VLM loader is dropped; summary generation never needs
//  images/video/audio inputs).
//
//  No-Fake-State (plan §1.7 / §7): an unavailable/unloadable model throws
//  `LLMError.providerUnavailable`; a generation failure throws `.requestFailed`. Never a
//  fabricated summary. MLX is stateless w.r.t. the Store — no schema, no Store writes here.
//
import AriKit
import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon

/// The on-device MLX conformer for `.mlx` (`ProviderKind.mlx`, `LLMClient.swift:85`). Constructed
/// via `AriKitEngineMLX.mlxClientProvider` and injected into `ProviderFactory.make(config:
/// mlxClientProvider:)` by the app at launch (`MLXRegistration.swift`).
///
/// `final class` (not a struct) because it holds a reference to the shared `ModelHost` actor and
/// per-instance generation defaults resolved once at construction — mirrors the plan's surface
/// (`final class MLXClient: LLMClient`, §1.3). Every stored property is an immutable, `Sendable`
/// value (`String`/`Int?`/`Double?`/the `ModelHost` actor reference), so this type satisfies
/// `LLMClient: Sendable` structurally without `@unchecked Sendable`.
public final class MLXClient: LLMClient {
    public let kind: ProviderKind = .mlx

    /// Fallback generation budget when neither the request nor the resolved config supplies one.
    /// Bounded (not unbounded) generation when a caller supplies no explicit budget. Trimmed from
    /// the S1 spike's 1200 (`Entry.swift:64`) to 800: observed final reports land ~500–600 tokens,
    /// so 800 leaves headroom without paying decode time for tokens the model won't use.
    static let defaultMaxTokens = 800

    /// ← the S1 spike's fixed sampling parameters (`Entry.swift:125-126`) — used only when neither
    /// the request nor the resolved `ProviderConfig` supplies a value.
    static let defaultTemperature = 0.5
    static let defaultTopP = 0.8

    /// The HF repo id to load (← `ProviderConfig.model`, e.g. "mlx-community/Qwen3.5-4B-4bit").
    private let repoId: String
    private let configMaxTokens: Int?
    private let configTemperature: Double?
    private let configTopP: Double?
    private let host: ModelHost

    /// - Parameters:
    ///   - config: resolved provider config; `config.model` is the HF repo id to load.
    ///   - host: the `ModelHost` actor to resolve the warm `ModelContainer` through. Defaults to
    ///     the process-wide `.shared` cache; tests inject a fresh instance so they never share
    ///     load state with production code (or with each other).
    ///
    /// Non-throwing by design: this initializer is called from
    /// `ProviderFactory.MLXClientProvider`, a **non-throwing** closure type
    /// (`@Sendable (ProviderConfig) -> any LLMClient`, `ProviderFactory.swift:29`) — the factory
    /// already guarantees `config.kind == .mlx` and a non-empty `config.model` before invoking it
    /// (`ProviderFactory.swift:43-47,86-92`), so there is nothing left to validate here.
    public init(config: ProviderConfig, host: ModelHost = .shared) {
        repoId = config.model
        configMaxTokens = config.maxTokens
        configTemperature = config.temperature
        configTopP = config.topP
        self.host = host
    }

    // MARK: - LLMClient

    public func generate(_ request: LLMRequest) async throws -> String {
        try Task.checkCancellation()

        let container = try await resolveContainer()
        let session = makeSession(container: container, request: request)

        let raw: String
        do {
            raw = try await session.respond(to: request.user)
        } catch {
            throw LLMError.requestFailed("MLX generation failed: \(error)")
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError.requestFailed("MLX model returned an empty summary")
        }
        return trimmed
    }

    /// True streaming (← `ChatSession.streamResponse(to:)`, verified against the checked-out
    /// `mlx-swift-lm` 3.31.4 source at `Libraries/MLXLMCommon/ChatSession.swift:479-489` — it
    /// yields `String` chunks directly, so this overrides the `LLMClient` extension's single-yield
    /// fallback instead of falling back to it, per plan §1.5(a)).
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let container = try await self.resolveContainer()
                    let session = self.makeSession(container: container, request: request)
                    for try await chunk in session.streamResponse(to: request.user) {
                        if Task.isCancelled {
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.requestFailed("MLX streaming failed: \(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func resolveContainer() async throws -> ModelContainer {
        do {
            return try await host.container(forRepoId: repoId)
        } catch {
            // No-Fake-State (plan §7): an unloadable on-device model is an honest
            // `.providerUnavailable`, never a fabricated client/response.
            throw LLMError.providerUnavailable("MLX model \"\(repoId)\" is unavailable: \(error)")
        }
    }

    /// Builds a fresh `ChatSession` per request — `ChatSession` documents itself as
    /// "not thread-safe... each session should be used from a single task/thread at a time"
    /// (`ChatSession.swift:142-144`), while the underlying `ModelContainer` (cached by `ModelHost`)
    /// "handles thread safety for model operations" — so a new session per call is the correct,
    /// concurrency-safe usage, matching the S1 spike's own per-run construction (`Entry.swift:
    /// 120-129`).
    private func makeSession(container: ModelContainer, request: LLMRequest) -> ChatSession {
        let maxTokens = request.maxTokens ?? configMaxTokens ?? Self.defaultMaxTokens
        let temperature = Float(request.temperature ?? configTemperature ?? Self.defaultTemperature)
        let topP = Float(request.topP ?? configTopP ?? Self.defaultTopP)

        return ChatSession(
            container,
            instructions: request.system,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP
            ),
            // ← the hard Qwen3.x carry-forward (plan §1.3): omitting this leaks `<think>` blocks
            // into the summary output.
            additionalContext: ["enable_thinking": false]
        )
    }
}
