//
//  AppleNLEmbedderTests.swift — plan §5/§6 Slice 3.
//
//  Behavioral parity with apple-helper's `Embed.run` (the sidecar the in-process embedder
//  replaces): one real vector per input in order, honest failure never zeros, stable modelTag.
//  These tests invoke the on-device NLEmbedding model directly.
//
import Foundation
import NaturalLanguage
import Testing
@testable import AriKit

struct AppleNLEmbedderTests {
    /// The tag must match `EmbedBackend.apple` so the indexer/search agree on the vector space.
    @Test func modelTagIsAppleNL() {
        #expect(AppleNLEmbedder().modelTag == "apple-nl")
        #expect(AppleNLEmbedder().modelTag == EmbedBackend.apple.modelTag)
    }

    /// Empty input is a no-op — no model load required, returns no vectors.
    @Test func emptyBatchReturnsEmpty() async throws {
        let vectors = try await AppleNLEmbedder().embed([])
        #expect(vectors.isEmpty)
    }

    /// One real vector per input, in order, each matching the model's dimension.
    @Test func embedsOneVectorPerInputAtModelDimension() async throws {
        let dimension = try #require(
            NLEmbedding.sentenceEmbedding(for: .english)?.dimension,
            "English sentence-embedding model must be available on the test host"
        )
        let texts = [
            "We agreed to ship the recall index next week.",
            "Nia will follow up on the calendar integration.",
            "Action item: draft the migration plan."
        ]
        let vectors = try await AppleNLEmbedder().embed(texts)

        #expect(vectors.count == texts.count)
        for vector in vectors {
            #expect(vector.count == dimension)
        }
    }

    /// Deterministic: the same text embeds to the same vector across calls (real model, no noise).
    @Test func embeddingIsDeterministic() async throws {
        let embedder = AppleNLEmbedder()
        let text = "The quarterly review covered hiring and roadmap."
        let first = try await embedder.embed([text])
        let second = try await embedder.embed([text])
        #expect(first == second)
    }

    /// The `embedQuery` convenience returns a single non-empty vector.
    @Test func embedQueryReturnsSingleVector() async throws {
        let vector = try await AppleNLEmbedder().embedQuery("What did we decide about diarization?")
        #expect(!vector.isEmpty)
    }

    /// Compile-time: the embedder and its error type are `Sendable` (crosses task boundaries).
    @Test func embedderIsSendable() {
        func requireSendable(_: (some Sendable).Type) {}
        requireSendable(AppleNLEmbedder.self)
        requireSendable(RecallEmbedderError.self)
    }
}

/// The `embedQuery` default-implementation contract, exercised via a fake conformer — the real
/// `NLEmbedding` model can't be forced to return an empty batch, so the throw path is proved here.
struct RecallEmbedderExtensionTests {
    private struct EmptyEmbedder: RecallEmbedder {
        var modelTag: String {
            "fake"
        }

        func embed(_: [String]) async throws -> [[Float]] {
            []
        }
    }

    private struct EchoEmbedder: RecallEmbedder {
        var modelTag: String {
            "fake"
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { [Float($0.count)] }
        }
    }

    /// `embedQuery` throws `emptyResult` when the backend yields no vector for a non-empty input.
    @Test func embedQueryThrowsOnEmptyResult() async {
        await #expect(throws: RecallEmbedderError.emptyResult) {
            _ = try await EmptyEmbedder().embedQuery("anything")
        }
    }

    /// `embedQuery` returns the single vector the backend produced for the query.
    @Test func embedQueryReturnsFirstVector() async throws {
        let vector = try await EchoEmbedder().embedQuery("abcd")
        #expect(vector == [4.0])
    }
}
