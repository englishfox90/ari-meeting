//
//  Identifier.swift — phantom-typed identifier (plan decision 0.1 / §7.4).
//
//  A `String`-backed identifier tagged with the entity it identifies, so the 6+ coexisting
//  `String` ID kinds (meeting / transcript / speaker / person / fact / series / …) cannot be
//  accidentally interchanged. `Entity` is a phantom type parameter — it is never stored, so
//  every `Identifier<Entity>` is unconditionally `Sendable`/`Hashable` regardless of `Entity`,
//  and encodes transparently as a bare JSON string (single-value container), leaving the
//  persistence / wire / CKRecord shape identical to a plain `String`.
//
import Foundation

public struct Identifier<Entity>: RawRepresentable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Ergonomic literal construction, primarily for fixtures/tests. Remains entity-typed —
    /// a literal still cannot cross from one entity's identifier to another's.
    public init(stringLiteral value: String) {
        rawValue = value
    }

    public var description: String { rawValue }

    // Bare-string single-value coding (plan §7.4): `Identifier` is indistinguishable from a
    // `String` on the wire and in storage.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// Equatable/Hashable implemented explicitly so they stay unconditional (the synthesized
// forms would otherwise risk constraining the phantom `Entity`).
extension Identifier: Equatable {
    public static func == (lhs: Identifier, rhs: Identifier) -> Bool {
        lhs.rawValue == rhs.rawValue
    }
}

extension Identifier: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
