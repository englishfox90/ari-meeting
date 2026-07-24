//
//  VocabularyBias.swift — pure resolver from `[VocabularyTerm]` to `AnalysisContext`-ready
//  contextual strings (docs/plans/custom-vocabulary.md §2.3).
//
//  Pure — no Store, no Speech import. `resolve` is the single entrypoint; every other detail is
//  an implementation detail of the algorithm described in the doc comment below.
//
//  ⚠️ LOAD-BEARING INVARIANT (plan §6, "the mis-hearing trap"): `definition` and `misheardAs`
//  must NEVER appear in `contextualStrings`. Feeding an observed mis-transcription ("Revo") into
//  the decoder's contextual strings biases it TOWARD the error, not away from it. Pinned by
//  `VocabularyBiasTests.definitionNeverReachesContextualStrings` /
//  `.misheardAsNeverReachesContextualStrings`.
//
import Foundation

public struct VocabularyBias: Sendable, Equatable {
    /// The strings handed to `AnalysisContext.contextualStrings[.general]`, in a
    /// deterministic term-major order. Never empty (see `resolve`).
    public let contextualStrings: [String]
    /// How many candidate strings were dropped to stay under `maxContextualStrings`.
    /// Surfaced honestly in Settings and logged; never silently swallowed.
    public let droppedCount: Int

    public static let maxContextualStrings = 100
    public static let maxEnabledTerms = 50
    public static let maxAlternateFormsPerTerm = 4

    /// Resolution, all pure and unit-testable:
    ///
    /// 1. Keep `isEnabled == true` only.
    /// 2. Trim, drop empties, case-insensitively de-duplicate across the whole candidate set.
    /// 3. Never include `definition` or `misheardAs` (see file header).
    /// 4. Truncate `alternateForms` to `maxAlternateFormsPerTerm` per term.
    /// 5. Order term-major: every canonical `term` first (sorted by `term`, stable), then
    ///    alternate forms in the same term order — so truncation at the ceiling always
    ///    sacrifices variants before canonical spellings.
    /// 6. Truncate the joined list to `maxContextualStrings`, recording `droppedCount`.
    /// 7. Empty result → `nil` — not an empty value. A `nil` result means the caller must attach
    ///    NO `AnalysisContext` at all.
    public static func resolve(_ terms: [VocabularyTerm]) -> VocabularyBias? {
        let enabled = terms.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        let candidates: [(term: String, alternateForms: [String])] = enabled.compactMap { term in
            let trimmedTerm = term.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTerm.isEmpty else { return nil }
            let trimmedForms = term.alternateForms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return (trimmedTerm, trimmedForms)
        }
        guard !candidates.isEmpty else { return nil }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            Self.foldedKey(lhs.term) < Self.foldedKey(rhs.term)
        }

        var seen = Set<String>()
        var ordered: [String] = []

        // Pass 1: every canonical term, de-duplicated case-insensitively.
        for candidate in sortedCandidates {
            let key = Self.foldedKey(candidate.term)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(candidate.term)
        }

        // Pass 2: alternate forms, capped per term, in the same term-major order — so
        // truncation below always sacrifices these before any canonical term above.
        for candidate in sortedCandidates {
            let cappedForms = candidate.alternateForms.prefix(maxAlternateFormsPerTerm)
            for form in cappedForms {
                let key = Self.foldedKey(form)
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                ordered.append(form)
            }
        }

        guard !ordered.isEmpty else { return nil }

        let droppedCount = max(0, ordered.count - maxContextualStrings)
        let truncated = Array(ordered.prefix(maxContextualStrings))

        return VocabularyBias(contextualStrings: truncated, droppedCount: droppedCount)
    }

    /// Locale-independent case-fold used for de-duplication and the term-major sort key.
    private static func foldedKey(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
