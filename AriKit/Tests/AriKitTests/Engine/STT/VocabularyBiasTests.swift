//
//  VocabularyBiasTests.swift — bias resolver acceptance tests T-B1..T-B9
//  (docs/plans/custom-vocabulary.md §5).
//
import Foundation
import Testing
@testable import AriKit

@Suite("VocabularyBias")
struct VocabularyBiasTests {
    private func makeTerm(
        term: String,
        definition: String? = nil,
        alternateForms: [String] = [],
        misheardAs: [String] = [],
        isEnabled: Bool = true
    ) -> VocabularyTerm {
        VocabularyTerm(
            id: VocabularyTermID(UUID().uuidString),
            term: term,
            definition: definition,
            alternateForms: alternateForms,
            misheardAs: misheardAs,
            isEnabled: isEnabled,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - T-B1

    @Test("T-B1 empty vocabulary resolves to nil, not an empty VocabularyBias")
    func emptyVocabularyResolvesToNil() {
        #expect(VocabularyBias.resolve([]) == nil)

        let allDisabled = [
            makeTerm(term: "Arivo", isEnabled: false),
            makeTerm(term: "AriKit", isEnabled: false)
        ]
        #expect(VocabularyBias.resolve(allDisabled) == nil)
    }

    // MARK: - T-B2 / T-B3 — load-bearing

    @Test("T-B2 definition never reaches contextualStrings")
    func definitionNeverReachesContextualStrings() {
        let terms = [makeTerm(term: "Arivo", definition: "A very distinctive gloss XYZZY")]
        let bias = VocabularyBias.resolve(terms)
        #expect(bias != nil)
        #expect(bias?.contextualStrings.contains { $0.contains("XYZZY") } == false)
    }

    @Test("T-B3 misheardAs never reaches contextualStrings")
    func misheardAsNeverReachesContextualStrings() {
        let terms = [makeTerm(term: "Arivo", misheardAs: ["Revo", "Arrivo"])]
        let bias = VocabularyBias.resolve(terms)
        #expect(bias != nil)
        #expect(bias?.contextualStrings.contains("Revo") == false)
        #expect(bias?.contextualStrings.contains("Arrivo") == false)
    }

    // MARK: - T-B4

    @Test("T-B4 cap is enforced and reported")
    func capIsEnforcedAndReported() {
        // 30 terms x 4 alternate forms (capped) = 150 candidate strings, well past the 100 cap.
        let terms = (0..<30).map { index in
            makeTerm(
                term: "Term\(index)",
                alternateForms: (0..<4).map { "Term\(index)Alt\($0)" }
            )
        }
        let bias = VocabularyBias.resolve(terms)
        #expect(bias?.contextualStrings.count == VocabularyBias.maxContextualStrings)
        #expect(bias?.droppedCount == 150 - VocabularyBias.maxContextualStrings)
    }

    // MARK: - T-B5

    @Test("T-B5 truncation sacrifices variants before canonical terms")
    func truncationSacrificesVariantsBeforeCanonicalTerms() {
        let terms = (0..<30).map { index in
            makeTerm(
                term: "Term\(index)",
                alternateForms: (0..<4).map { "Term\(index)Alt\($0)" }
            )
        }
        let bias = VocabularyBias.resolve(terms)
        let canonicalTerms = Set(terms.map(\.term))
        let present = Set(bias?.contextualStrings ?? [])
        #expect(canonicalTerms.isSubset(of: present))
    }

    // MARK: - T-B6

    @Test("T-B6 resolution is deterministic regardless of input order")
    func resolutionIsDeterministic() {
        let terms = [
            makeTerm(term: "Zebra", alternateForms: ["Zeb"]),
            makeTerm(term: "Arivo", alternateForms: ["AriKit"]),
            makeTerm(term: "Mango")
        ]
        let shuffled = terms.shuffled()

        let biasA = VocabularyBias.resolve(terms)
        let biasB = VocabularyBias.resolve(shuffled)
        #expect(biasA == biasB)
    }

    // MARK: - T-B7

    @Test("T-B7 case-insensitive duplicates collapse")
    func caseInsensitiveDuplicatesCollapse() {
        let terms = [
            makeTerm(term: "Arivo"),
            makeTerm(term: "ARIVO"),
            makeTerm(term: "arivo")
        ]
        let bias = VocabularyBias.resolve(terms)
        #expect(bias?.contextualStrings.count == 1)
    }

    // MARK: - T-B8

    @Test("T-B8 blank and whitespace-only entries are dropped")
    func blankAndWhitespaceOnlyEntriesDropped() {
        let terms = [
            makeTerm(term: "  Arivo  ", alternateForms: ["   ", "", "AriKit"])
        ]
        let bias = VocabularyBias.resolve(terms)
        #expect(bias?.contextualStrings == ["Arivo", "AriKit"])

        let allBlank = [makeTerm(term: "   ")]
        #expect(VocabularyBias.resolve(allBlank) == nil)
    }

    // MARK: - T-B9

    @Test("T-B9 alternate forms are capped per term")
    func alternateFormsAreCappedPerTerm() {
        let terms = [
            makeTerm(term: "Arivo", alternateForms: ["A1", "A2", "A3", "A4", "A5", "A6"])
        ]
        let bias = VocabularyBias.resolve(terms)
        // 1 canonical term + at most maxAlternateFormsPerTerm variants.
        #expect(bias?.contextualStrings.count == 1 + VocabularyBias.maxAlternateFormsPerTerm)
        #expect(bias?.contextualStrings.contains("A5") == false)
        #expect(bias?.contextualStrings.contains("A6") == false)
    }
}
