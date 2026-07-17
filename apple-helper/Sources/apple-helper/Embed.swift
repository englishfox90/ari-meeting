//
//  Embed.swift
//  apple-helper
//
//  On-device text embeddings for the `embedBatch` request, factored out of
//  main.swift so it is unit-testable and so the framework calls are isolated.
//
//  Backed by Apple's NaturalLanguage `NLEmbedding` sentence-embedding model.
//  Every vector reflects a REAL model embedding — this function NEVER fabricates
//  a vector (No-Fake-State). If the model is unavailable, or if ANY single input
//  fails to embed (`vector(for:)` returns nil — e.g. empty/unsupported text), it
//  THROWS a descriptive `EmbedError` for the WHOLE batch; main.swift catches and
//  emits an `AppleResponse.error(message:)` instead of a zero/placeholder vector.
//
//  Symbols (NaturalLanguage.framework):
//    - `NLEmbedding.sentenceEmbedding(for: NLLanguage) -> NLEmbedding?` — the
//      on-device sentence-embedding model for a language (nil if unavailable).
//    - `NLEmbedding.dimension: Int` — the vector length (English sentence model
//      is 512-d).
//    - `NLEmbedding.vector(for: String) -> [Double]?` — the embedding of one
//      string, or nil when the model cannot embed it.
//
//  ENTITLEMENTS: NLEmbedding is a pure in-process, on-device NLP model. It needs
//  NO entitlement, no network, and no TCC-guarded resource. No entitlements file
//  was added.
//

import Foundation
import NaturalLanguage

/// A descriptive, honest failure from the embed path. Its `message` is what the
/// sidecar surfaces to the Rust core as `AppleResponse.error(message:)`.
struct EmbedError: Error, Equatable {
    let message: String
}

enum Embed {

    /// Embed each string in `texts` and return one vector per input, in the SAME
    /// order. Loads the `NLEmbedding` model ONCE, then embeds every item.
    ///
    /// - Returns: `[[Float]]` — one 512-d vector per input text, in order.
    /// - Throws: `EmbedError` with a truthful reason when the sentence-embedding
    ///   model is unavailable, or when ANY single input fails to embed (nil
    ///   vector). The whole batch fails — never a partial or fabricated result.
    static func run(texts: [String]) throws -> [[Float]] {
        // Load the on-device sentence-embedding model ONCE before the loop.
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbedError(
                message: "NLEmbedding sentence embedding is not available on this device"
            )
        }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for (index, text) in texts.enumerated() {
            // No-Fake-State: a nil vector fails the WHOLE batch; never emit zeros.
            guard let doubles = embedding.vector(for: text) else {
                throw EmbedError(
                    message: "failed to embed text at index \(index) — NLEmbedding returned no vector"
                )
            }
            vectors.append(doubles.map { Float($0) })
        }
        return vectors
    }
}
