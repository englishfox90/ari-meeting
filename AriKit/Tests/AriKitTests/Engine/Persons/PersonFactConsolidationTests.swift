//
//  PersonFactConsolidationTests.swift — docs/plans/person-fact-consolidation.md §8, mirroring
//  `PersonReconciliationTests.swift`'s structure (in-memory `AppDatabase`,
//  `StubSettingsReading`/`StubSecretsReading`, `StubLLMClient` with a canned response) — headless,
//  no network/Store-owner violation.
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonFactConsolidation — person-fact-consolidation plan")
struct PersonFactConsolidationTests {
    private func makePerson(
        id: String = "person-sarah",
        email: String = "sarah@example.com",
        name: String = "Sarah"
    ) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: name,
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeFact(
        person: PersonID,
        text: String,
        status: FactStatus = .active,
        confidence: Double = 0.5,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ProfileFact {
        ProfileFact(
            id: ProfileFactID(UUID().uuidString),
            personId: person,
            factText: text,
            factKind: .other,
            origin: .attributed,
            confidence: confidence,
            sourceCount: 0,
            status: status,
            createdAt: createdAt
        )
    }

    private func makeConsolidation(
        db: AppDatabase,
        cannedResponse: String,
        summaryModelConfigValue: SummaryModelConfig? = SummaryModelConfig(
            providerKey: "claude",
            model: "claude-3-5-sonnet"
        )
    ) -> PersonFactConsolidation {
        PersonFactConsolidation(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: summaryModelConfigValue),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            clientFactory: { _ in StubLLMClient(kind: .claude, cannedResponse: cannedResponse) }
        )
    }

    // MARK: - Degrade-gracefully (never throws)

    @Test("Fewer than 2 existing facts (0) degrades to an all-zero result, no LLM call made")
    func zeroFactsDegradesWithoutCallingModel() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)

        // A canned response that would throw/produce garbage if the client were actually invoked
        // proves the early return short-circuits before any LLM call.
        let consolidation = PersonFactConsolidation(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: SummaryModelConfig(
                providerKey: "claude", model: "claude-3-5-sonnet"
            )),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            clientFactory: { _ in StubLLMClient(kind: .claude, error: .requestFailed("should never be called")) }
        )
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result == ConsolidationResult(merged: 0, factsRetired: 0, kept: 0, message: result.message))
    }

    @Test("Exactly 1 existing fact degrades to an all-zero result, no LLM call made")
    func oneFactDegradesWithoutCallingModel() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Only fact"))

        let consolidation = PersonFactConsolidation(
            db: db,
            settings: StubSettingsReading(summaryModelConfigValue: SummaryModelConfig(
                providerKey: "claude", model: "claude-3-5-sonnet"
            )),
            secrets: StubSecretsReading(apiKeys: ["claude": "test-key"]),
            clientFactory: { _ in StubLLMClient(kind: .claude, error: .requestFailed("should never be called")) }
        )
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0 && result.kept == 0)
        #expect(try await db.profileFacts.all().count == 1)
    }

    @Test("Unconfigured provider degrades to an all-zero result")
    func unconfiguredProviderDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact A"))
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact B"))

        let consolidation = makeConsolidation(db: db, cannedResponse: "[]", summaryModelConfigValue: nil)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0 && result.kept == 0)
    }

    @Test("Malformed/unparseable model response degrades to an all-zero result")
    func unparseableModelResponseDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact A"))
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact B"))

        let consolidation = makeConsolidation(db: db, cannedResponse: "not json")
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0 && result.kept == 0)
    }

    @Test("Empty ops array ([]) degrades to an all-zero result — nothing to consolidate")
    func emptyOpsArrayDegrades() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact A"))
        try await db.profileFacts.upsert(makeFact(person: sarah.id, text: "Fact B"))

        let consolidation = makeConsolidation(db: db, cannedResponse: "[]")
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0 && result.factsRetired == 0 && result.kept == 0)
        let all = try await db.profileFacts.all()
        #expect(all.count == 2)
    }

    // MARK: - Happy path

    @Test("A 'merge' op with 3 fact_ids creates exactly 1 new pending fact and 3 supersession rows")
    func mergeCreatesOnePendingFactAndSupersessionRows() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        let factA = makeFact(person: sarah.id, text: "Leads the migration")
        let factB = makeFact(person: sarah.id, text: "Is leading a migration project")
        let factC = makeFact(person: sarah.id, text: "Owns the migration effort")
        try await db.profileFacts.upsert(factA)
        try await db.profileFacts.upsert(factB)
        try await db.profileFacts.upsert(factC)

        let canned = """
        [{"op": "merge", \
        "fact_ids": ["\(factA.id.rawValue)", "\(factB.id.rawValue)", "\(factC.id.rawValue)"], \
        "fact_id": null, "fact_text": "Leads the platform migration project", \
        "fact_kind": "project", "confidence": 0.8, "reason": null}]
        """
        let consolidation = makeConsolidation(db: db, cannedResponse: canned)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 1)
        #expect(result.factsRetired == 3)
        #expect(result.kept == 0)

        let all = try await db.profileFacts.all()
        #expect(all.count == 4) // 3 old (still active, unconfirmed) + 1 new pending
        let newFact = try #require(all.first {
            ![factA.id, factB.id, factC.id].contains($0.id)
        })
        #expect(newFact.status == .pending)
        #expect(newFact.factText == "Leads the platform migration project")

        // The 3 old facts are unchanged/still active — deferred supersession, nothing retired yet.
        for oldId in [factA.id, factB.id, factC.id] {
            let reloaded = try await db.profileFacts.find(oldId)
            #expect(reloaded?.status == .active)
        }

        let supersessionIds = try await db.profileFacts.oldFactIds(supersededBy: newFact.id)
        #expect(Set(supersessionIds) == Set([factA.id, factB.id, factC.id]))

        // Confirm-then-retire integration: this is the test that proves the §4.1 gap is closed —
        // a naive `markSupersedes`-called-3× approach would only retire the LAST-written old fact.
        try await db.profileFacts.confirmFact(newFact.id)
        for oldId in [factA.id, factB.id, factC.id] {
            let reloaded = try await db.profileFacts.find(oldId)
            #expect(reloaded?.status == .superseded)
            #expect(reloaded?.supersededBy == newFact.id)
        }
    }

    @Test("A 'keep' op is a no-op: kept == 1, no DB mutation")
    func keepIsANoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        let existing = makeFact(person: sarah.id, text: "Distinct fact", status: .active, confidence: 0.5)
        let other = makeFact(person: sarah.id, text: "Another distinct fact", status: .active, confidence: 0.6)
        try await db.profileFacts.upsert(existing)
        try await db.profileFacts.upsert(other)

        let canned = """
        [{"op": "keep", "fact_ids": null, "fact_id": "\(existing.id.rawValue)", \
        "fact_text": null, "fact_kind": null, "confidence": null, "reason": null}]
        """
        let consolidation = makeConsolidation(db: db, cannedResponse: canned)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.kept == 1)
        #expect(result.merged == 0)
        let reloaded = try #require(try await db.profileFacts.find(existing.id))
        #expect(reloaded.status == .active)
        #expect(reloaded.factText == "Distinct fact")
    }

    // MARK: - Rejections (No-Fake-State discipline)

    @Test("A 'merge' whose fact_ids includes an id belonging to a DIFFERENT person is rejected whole")
    func mergeRefusesUnownedFactId() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        let bob = makePerson(id: "person-bob", email: "bob@example.com", name: "Bob")
        try await db.persons.upsert(sarah)
        try await db.persons.upsert(bob)

        let sarahFactA = makeFact(person: sarah.id, text: "Sarah fact A")
        let sarahFactB = makeFact(person: sarah.id, text: "Sarah fact B")
        let bobsFact = makeFact(person: bob.id, text: "Bob's fact")
        try await db.profileFacts.upsert(sarahFactA)
        try await db.profileFacts.upsert(sarahFactB)
        try await db.profileFacts.upsert(bobsFact)

        let canned = """
        [{"op": "merge", \
        "fact_ids": ["\(sarahFactA.id.rawValue)", "\(bobsFact.id.rawValue)"], \
        "fact_id": null, "fact_text": "Hijacked", "fact_kind": "other", "confidence": 0.9, \
        "reason": null}]
        """
        let consolidation = makeConsolidation(db: db, cannedResponse: canned)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0)
        #expect(result.factsRetired == 0)
        // No cross-contamination — Bob's fact is untouched, no new pending replacement created.
        #expect(try await db.profileFacts.all().count == 3)
        let reloadedBob = try await db.profileFacts.find(bobsFact.id)
        #expect(reloadedBob?.factText == "Bob's fact")
    }

    @Test("A 'merge' with only 1 fact_id is rejected — that's not a merge")
    func mergeWithOnlyOneFactIdIsRejected() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        let factA = makeFact(person: sarah.id, text: "Fact A")
        let factB = makeFact(person: sarah.id, text: "Fact B")
        try await db.profileFacts.upsert(factA)
        try await db.profileFacts.upsert(factB)

        let canned = """
        [{"op": "merge", "fact_ids": ["\(factA.id.rawValue)"], "fact_id": null, \
        "fact_text": "Solo merge", "fact_kind": "other", "confidence": 0.5, "reason": null}]
        """
        let consolidation = makeConsolidation(db: db, cannedResponse: canned)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 0)
        #expect(try await db.profileFacts.all().count == 2)
    }

    @Test("Two ops referencing the same fact_id: the second reference is rejected, no double-count")
    func duplicateFactIdReferenceAcrossOpsRejectsSecond() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)
        let factA = makeFact(person: sarah.id, text: "Fact A")
        let factB = makeFact(person: sarah.id, text: "Fact B")
        let factC = makeFact(person: sarah.id, text: "Fact C")
        try await db.profileFacts.upsert(factA)
        try await db.profileFacts.upsert(factB)
        try await db.profileFacts.upsert(factC)

        // Two "merge" ops both reference factC — the first wins, the second (referencing factC
        // again) is rejected in full.
        let canned = """
        [{"op": "merge", "fact_ids": ["\(factA.id.rawValue)", "\(factC.id.rawValue)"], \
        "fact_id": null, "fact_text": "A merged with C", "fact_kind": "other", \
        "confidence": 0.6, "reason": null}, \
        {"op": "merge", "fact_ids": ["\(factB.id.rawValue)", "\(factC.id.rawValue)"], \
        "fact_id": null, "fact_text": "B merged with C again", "fact_kind": "other", \
        "confidence": 0.6, "reason": null}]
        """
        let consolidation = makeConsolidation(db: db, cannedResponse: canned)
        let result = try await consolidation.consolidateFacts(for: sarah.id)

        #expect(result.merged == 1)
        #expect(result.factsRetired == 2) // only the first merge's 2 facts, never double-counted
        let all = try await db.profileFacts.all()
        #expect(all.count == 4) // 3 old + 1 new
        // factB was never touched by the rejected second op.
        let reloadedB = try await db.profileFacts.find(factB.id)
        #expect(reloadedB?.status == .active)
        #expect(reloadedB?.factText == "Fact B")
    }
}
