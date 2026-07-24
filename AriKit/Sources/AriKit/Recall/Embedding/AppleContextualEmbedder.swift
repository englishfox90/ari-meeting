//
//  AppleContextualEmbedder.swift — the sole recall embedder (plan §5 SLICE 3, ← embed_apple.rs),
//  upgraded from the retired `AppleNLEmbedder`/`NLEmbedding` static sentence model to Apple's
//  `NLContextualEmbedding`.
//
//  Unlike `NLEmbedding` (a stateless, always-resident model), `NLContextualEmbedding` requires
//  explicit asset management (a possible first-run over-the-air download) and an explicit
//  `load()` before use, and its model object is not `Sendable`. This embedder is therefore an
//  ACTOR: the model is created, asset-checked, and loaded lazily exactly once and cached for the
//  actor's lifetime; every call is serialized through actor isolation. This is the Swift-6-clean
//  way to hold non-Sendable model state — no `@unchecked Sendable`/`nonisolated(unsafe)` anywhere.
//
//  `NLContextualEmbeddingResult` returns one embedding vector PER SUBWORD TOKEN, not one per input
//  string, so this embedder mean-pools every token vector into a single sentence-level vector of
//  length `model.dimension` — the shape `RecallEmbedder.embed` promises (one vector per input,
//  same order). A non-empty input that yields zero token vectors is an honest failure
//  (No-Fake-State — never a zero/placeholder vector), mirroring the old nil-vector-fails-the-batch
//  contract.
//
//  Symbols (NaturalLanguage.framework):
//    - `NLContextualEmbedding(language:) -> NLContextualEmbedding?` — the model for a language.
//    - `NLContextualEmbedding.hasAvailableAssets: Bool` /
//      `requestAssets() async throws -> NLContextualEmbedding.AssetsResult` — first-run
//      over-the-air asset check/download.
//    - `NLContextualEmbedding.load() throws` — must be called before `embeddingResult(for:language:)`.
//    - `NLContextualEmbedding.embeddingResult(for:language:) throws -> NLContextualEmbeddingResult`
//      — one vector per SUBWORD TOKEN.
//    - `NLContextualEmbeddingResult.enumerateTokenVectors(in:using:)` — the per-token vectors,
//      mean-pooled here into one sentence vector.
//    - `NLContextualEmbedding.dimension: Int` — the model's vector length.
//
import Foundation
import NaturalLanguage

/// On-device Apple `NLContextualEmbedding` embedder — the sole recall backend (`EmbedBackend.apple`).
///
/// An actor because the underlying model requires one-time async asset loading + a stateful
/// `load()` and is not `Sendable`; the actor serializes all access and lazily caches the loaded
/// model so repeated `embed` calls don't repeat the load.
public actor AppleContextualEmbedder: RecallEmbedder {
    public init() {}

    /// Matches `EmbedBackend.apple.modelTag` ("apple-contextual") so index/search agree on the
    /// vector space. `nonisolated` per the `RecallEmbedder` protocol — it names the backend, not
    /// the loaded model instance, so no actor-isolated state is touched.
    public nonisolated var modelTag: String {
        EmbedBackend.apple.modelTag
    }

    private var loadedModel: NLContextualEmbedding?

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        if texts.isEmpty {
            return []
        }

        let model = try await loadedModelInstance()

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for (index, text) in texts.enumerated() {
            // No-Fake-State: a token-less result fails the WHOLE batch; never emit zeros.
            guard let vector = try Self.sentenceVector(for: text, model: model) else {
                throw RecallEmbedderError.embeddingFailed(index: index)
            }
            vectors.append(vector)
        }
        return vectors
    }

    /// Lazily creates, asset-checks, and loads the on-device model exactly once, caching it for
    /// the actor's lifetime. Never fabricates availability — a missing model/assets throws
    /// honestly (`RecallEmbedderError.modelUnavailable`) so the caller degrades to lexical-only.
    ///
    /// Package-visible (not `private`) so `OnboardingInstallableComponent.ensureReady`
    /// (docs/plans/onboarding-install-flow.md §2.4, same file below) can call this same lazy-load
    /// path directly, rather than forcing it via a throwaway-string `embed(_:)` call — the plan's
    /// explicit "avoid the throwaway-string hack" call.
    func loadedModelInstance() async throws -> NLContextualEmbedding {
        if let loadedModel {
            return loadedModel
        }

        guard let model = NLContextualEmbedding(language: .english) else {
            throw RecallEmbedderError.modelUnavailable(
                "NLContextualEmbedding is not available on this device for English"
            )
        }

        if !model.hasAvailableAssets {
            let result = try await model.requestAssets()
            guard result == .available else {
                throw RecallEmbedderError.modelUnavailable(
                    "NLContextualEmbedding assets are not available on this device (\(result))"
                )
            }
        }

        try model.load()
        loadedModel = model
        return model
    }

    /// Mean-pool every subword-token vector `NLContextualEmbeddingResult` returns for `text` into
    /// one sentence-level vector of length `model.dimension`. Returns `nil` only when the model
    /// produced zero token vectors for a non-empty string — the caller turns that into an honest
    /// per-index failure, never a zero vector.
    private static func sentenceVector(for text: String, model: NLContextualEmbedding) throws -> [Float]? {
        guard !text.isEmpty else {
            return nil
        }
        let result = try model.embeddingResult(for: text, language: .english)

        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex ..< text.endIndex) { tokenVector, _ in
            for (i, value) in tokenVector.enumerated() where i < sum.count {
                sum[i] += value
            }
            count += 1
            return true
        }

        guard count > 0 else {
            return nil
        }
        return sum.map { Float($0 / Double(count)) }
    }
}
