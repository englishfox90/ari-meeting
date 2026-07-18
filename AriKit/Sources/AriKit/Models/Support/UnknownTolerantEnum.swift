//
//  UnknownTolerantEnum.swift — forward-compatible String enum pattern (plan §7.2).
//
//  The frozen engine stores several open-ish string sets (enrollment state, fact kind/status,
//  segment source, calendar link source, …). A newer engine build can emit a value this Swift
//  version has never seen; the domain layer must **never fail to decode** on that account.
//
//  This protocol gives every such enum a `.unknown(String)` escape hatch: an unrecognized raw
//  value decodes into `.unknown(raw)` (never throws) and re-encodes to exactly `raw`, so the
//  round-trip is lossless and no forward information is dropped.
//
//  Conformers implement `RawRepresentable` by hand (returning `nil` for unrecognized raws) and
//  route Codable through `init(tolerantFrom:)` / `encodeTolerant(to:)`. The two coding methods
//  are given deliberately distinct names, and each enum declares `init(from:)` / `encode(to:)`
//  explicitly, so the compiler's associated-value Codable synthesis can never shadow the
//  tolerant behavior.
//
import Foundation

public protocol UnknownTolerantEnum: RawRepresentable, Codable, Hashable, Sendable
    where RawValue == String {
    /// Wraps a raw value that matched no known case.
    static func unknownCase(_ rawValue: String) -> Self
}

public extension UnknownTolerantEnum {
    /// Decodes a single string; unrecognized raws become `.unknown(raw)` instead of throwing.
    init(tolerantFrom decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknownCase(raw)
    }

    /// Encodes the raw value as a bare string (known or preserved-unknown alike).
    func encodeTolerant(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
