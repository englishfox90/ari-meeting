//
//  CentroidCodecTests.swift — ← Rust `ari-engine/src/diarization/engine.rs` BLOB round-trip
//  tests (`centroid_bytes_round_trip_is_exact`, `centroid_bytes_empty_round_trips`,
//  `bytes_to_centroid_ignores_partial_tail`, `centroid_bytes_are_little_endian`).
//
import Foundation
import Testing
@testable import AriKit

@Suite("CentroidCodec")
struct CentroidCodecTests {
    @Test
    func centroidBytesRoundTripIsExact() {
        let v: [Float] = [
            0.0,
            1.0,
            -1.0,
            0.5,
            -0.25,
            Float.leastNormalMagnitude,
            123456.789,
            -987654.321
        ]
        let bytes = CentroidCodec.data(from: v)
        #expect(bytes.count == v.count * 4, "4 bytes per f32")
        let back = CentroidCodec.vector(from: bytes)
        #expect(back == v, "round-trip must be bit-exact")
    }

    @Test
    func centroidBytesEmptyRoundTrips() {
        #expect(CentroidCodec.data(from: []).isEmpty)
        #expect(CentroidCodec.vector(from: Data()).isEmpty)
    }

    @Test
    func bytesToCentroidIgnoresPartialTail() {
        // 6 bytes = one f32 + a 2-byte tail that must be dropped.
        var bytes = CentroidCodec.data(from: [3.5])
        bytes.append(contentsOf: [0xAB, 0xCD])
        #expect(CentroidCodec.vector(from: bytes) == [3.5])
    }

    @Test
    func centroidBytesAreLittleEndian() {
        // 1.0f32 == 0x3F800000; little-endian byte order is [00,00,80,3F].
        #expect(CentroidCodec.data(from: [1.0]) == Data([0x00, 0x00, 0x80, 0x3F]))
    }
}
