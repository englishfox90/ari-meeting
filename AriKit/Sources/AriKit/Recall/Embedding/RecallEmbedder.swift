//
//  RecallEmbedder.swift — the pluggable embedder seam (plan §2.3, ← embedding.rs:117).
//
//  Recall's semantic arm needs one vector per chunk (index build) and one per query (search).
//  In Rust this is the free-function dispatch `embed_documents`/`embed_query` over `EmbedBackend`
//  (embedding.rs). In Swift the seam is a `Sendable` protocol so the indexer/search hold `any
//  RecallEmbedder` and the concrete backend (Apple in-process, later Ollama/MLX) is injected.
//
//  BEST-EFFORT / No-Fake-State (principle 6, ← embedding.rs:119, indexer.rs:83): `embed` THROWS
//  when the semantic arm is unavailable — it never returns zero/placeholder vectors. The caller
//  degrades to lexical-only search on a thrown error. `modelTag` identifies the (incomparable)
//  vector space so a backend change is detected and the affected meetings are re-embedded.
//
import Foundation

/// A pluggable on-device embedder for recall's semantic arm. Conformers do CPU/ANE work off the
/// main actor (the protocol requirement is `async`); they never block a capture/STT hot path.
public protocol RecallEmbedder: Sendable {
    /// Embed a batch of documents. Returns one vector per input, in the SAME order.
    /// - Throws: when the model is unavailable or any single input fails to embed — the whole
    ///   batch fails (never a partial or fabricated result). The caller falls back to lexical-only.
    func embed(_ texts: [String]) async throws -> [[Float]]

    /// Stable tag for this backend's vector space, stored on each chunk (← `EmbedBackend.model_tag`).
    /// Distinct backends produce incomparable vectors; a tag mismatch forces a clean re-embed.
    var modelTag: String { get }
}

public extension RecallEmbedder {
    /// Embed a single query string (← `embed_query`, embedding.rs:135). Convenience over `embed`.
    /// - Throws: `RecallEmbedderError.emptyResult` if the backend returns no vector.
    func embedQuery(_ text: String) async throws -> [Float] {
        let batch = try await embed([text])
        guard let first = batch.first else {
            throw RecallEmbedderError.emptyResult
        }
        return first
    }
}

/// A descriptive, honest failure from the embed path (mirrors apple-helper's `EmbedError`).
public enum RecallEmbedderError: Error, Sendable, Equatable {
    /// The on-device model is not available on this device.
    case modelUnavailable(String)
    /// A single input failed to embed (`vector(for:)` returned nil) — the whole batch fails.
    case embeddingFailed(index: Int)
    /// The backend returned an empty result for a non-empty input.
    case emptyResult
}
