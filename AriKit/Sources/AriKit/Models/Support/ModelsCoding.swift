//
//  ModelsCoding.swift — shared Codable factory + RFC3339 date strategy (plan §7.3).
//
//  Every domain type decodes/encodes through `Models.jsonDecoder` / `Models.jsonEncoder` so
//  the date policy is defined in exactly one place:
//  - Real instants (`createdAt`, `updatedAt`, `observedAt`, event `start`/`end`) are `Date`,
//    parsed from RFC3339 tolerant of fractional seconds and of both `Z` and numeric UTC offset.
//  - Numeric audio offsets stay `Double` seconds (they are not dates and are untouched here).
//  - A malformed date string surfaces a `DecodingError`, never a silent default (No-Fake-State).
//
//  Ambiguous string-timestamps that the engine has not confirmed as instants
//  (`Transcript.timestamp`) stay `String` on their types and never reach this strategy.
//
//  The factories are computed (fresh instance per access) rather than shared `static let`
//  singletons, because `JSONDecoder`/`JSONEncoder` are non-`Sendable` reference types.
//
import Foundation

public extension Models {
    /// The canonical decoder for every domain value type.
    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = RFC3339.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an RFC3339 date string, got \"\(string)\"."
                )
            }
            return date
        }
        return decoder
    }

    /// The canonical encoder for every domain value type. Emits RFC3339 with fractional
    /// seconds and a `Z` zone, so encode→decode round-trips through `jsonDecoder`.
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.string(from: date))
        }
        return encoder
    }
}

/// RFC3339 parsing/formatting shared by the domain date strategy. `ISO8601DateFormatter`
/// instances are created per call (they are not `Sendable`); this layer is not a hot path.
enum RFC3339 {
    static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
