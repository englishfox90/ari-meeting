//
//  VocabularyGlossary.swift — pure "### Glossary" block renderer for the summary context
//  (docs/plans/custom-vocabulary.md §2.3).
//
//  Pure — no Store. Terse by construction (prompt bloat is a standing PRD risk): definitions are
//  truncated via `SummaryContextAssembler.truncateChars` and the whole block is empty (not a bare
//  heading) when there is nothing to say.
//
//  This is the one place `misheardAs` is *supposed* to surface (plan §6) — unlike
//  `VocabularyBias`, which must never read it.
//
import Foundation

enum VocabularyGlossary {
    static let maxDefinitionChars = 80

    /// Returns "" when there is nothing to say — never a bare `### Glossary` heading.
    static func block(for terms: [VocabularyTerm]) -> String {
        let lines: [String] = terms
            .filter(\.isEnabled)
            .compactMap { term -> String? in
                guard let trimmedTerm = SummaryContextAssembler.trimmedNonEmpty(term.term) else {
                    return nil
                }

                var line = "- \(trimmedTerm)"

                let alternateForms = term.alternateForms
                    .compactMap { SummaryContextAssembler.trimmedNonEmpty($0) }
                if !alternateForms.isEmpty {
                    line += " (also written: \(alternateForms.joined(separator: ", ")))"
                }

                if let definition = SummaryContextAssembler.trimmedNonEmpty(term.definition) {
                    line += " — \(SummaryContextAssembler.truncateChars(definition, max: maxDefinitionChars))"
                }

                let misheardAs = term.misheardAs
                    .compactMap { SummaryContextAssembler.trimmedNonEmpty($0) }
                if !misheardAs.isEmpty {
                    let quoted = misheardAs.map { "\"\($0)\"" }.joined(separator: ", ")
                    line += " Sometimes mis-transcribed as \(quoted)."
                }

                return line
            }

        guard !lines.isEmpty else { return "" }

        return (["### Glossary (spell these exactly)"] + lines).joined(separator: "\n")
    }
}
