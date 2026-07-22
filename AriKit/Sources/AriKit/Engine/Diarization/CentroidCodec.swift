//
//  CentroidCodec.swift — centroid/embedding blob (de)serialization
//  (← Rust `ari-engine/src/diarization/engine.rs:557-572` `centroid_to_bytes`/`bytes_to_centroid`).
//
//  Opaque little-endian `Vec<f32>` <-> `Data`, for the DB BLOB layer. Pure, no IO.
//
import Foundation

public enum CentroidCodec {
    /// Serialize a centroid/embedding to opaque little-endian bytes for BLOB storage. Exact
    /// inverse of `vector(from:)`.
    public static func data(from vector: [Float]) -> Data {
        var out = Data(capacity: vector.count * 4)
        for f in vector {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    /// Deserialize a little-endian BLOB back into a centroid/embedding. A trailing partial
    /// (non-4-byte-aligned) tail is ignored. Exact inverse of `data(from:)`.
    public static func vector(from data: Data) -> [Float] {
        let bytes = [UInt8](data)
        let count = bytes.count / 4
        var out = [Float]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let offset = i * 4
            let bits = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            out.append(Float(bitPattern: bits))
        }
        return out
    }
}
