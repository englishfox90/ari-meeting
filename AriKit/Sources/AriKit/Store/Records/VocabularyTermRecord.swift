//
//  VocabularyTermRecord.swift — GRDB record for the `vocabularyTerm` table
//  (docs/plans/custom-vocabulary.md §4.1/§4.2).
//
//  Store-internal only — `VocabularyRepository` translates to/from the public
//  `AriKit.Models.VocabularyTerm` value type. `alternateForms`/`misheardAs` are kept as inline
//  JSON columns, mirroring `CalendarEventRecord.attendeesJson`. `normalizedTerm` is a
//  case/whitespace/diacritic-folded duplicate-detection key, never displayed — computed by the
//  pure `VocabularyTermRecord.normalize(_:)` so it is unit-testable independently of the DB.
//
import Foundation
import GRDB

struct VocabularyTermRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "vocabularyTerm"

    var id: String
    var term: String
    var normalizedTerm: String
    var definition: String?
    var alternateFormsJson: String?
    var misheardAsJson: String?
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool
    var deletedAt: Date?
}

extension VocabularyTermRecord {
    /// Throws only if the array fields somehow fail to encode (never expected for `[String]`) —
    /// surfaced rather than silently dropping data (No-Fake-State), matching
    /// `CalendarEventRecord.init(_:)`.
    init(_ term: VocabularyTerm) throws {
        id = term.id.rawValue
        self.term = term.term
        normalizedTerm = Self.normalize(term.term)
        definition = term.definition
        alternateFormsJson = try Self.encodeJSON(term.alternateForms)
        misheardAsJson = try Self.encodeJSON(term.misheardAs)
        isEnabled = term.isEnabled
        createdAt = term.createdAt
        updatedAt = term.updatedAt
        isDeleted = false
        deletedAt = nil
    }

    func asModel() -> VocabularyTerm {
        VocabularyTerm(
            id: VocabularyTermID(id),
            term: term,
            definition: definition,
            alternateForms: Self.decodeJSON(alternateFormsJson),
            misheardAs: Self.decodeJSON(misheardAsJson),
            isEnabled: isEnabled,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func encodeJSON(_ strings: [String]) throws -> String {
        let data = try Models.jsonEncoder.encode(strings)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeJSON(_ json: String?) -> [String] {
        guard let json else { return [] }
        return (try? Models.jsonDecoder.decode([String].self, from: Data(json.utf8))) ?? []
    }

    /// Case/whitespace/diacritic-folded duplicate-detection key (plan §4.2): trim, collapse
    /// internal whitespace, lowercase under `en_US_POSIX` (locale-independent), then fold
    /// diacritics. Pure — unit-tested independently of the DB (T-S3/T-S4).
    static func normalize(_ term: String) -> String {
        let collapsedWhitespace = term
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedWhitespace
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
