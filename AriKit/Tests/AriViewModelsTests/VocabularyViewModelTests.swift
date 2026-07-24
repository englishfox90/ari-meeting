//
//  VocabularyViewModelTests.swift — docs/plans/custom-vocabulary.md §5, T-V1.
//
//  The cap and duplicate-term errors must surface as REAL, human-readable messages — never a
//  silent no-op (No-Fake-State). `VocabularyRepository`'s write-transaction checks are already
//  covered by `VocabularyRepositoryTests`; this pins that the view model faithfully relays those
//  failures to `errorMessage` rather than swallowing them.
//
import Foundation
import Testing
@testable import AriKit
@testable import AriViewModels

@Suite("VocabularyViewModel")
@MainActor
struct VocabularyViewModelTests {
    private func makeTerm(_ id: String, term: String, isEnabled: Bool = true) -> VocabularyTerm {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return VocabularyTerm(
            id: VocabularyTermID(id),
            term: term,
            isEnabled: isEnabled,
            createdAt: now,
            updatedAt: now
        )
    }

    @Test("capIsSurfacedHonestly")
    func capIsSurfacedHonestly() async throws {
        let database = try AppDatabase.makeInMemory()
        for index in 0 ..< VocabularyBias.maxEnabledTerms {
            try await database.vocabulary.upsert(makeTerm("term-\(index)", term: "Term \(index)"))
        }

        let viewModel = VocabularyViewModel(database: database)
        await viewModel.observe()

        #expect(viewModel.enabledCount == VocabularyBias.maxEnabledTerms)
        #expect(viewModel.isAtCap == true)

        let error = await viewModel.add(
            term: "One too many",
            definition: nil,
            alternateForms: [],
            misheardAs: [],
            isEnabled: true
        )

        #expect(error != nil, "adding past the cap must surface a real error, not silently no-op")
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.errorMessage?.contains("\(VocabularyBias.maxEnabledTerms)") == true)
        // The 51st term must genuinely not have been persisted.
        #expect(viewModel.enabledCount == VocabularyBias.maxEnabledTerms)
    }

    @Test("duplicateTermIsSurfacedHonestly")
    func duplicateTermIsSurfacedHonestly() async throws {
        let database = try AppDatabase.makeInMemory()
        try await database.vocabulary.upsert(makeTerm("term-arivo", term: "Arivo"))

        let viewModel = VocabularyViewModel(database: database)
        await viewModel.observe()

        let error = await viewModel.add(
            term: " arivo ",
            definition: nil,
            alternateForms: [],
            misheardAs: [],
            isEnabled: true
        )

        #expect(error != nil, "a duplicate normalized term must surface a real error, not silently no-op")
        #expect(viewModel.errorMessage?.localizedCaseInsensitiveContains("arivo") == true)
        #expect(viewModel.terms.count == 1)
    }
}
