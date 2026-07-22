//
//  SpeakerMath.swift — shared centroid math (← Rust `ari-engine/src/diarization/matching.rs`
//  `cosine_similarity` + `ari-engine/src/diarization/engine.rs` `weighted_mean`/`l2_normalize`).
//
//  Pure, no IO, no actor. Shared by `DiarizationPostProcess`, `SpeakerMatcher`, and the
//  FluidAudio centroid builder (D7).
//
public enum SpeakerMath {
    /// Cosine similarity of two vectors. Returns `0.0` on length mismatch, empty input, or a
    /// zero-norm vector — never NaN, never a crash.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }

        var dot: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        guard normA > 0.0, normB > 0.0 else { return 0.0 }

        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Duration-weighted element-wise mean of two equal-length vectors. If both weights are
    /// non-positive it degrades to a plain (equal-weight) mean; a length mismatch or empty `a`
    /// returns `a` unchanged (defensive — should not happen in practice).
    public static func weightedMean(_ a: [Float], _ wa: Double, _ b: [Float], _ wb: Double) -> [Float] {
        guard a.count == b.count, !a.isEmpty else { return a }

        let (weightA, weightB): (Double, Double)
        if wa <= 0.0, wb <= 0.0 {
            (weightA, weightB) = (1.0, 1.0)
        } else {
            (weightA, weightB) = (max(wa, 0.0), max(wb, 0.0))
        }

        let denom = Float(weightA + weightB)
        return zip(a, b).map { x, y in
            (x * Float(weightA) + y * Float(weightB)) / denom
        }
    }

    /// L2-normalize a vector. A zero-norm input is returned unchanged (still zero) so downstream
    /// cosine reads it as no-match — never NaN.
    public static func l2Normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0.0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > Float.ulpOfOne else { return v }
        return v.map { $0 / norm }
    }
}
