//
//  AppleNLEmbedder.swift — the DEFAULT recall embedder, in-process (plan §5 SLICE 3,
//  ← embed_apple.rs).
//
//  Apple's NaturalLanguage `NLEmbedding` sentence-embedding model. Zero download, offline,
//  no entitlement, no TCC-guarded resource. In the Rust build this ran through the apple-helper
//  SIDECAR (embed_apple.rs → apple::helper::embed_batch); in Swift it runs in-process — a genuine
//  simplification (the sidecar hop vanishes). The batch logic mirrors apple-helper's `Embed.run`
//  verbatim so behavior is identical: load the model ONCE, embed each item, throw honestly on any
//  nil vector (No-Fake-State — never emit zeros).
//
//  Symbols (NaturalLanguage.framework):
//    - `NLEmbedding.sentenceEmbedding(for:) -> NLEmbedding?` — the model for a language (nil if
//      unavailable).
//    - `NLEmbedding.vector(for:) -> [Double]?` — one string's embedding, or nil.
//    - `NLEmbedding.dimension: Int` — the vector length (English sentence model is 512-d).
//
import Foundation
import NaturalLanguage

/// On-device Apple `NLEmbedding` embedder — the default recall backend (`EmbedBackend.apple`).
///
/// Value type with no stored state (the `NLEmbedding` model is created per call, never stored),
/// so it is trivially `Sendable`. Because this is a plain non-isolated type (no `@MainActor`, no
/// actor) and the protocol requirement carries no isolation, `embed` runs on the cooperative
/// thread pool rather than being pinned to the caller's actor — so the CPU/ANE work stays off the
/// main actor even when awaited from a `@MainActor` context (plan §3). (The guarantee comes from
/// the type's non-isolation, not from `async` alone.)
public struct AppleNLEmbedder: RecallEmbedder {
    public init() {}

    /// Matches `EmbedBackend.apple.modelTag` ("apple-nl") so index/search agree on the vector space.
    public var modelTag: String {
        EmbedBackend.apple.modelTag
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        if texts.isEmpty {
            return []
        }

        // Load the on-device sentence-embedding model ONCE before the loop.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw RecallEmbedderError.modelUnavailable(
                "NLEmbedding sentence embedding is not available on this device"
            )
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for (index, text) in texts.enumerated() {
            // No-Fake-State: a nil vector fails the WHOLE batch; never emit zeros.
            guard let doubles = embedding.vector(for: text) else {
                throw RecallEmbedderError.embeddingFailed(index: index)
            }
            vectors.append(doubles.map { Float($0) })
        }
        return vectors
    }
}
