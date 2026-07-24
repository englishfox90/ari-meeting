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
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os

/// Bounds MLX's GPU (Metal) buffer cache, run exactly once process-wide before the first
/// generation. MLX's cache limit *defaults to its memory limit* — 1.5× the device's recommended
/// max working-set size (`mlx-swift/Source/MLX/GPU+Metal.swift`) — so on a Mac with abundant RAM
/// the reuse cache is allowed to grow to many GB and never returns memory to the OS. Left
/// unbounded it drove a real 17 GB `IOAccelerator` footprint and a system application-memory OOM
/// (2026-07-23). A firm ceiling keeps freed buffers reusable for decode-loop throughput while
/// capping runaway growth; `MLXClient` additionally `clearCache()`s on the idle transition so the
/// pool is handed back between summaries. A top-level `let` is a lazily-initialized, thread-safe
/// once — reference it (`_ = mlxRuntimeConfigured`) at every generation entry point.
/// Not `private`: `MLXClient+Tools.swift` (the tool-capable `respondWithTools` conformance,
/// docs/plans/ask-meetings-agentic-tools.md §3.5) installs the same one-time GPU cache-limit
/// bracket at its own generation entry point, mirroring `generate`/`stream` below.
let mlxRuntimeConfigured: Bool = {
    // 512 MB: comfortably above a single decode's transient buffer churn (so reuse still helps),
    // far below the multi-GB default ceiling. MLX docs note even ~2 MB is often perf-neutral; 512
    // MB is a conservative pick that keeps growth bounded without risking decode regressions.
    MLX.Memory.cacheLimit = 512 * 1024 * 1024
    return true
}()

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
    private static let log = Logger(subsystem: "com.arivo.ari.AriKitEngineMLX", category: "mlx.client")

    public let kind: ProviderKind = .mlx

    /// Fallback generation budget when neither the request nor the resolved config supplies one
    /// (MLX always lands here — `ProviderConfigResolution` only populates `maxTokens` for
    /// CustomOpenAI). This is an OUTPUT cap we choose, NOT a model limit: Qwen3.5-4B's context is
    /// 262k tokens, so a few-thousand-token summary sits far inside what the model can produce.
    ///
    /// Raised from 800 → 4096 (2026-07-22): 800 truncated multi-section summary templates
    /// mid-content — a real one_on_one summary ended `| **Owner** | **Task** | **Due Date` with the
    /// Action Items table cut off, and later-section `@ref(MM:SS)` citations never got generated.
    /// 4096 fits a full summary of even a long (37k-char) meeting with citations intact. It is a
    /// CEILING, not a target: the model emits its natural EOS well before this on short meetings, so
    /// they don't pay for tokens they don't use — only genuinely long summaries run longer.
    static let defaultMaxTokens = 4096

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
        _ = mlxRuntimeConfigured // one-time GPU cache-limit install (see the top-level `let`)

        // Registered for the whole GPU-touching span (container resolve → session.respond) — a
        // crash (2026-07-22) came from the app quitting while this work was still in flight on a
        // background task; the app's termination handler awaits `MLXActivityTracker.shared.
        // waitUntilIdle()` before letting `exit()` run, so it never races a live generation the
        // way the crash did. `begin()`/`end()` bracket the `do`/`catch` directly (not a `defer`,
        // which cannot `await`) so every exit path — success or throw — decrements exactly once
        // before this call returns. See MLXActivityTracker.swift for the full root-cause writeup.
        await MLXActivityTracker.shared.begin()
        do {
            let result = try await generateBody(request)
            await Self.endActivityReclaimingCacheIfIdle()
            return result
        } catch {
            await Self.endActivityReclaimingCacheIfIdle()
            throw error
        }
    }

    /// Decrements the activity ledger and, *only* when that drains it to idle, hands MLX's GPU
    /// buffer cache back to the OS. `clearCache()` frees just unused cached buffers — never active
    /// allocations — so even if an overlapping generation begins right after, MLX serializes
    /// `clearCache()` and `eval` on the same internal `evalLock`, so the worst case is that
    /// generation loses buffer reuse for one step, never correctness. Paired with the 512 MB
    /// `cacheLimit` (see `mlxRuntimeConfigured`), this keeps the between-summaries footprint low
    /// instead of pinning multiple GB of cache resident for the process lifetime.
    ///
    /// The reclaim is handed to `end(reclaimingWhenIdle:)` so it runs *inside* the tracker's
    /// actor-isolated critical section, before the drained-to-idle waiters resume — see that
    /// method for why that ordering is load-bearing against the process-teardown race.
    /// Not `private`: shared with `MLXClient+Tools.swift`'s `respondWithTools` bracket.
    static func endActivityReclaimingCacheIfIdle() async {
        await MLXActivityTracker.shared.end(reclaimingWhenIdle: { MLX.Memory.clearCache() })
    }

    private func generateBody(_ request: LLMRequest) async throws -> String {
        let clock = ContinuousClock()
        let containerStart = clock.now
        let container = try await resolveContainer()
        // `container(forRepoId:)` is warm-cached process-wide (ModelHost.shared) — a large elapsed
        // here means a cold first load/download; a near-zero one confirms the warm path (the reason
        // the 2nd+ summary is fast and the model stays resident in RAM, never unloaded per-summary).
        let loadElapsed = clock.now - containerStart
        let session = makeSession(container: container, request: request)
        let maxTokens = request.maxTokens ?? configMaxTokens ?? Self.defaultMaxTokens
        let repo = repoId // local copy — os.Logger interpolation is an autoclosure (no implicit self capture)
        Self.log.info(
            "MLX generate start: repo=\(repo, privacy: .public) maxTokens=\(maxTokens, privacy: .public) promptChars=\(request.user.count, privacy: .public) containerLoad=\(loadElapsed.formatted(), privacy: .public)"
        )

        let genStart = clock.now
        let raw: String
        do {
            raw = try await session.respond(to: request.user)
        } catch {
            throw LLMError.requestFailed("MLX generation failed: \(error)")
        }
        let genElapsed = clock.now - genStart
        Self.log.info(
            "MLX generate done: repo=\(repo, privacy: .public) decode=\(genElapsed.formatted(), privacy: .public) outputChars=\(raw.count, privacy: .public)"
        )

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
        _ = mlxRuntimeConfigured // one-time GPU cache-limit install (see the top-level `let`)
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Same `MLXActivityTracker` bracket as `generate` (see there for the full
                // root-cause writeup) — bracket the whole GPU-touching span, decrement on every
                // exit path (normal finish, cancellation, or error) before this `Task` completes.
                // `endActivityReclaimingCacheIfIdle()` also reclaims the GPU cache on the idle
                // transition (see its doc comment).
                await MLXActivityTracker.shared.begin()
                do {
                    try Task.checkCancellation()
                    let container = try await self.resolveContainer()
                    let session = self.makeSession(container: container, request: request)
                    for try await chunk in session.streamResponse(to: request.user) {
                        if Task.isCancelled {
                            await Self.endActivityReclaimingCacheIfIdle()
                            continuation.finish(throwing: LLMError.cancelled)
                            return
                        }
                        continuation.yield(chunk)
                    }
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish()
                } catch let error as LLMError {
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish(throwing: error)
                } catch {
                    await Self.endActivityReclaimingCacheIfIdle()
                    continuation.finish(throwing: LLMError.requestFailed("MLX streaming failed: \(error)"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    /// Not `private`: shared with `MLXClient+Tools.swift`'s `respondWithTools`.
    func resolveContainer() async throws -> ModelContainer {
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
