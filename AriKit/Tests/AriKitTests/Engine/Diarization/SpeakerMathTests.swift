//
//  SpeakerMathTests.swift — ← Rust `ari-engine/src/diarization/matching.rs` cosine tests
//  (`matching.rs:576-616`) + `ari-engine/src/diarization/engine.rs` weighted-mean/l2-normalize
//  tests (`postprocess.rs` module, `weighted_mean`/`l2_normalize` tests).
//
import Testing
@testable import AriKit

@Suite("SpeakerMath")
struct SpeakerMathTests {
    private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-5) -> Bool {
        abs(a - b) < tol
    }

    // ---- cosineSimilarity ----------------------------------------------

    @Test
    func cosineIdenticalIsOne() {
        let v: [Float] = [1.0, 2.0, 3.0, 4.0]
        #expect(approx(SpeakerMath.cosineSimilarity(v, v), 1.0))
    }

    @Test
    func cosineOrthogonalIsZero() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        #expect(approx(SpeakerMath.cosineSimilarity(a, b), 0.0))
    }

    @Test
    func cosineOppositeIsMinusOne() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        #expect(approx(SpeakerMath.cosineSimilarity(a, b), -1.0))
    }

    @Test
    func cosineLengthMismatchGuard() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [1.0, 2.0]
        #expect(SpeakerMath.cosineSimilarity(a, b) == 0.0)
    }

    @Test
    func cosineZeroNormGuard() {
        let a: [Float] = [0.0, 0.0, 0.0]
        let b: [Float] = [1.0, 2.0, 3.0]
        #expect(SpeakerMath.cosineSimilarity(a, b) == 0.0)
        #expect(SpeakerMath.cosineSimilarity(b, a) == 0.0)
    }

    @Test
    func cosineEmptyGuard() {
        let a: [Float] = []
        let b: [Float] = []
        #expect(SpeakerMath.cosineSimilarity(a, b) == 0.0)
    }

    // ---- weightedMean / l2Normalized -------------------------------------

    @Test
    func weightedMeanDurationWeighted() {
        // a=[1,0] weight 3, b=[0,1] weight 1 -> ([3,0]+[0,1])/4 = [0.75,0.25].
        let m = SpeakerMath.weightedMean([1.0, 0.0], 3.0, [0.0, 1.0], 1.0)
        #expect(approx(m[0], 0.75))
        #expect(approx(m[1], 0.25))
    }

    @Test
    func weightedMeanThenNormalizeIsUnit() {
        let m = SpeakerMath.weightedMean([1.0, 0.0], 3.0, [0.0, 1.0], 1.0)
        let n = SpeakerMath.l2Normalized(m)
        let norm = (n[0] * n[0] + n[1] * n[1]).squareRoot()
        #expect(approx(norm, 1.0))
        // Direction: [0.75,0.25] normalized = [0.9487, 0.3162].
        #expect(approx(n[0], 0.94868))
        #expect(approx(n[1], 0.31623))
    }

    @Test
    func weightedMeanZeroDurationsEqualWeight() {
        let m = SpeakerMath.weightedMean([2.0, 0.0], 0.0, [0.0, 2.0], 0.0)
        #expect(approx(m[0], 1.0))
        #expect(approx(m[1], 1.0))
    }

    @Test
    func l2NormalizeZeroStaysZero() {
        #expect(SpeakerMath.l2Normalized([0.0, 0.0]) == [0.0, 0.0])
    }
}
