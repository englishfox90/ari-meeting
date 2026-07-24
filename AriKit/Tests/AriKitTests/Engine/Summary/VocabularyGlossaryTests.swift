//
//  VocabularyGlossaryTests.swift — glossary renderer acceptance tests T-G1..T-G5
//  (docs/plans/custom-vocabulary.md §5).
//
import Foundation
import Testing
@testable import AriKit

@Suite("VocabularyGlossary")
struct VocabularyGlossaryTests {
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

    // MARK: - T-G1

    @Test("T-G1 empty vocabulary emits no heading")
    func emptyVocabularyEmitsNoHeading() {
        #expect(VocabularyGlossary.block(for: []) == "")

        let allDisabled = [makeTerm(term: "Arivo", isEnabled: false)]
        #expect(VocabularyGlossary.block(for: allDisabled) == "")
    }

    // MARK: - T-G2

    @Test("T-G2 disabled terms are excluded")
    func disabledTermsAreExcluded() {
        let terms = [
            makeTerm(term: "Arivo", isEnabled: true),
            makeTerm(term: "Excluded", isEnabled: false)
        ]
        let block = VocabularyGlossary.block(for: terms)
        #expect(block.contains("Arivo"))
        #expect(!block.contains("Excluded"))
    }

    // MARK: - T-G3

    @Test("T-G3 definitions are truncated via SummaryContextAssembler.truncateChars")
    func definitionsAreTruncated() {
        let longDefinition = String(repeating: "x", count: 500)
        let terms = [makeTerm(term: "Arivo", definition: longDefinition)]
        let block = VocabularyGlossary.block(for: terms)

        let expectedTruncated = SummaryContextAssembler.truncateChars(
            longDefinition,
            max: VocabularyGlossary.maxDefinitionChars
        )
        #expect(block.contains(expectedTruncated))
        #expect(!block.contains(longDefinition))
    }

    // MARK: - T-G4

    @Test("T-G4 misheard forms appear in the glossary")
    func misheardFormsAppearInGlossary() {
        let terms = [makeTerm(term: "Arivo", misheardAs: ["Revo", "Arrivo"])]
        let block = VocabularyGlossary.block(for: terms)
        #expect(block.contains("Revo"))
        #expect(block.contains("Arrivo"))
    }

    // MARK: - T-G5

    @Test("T-G5 glossary is bounded overall")
    func glossaryIsBoundedOverall() {
        let longDefinition = String(repeating: "x", count: 500)
        let terms = (0..<VocabularyBias.maxEnabledTerms).map { index in
            makeTerm(
                term: "Term\(index) with a moderately long canonical spelling",
                definition: longDefinition,
                alternateForms: ["Alt1-\(index)", "Alt2-\(index)"],
                misheardAs: ["Mis1-\(index)", "Mis2-\(index)"]
            )
        }
        let block = VocabularyGlossary.block(for: terms)

        // A concrete ceiling so prompt growth is a test failure, not a surprise (plan T-G5).
        // Each line is bounded (~term + " (also written: ...)" + " — " + 80-char definition +
        // " Sometimes mis-transcribed as ...") — 300 chars/line is a generous per-line ceiling,
        // so 50 terms stays comfortably under 15,050 chars including the heading.
        #expect(block.count < 15_100)
    }
}
