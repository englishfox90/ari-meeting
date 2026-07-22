//
//  AppleContextualEmbedderTests.swift — plan §5/§6 Slice 3 (upgraded from `NLEmbedding` to
//  `NLContextualEmbedding`).
//
//  One real vector per input in order, honest failure never zeros, stable modelTag. These tests
//  invoke the on-device `NLContextualEmbedding` model directly. Unlike the old static `NLEmbedding`
//  sentence model, `NLContextualEmbedding` needs asset availability + an explicit `load()`, and a
//  clean CI/headless host may not have the model assets downloaded — so every test that needs the
//  live model guards on `hasAvailableAssets` first and skips cleanly (rather than hard-failing)
//  when the on-device model isn't present, mirroring the tolerance the old `NLEmbedding` test had
//  for a missing model.
//
import Foundation
import NaturalLanguage
import Testing
@testable import AriKit

struct AppleContextualEmbedderTests {
    /// Whether the on-device English contextual-embedding model's assets are actually present on
    /// this host. Synchronous and side-effect-free (never triggers a download) — purely a guard so
    /// tests degrade honestly rather than hard-failing CI on a host with no downloaded assets.
    private static var modelAssetsAvailable: Bool {
        guard let model = NLContextualEmbedding(language: .english) else {
            return false
        }
        return model.hasAvailableAssets
    }

    /// The tag must match `EmbedBackend.apple` so the indexer/search agree on the vector space.
    @Test func modelTagIsAppleContextual() {
        #expect(AppleContextualEmbedder().modelTag == "apple-contextual")
        #expect(AppleContextualEmbedder().modelTag == EmbedBackend.apple.modelTag)
    }

    /// Empty input is a no-op — no model load required, returns no vectors.
    @Test func emptyBatchReturnsEmpty() async throws {
        let vectors = try await AppleContextualEmbedder().embed([])
        #expect(vectors.isEmpty)
    }

    /// One real vector per input, in order, each matching the model's dimension. Skips cleanly if
    /// this host has no downloaded model assets (no network calls are made in this test).
    @Test func embedsOneVectorPerInputAtModelDimension() async throws {
        guard Self.modelAssetsAvailable, let dimension = NLContextualEmbedding(language: .english)?.dimension else {
            return
        }
        let texts = [
            "We agreed to ship the recall index next week.",
            "Nia will follow up on the calendar integration.",
            "Action item: draft the migration plan."
        ]
        let vectors = try await AppleContextualEmbedder().embed(texts)

        #expect(vectors.count == texts.count)
        for vector in vectors {
            #expect(vector.count == dimension)
        }
    }

    /// Deterministic: the same text embeds to the same vector across calls (real model, no noise).
    @Test func embeddingIsDeterministic() async throws {
        guard Self.modelAssetsAvailable else {
            return
        }
        let embedder = AppleContextualEmbedder()
        let text = "The quarterly review covered hiring and roadmap."
        let first = try await embedder.embed([text])
        let second = try await embedder.embed([text])
        #expect(first == second)
    }

    /// The `embedQuery` convenience returns a single non-empty vector.
    @Test func embedQueryReturnsSingleVector() async throws {
        guard Self.modelAssetsAvailable else {
            return
        }
        let vector = try await AppleContextualEmbedder().embedQuery("What did we decide about diarization?")
        #expect(!vector.isEmpty)
    }

    /// Compile-time: the embedder and its error type are `Sendable` (crosses task boundaries).
    @Test func embedderIsSendable() {
        func requireSendable(_: (some Sendable).Type) {}
        requireSendable(AppleContextualEmbedder.self)
        requireSendable(RecallEmbedderError.self)
    }
}

/// The `embedQuery` default-implementation contract, exercised via a fake conformer — the real
/// on-device model can't be forced to return an empty batch, so the throw path is proved here.
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
