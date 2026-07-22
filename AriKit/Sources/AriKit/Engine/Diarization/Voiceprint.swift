//
//  Voiceprint.swift — voiceprint identicon signature helper
//  (← Rust `ari-engine/src/diarization/voiceprint.rs:86-115`, `SIGNATURE_BUCKETS`).
//
//  Pure f32 math (decode + down-sample + normalize) — no DB, no I/O, trivially
//  unit-testable. Honours the app's No-Fake-State rule: the signature is a
//  direct, order-preserving down-sampling of a real voiceprint centroid, never
//  a hash — two cosine-similar voices therefore produce visually similar rings.
//
import Foundation

public enum Voiceprint {
    /// How many radial buckets a centroid is reduced to (`SIGNATURE_BUCKETS` in the Rust port).
    public static let signatureBuckets = 32

    /// Reduce an embedding to `buckets` values (mean of each contiguous slice) and normalize the
    /// result to `[0, 1]` via per-vector min/max.
    ///
    /// Returns `nil` for an empty embedding, `buckets == 0`, one with no variation (all buckets
    /// equal), or any non-finite input (NaN/inf) — both would only ever yield a flat, meaningless
    /// ring, so we decline to invent one.
    ///
    /// The mapping is intentionally direct (no hashing): preserving relative magnitudes keeps
    /// cosine-similar voices visually similar.
    public static func downsampleNormalize(_ embedding: [Float], buckets: Int = signatureBuckets) -> [Float]? {
        guard !embedding.isEmpty, buckets > 0 else { return nil }
        let n = embedding.count
        var means = [Float]()
        means.reserveCapacity(buckets)
        for i in 0 ..< buckets {
            let start = (i * n) / buckets
            var end = ((i + 1) * n) / buckets
            if end <= start {
                end = min(start + 1, n) // guarantee a non-empty slice when n < buckets
            }
            let slice = embedding[start ..< end]
            let sum = slice.reduce(0, +)
            means.append(sum / Float(slice.count))
        }

        let min = means.min() ?? Float.infinity
        let max = means.max() ?? -Float.infinity
        let range = max - min
        guard range.isFinite, range > Float.ulpOfOne else {
            return nil // degenerate / no variation → honest "no glyph"
        }
        return means.map { (($0 - min) / range).clamped(to: 0.0 ... 1.0) }
    }

    /// Decode a centroid BLOB (little-endian f32, as stored in `speakers.centroid`) via
    /// `CentroidCodec` and reduce it to a render-ready signature.
    public static func signature(fromCentroid centroid: Data, buckets: Int = signatureBuckets) -> [Float]? {
        let embedding = CentroidCodec.vector(from: centroid)
        guard !embedding.isEmpty else { return nil }
        return downsampleNormalize(embedding, buckets: buckets)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
