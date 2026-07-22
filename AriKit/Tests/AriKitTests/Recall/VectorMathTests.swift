//
//  VectorMathTests.swift — plan §6 Slice 1 test 8.
//
//  1:1 port of every Rust `embedding.rs` test (embedding.rs:169-198).
//
import Testing
@testable import AriKit

struct VectorMathTests {
    @Test func backendParsesFromSettingWithAppleDefault() {
        #expect(EmbedBackend.from(setting: nil) == .apple)
        #expect(EmbedBackend.from(setting: "apple") == .apple)
        // Legacy stored values (from before the single-embedder collapse) still resolve to the
        // one remaining case.
        #expect(EmbedBackend.from(setting: "nomic-gguf") == .apple)
        #expect(EmbedBackend.from(setting: "ollama") == .apple)
        #expect(EmbedBackend.from(setting: "weird") == .apple)
    }

    @Test func packRoundtripPreservesValues() {
        let original: [Float] = [0.0, 1.5, -2.25, 3.125]
        let restored = Recall.unpackF32(Recall.packF32(original))
        #expect(original == restored)
    }

    @Test func cosineIdenticalIsOneOrthogonalIsZero() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let c: [Float] = [0.0, 1.0, 0.0]
        #expect(abs(Recall.cosine(a, b) - 1.0) < 1e-6)
        #expect(abs(Recall.cosine(a, c)) < 1e-6)
    }

    @Test func cosineHandlesMismatchAndEmpty() {
        #expect(Recall.cosine([1.0, 2.0], [1.0]) == 0.0)
        #expect(Recall.cosine([], []) == 0.0)
    }

    @Test func backendIdAndModelTagAreStable() {
        #expect(EmbedBackend.apple.id == "apple")
        #expect(EmbedBackend.apple.modelTag == "apple-contextual")
    }
}
