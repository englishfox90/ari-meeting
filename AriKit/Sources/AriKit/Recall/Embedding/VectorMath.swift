//
//  VectorMath.swift — vector pack/unpack + cosine (plan §7, ← embedding.rs:84-117).
//
//  Embeddings are stored as packed little-endian f32 bytes (opaque BLOB), matching the
//  `speaker.centroid` convention — the DB layer never interprets them; all math lives here. Byte
//  layout mirrors Rust `f32::to_le_bytes` / `from_le_bytes` exactly so vectors written by either
//  side round-trip.
//
import Foundation

extension Recall {
    /// Pack a vector into little-endian f32 bytes (← `pack_f32`).
    public static func packF32(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            var littleEndian = value.bitPattern.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Unpack little-endian f32 bytes into a vector (← `unpack_f32`). Trailing bytes that do not
    /// form a full 4-byte lane are ignored (Rust `chunks_exact(4)`).
    public static func unpackF32(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var result = [Float]()
        result.reserveCapacity(count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<count {
                let base = i * 4
                let bits = UInt32(raw[base])
                    | (UInt32(raw[base + 1]) << 8)
                    | (UInt32(raw[base + 2]) << 16)
                    | (UInt32(raw[base + 3]) << 24)
                result.append(Float(bitPattern: bits))
            }
        }
        return result
    }

    /// Cosine similarity in `[-1, 1]` (← `cosine`). Returns `0` for empty or mismatched-length
    /// vectors (a vector from a different embedder / dimension simply never matches) and for a
    /// zero-norm operand.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        if a.isEmpty || a.count != b.count {
            return 0
        }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        if normA == 0 || normB == 0 {
            return 0
        }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
