//
//  VoiceprintTests.swift — ← Rust `ari-engine/src/diarization/voiceprint.rs:86-291` port tests
//  (downsample_produces_requested_bucket_count, downsample_normalizes_to_unit_range,
//  downsample_means_are_correct, deterministic_same_input_same_output,
//  empty_and_flat_vectors_yield_none, non_finite_input_yields_none,
//  handles_fewer_values_than_buckets) plus signature() composition over CentroidCodec.
//
import Foundation
import Testing
@testable import AriKit

@Suite("Voiceprint")
struct VoiceprintTests {
    @Test
    func downsampleProducesRequestedBucketCount() {
        let embedding: [Float] = (0 ..< 192).map { Float($0) }
        let sig = Voiceprint.downsampleNormalize(embedding, buckets: 32)
        #expect(sig?.count == 32)
    }

    @Test
    func downsampleNormalizesToUnitRange() throws {
        let embedding: [Float] = (0 ..< 192).map { Float($0) }
        let sig = Voiceprint.downsampleNormalize(embedding, buckets: 32)
        let values = try #require(sig)
        #expect(abs(values[0] - 0.0) < 1e-6)
        #expect(abs(values[values.count - 1] - 1.0) < 1e-6)
        #expect(values.allSatisfy { $0 >= 0.0 && $0 <= 1.0 })
    }

    @Test
    func downsampleMeansAreCorrect() throws {
        // 8 values, 4 buckets → each bucket is the mean of a pair.
        // means: 1, 5, 9, 13 → min 1, max 13, range 12 → 0, 1/3, 2/3, 1
        let embedding: [Float] = [0.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0]
        let sig = Voiceprint.downsampleNormalize(embedding, buckets: 4)
        let values = try #require(sig)
        #expect(values.count == 4)
        #expect(abs(values[0] - 0.0) < 1e-6)
        #expect(abs(values[1] - 1.0 / 3.0) < 1e-6)
        #expect(abs(values[2] - 2.0 / 3.0) < 1e-6)
        #expect(abs(values[3] - 1.0) < 1e-6)
    }

    @Test
    func deterministicSameInputSameOutput() {
        let embedding: [Float] = (0 ..< 192).map { sinf(Float($0) * 0.37) }
        let a = Voiceprint.downsampleNormalize(embedding, buckets: 32)
        let b = Voiceprint.downsampleNormalize(embedding, buckets: 32)
        #expect(a == b)
    }

    @Test
    func emptyAndFlatVectorsYieldNil() {
        #expect(Voiceprint.downsampleNormalize([], buckets: 32) == nil)
        #expect(Voiceprint.downsampleNormalize([Float](repeating: 0.0, count: 192), buckets: 32) == nil)
        #expect(Voiceprint.downsampleNormalize([Float](repeating: 5.0, count: 192), buckets: 32) == nil)
    }

    @Test
    func nonFiniteInputYieldsNil() {
        var embedding = [Float](repeating: 0.5, count: 192)
        embedding[0] = Float.nan
        #expect(Voiceprint.downsampleNormalize(embedding, buckets: 32) == nil)
    }

    @Test
    func handlesFewerValuesThanBuckets() throws {
        let embedding: [Float] = [0.0, 1.0, 2.0, 3.0]
        let sig = Voiceprint.downsampleNormalize(embedding, buckets: 32)
        let values = try #require(sig)
        #expect(values.count == 32)
        #expect(values.allSatisfy { $0 >= 0.0 && $0 <= 1.0 })
    }

    @Test
    func zeroBucketsYieldsNil() {
        #expect(Voiceprint.downsampleNormalize([1.0, 2.0, 3.0], buckets: 0) == nil)
    }

    // MARK: - signature(fromCentroid:)

    @Test
    func signatureIsDeterministicOverCentroidRoundTrip() {
        let embedding: [Float] = (0 ..< 192).map { sinf(Float($0) * 0.13) }
        let centroid = CentroidCodec.data(from: embedding)
        let a = Voiceprint.signature(fromCentroid: centroid)
        let b = Voiceprint.signature(fromCentroid: centroid)
        #expect(a != nil)
        #expect(a == b)
        #expect(a == Voiceprint.downsampleNormalize(embedding, buckets: 32))
    }

    @Test
    func signatureFromDegenerateCentroidYieldsNil() {
        let flat = [Float](repeating: 1.0, count: 192)
        let centroid = CentroidCodec.data(from: flat)
        #expect(Voiceprint.signature(fromCentroid: centroid) == nil)
    }

    @Test
    func signatureFromEmptyCentroidYieldsNil() {
        #expect(Voiceprint.signature(fromCentroid: Data()) == nil)
    }
}
