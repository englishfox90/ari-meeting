//
//  VocabularyTerm.swift — a user-authored domain proper noun (docs/plans/custom-vocabulary.md §2.1).
//
//  Feeds two independent consumers: recognizer biasing (`term` + `alternateForms`, via
//  `Engine/STT/VocabularyBias.swift`) and the summarizer glossary (`term` + `definition` +
//  `misheardAs`, via `Engine/Summary/VocabularyGlossary.swift`). `definition`/`misheardAs` are
//  glossary-only and must NEVER reach the recognizer — feeding an observed mis-transcription into
//  the decoder's contextual strings biases it TOWARD the error (plan §6, "the mis-hearing trap").
//
//  Named `definition`, not `description` — a stored property named `description` on a struct
//  shadows `CustomStringConvertible.description` and makes every `"\(term)"` interpolation
//  surprising (plan §2.1).
//
import Foundation

/// Typed identifier for a `VocabularyTerm` (plan §7.4 pattern).
public typealias VocabularyTermID = Identifier<VocabularyTerm>

public struct VocabularyTerm: Codable, Hashable, Sendable, Identifiable {
    public var id: VocabularyTermID
    /// The canonical spelling, exactly as it should appear in a transcript. e.g. "Arivo".
    public var term: String
    /// Optional one-line gloss for the summarizer. NEVER sent to the recognizer.
    public var definition: String?
    /// Other CORRECT spoken/written forms of the same thing ("AriKit" / "Ari Kit").
    /// These ARE sent to the recognizer. See the file header for the mis-hearing trap.
    public var alternateForms: [String]
    /// Known WRONG transcriptions ("Revo" for "Arivo"). Glossary-only — never
    /// sent to the recognizer, where they would bias TOWARD the error.
    public var misheardAs: [String]
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: VocabularyTermID,
        term: String,
        definition: String? = nil,
        alternateForms: [String] = [],
        misheardAs: [String] = [],
        isEnabled: Bool = true,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.term = term
        self.definition = definition
        self.alternateForms = alternateForms
        self.misheardAs = misheardAs
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
