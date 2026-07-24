//
//  ProfileFactRepositorySupersessionTests.swift — docs/plans/person-fact-consolidation.md §10
//  step 2: a focused repository-level test for `recordSupersession` + the extended `confirmFact`
//  behavior, independent of the `PersonFactConsolidation` engine layer above it.
//
import Foundation
import Testing
@testable import AriKit

@Suite("ProfileFactRepository — supersession (person-fact-consolidation plan)")
struct ProfileFactRepositorySupersessionTests {
    private func makePerson(id: String = "person-sarah") -> Person {
        Person(
            id: PersonID(id),
            email: "sarah@example.com",
            displayName: "Sarah",
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeFact(person: PersonID, text: String, status: FactStatus = .active) -> ProfileFact {
        ProfileFact(
            id: ProfileFactID(UUID().uuidString),
            personId: person,
            factText: text,
            factKind: .other,
            origin: .attributed,
            confidence: 0.5,
            sourceCount: 0,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("recordSupersession inserts one row per oldFactId, readable via oldFactIds(supersededBy:)")
    func recordSupersessionInsertsOneRowPerOldFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)

        let oldA = makeFact(person: sarah.id, text: "Old A")
        let oldB = makeFact(person: sarah.id, text: "Old B")
        let oldC = makeFact(person: sarah.id, text: "Old C")
        let newFact = makeFact(person: sarah.id, text: "New consolidated fact", status: .pending)
        try await db.profileFacts.upsert(oldA)
        try await db.profileFacts.upsert(oldB)
        try await db.profileFacts.upsert(oldC)
        try await db.profileFacts.upsert(newFact)

        try await db.profileFacts.recordSupersession(
            newFactId: newFact.id, oldFactIds: [oldA.id, oldB.id, oldC.id]
        )

        let recorded = try await db.profileFacts.oldFactIds(supersededBy: newFact.id)
        #expect(Set(recorded) == Set([oldA.id, oldB.id, oldC.id]))
    }

    @Test("confirmFact retires EVERY profileFactSupersession-linked old fact, not just one")
    func confirmFactRetiresEveryLinkedOldFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)

        let oldA = makeFact(person: sarah.id, text: "Old A")
        let oldB = makeFact(person: sarah.id, text: "Old B")
        let oldC = makeFact(person: sarah.id, text: "Old C")
        let newFact = makeFact(person: sarah.id, text: "New consolidated fact", status: .pending)
        try await db.profileFacts.upsert(oldA)
        try await db.profileFacts.upsert(oldB)
        try await db.profileFacts.upsert(oldC)
        try await db.profileFacts.upsert(newFact)
        try await db.profileFacts.recordSupersession(
            newFactId: newFact.id, oldFactIds: [oldA.id, oldB.id, oldC.id]
        )

        // Before confirm: all 3 old facts stay untouched (deferred supersession).
        for oldId in [oldA.id, oldB.id, oldC.id] {
            let reloaded = try await db.profileFacts.find(oldId)
            #expect(reloaded?.status == .active)
            #expect(reloaded?.supersededBy == nil)
        }

        try await db.profileFacts.confirmFact(newFact.id)

        let reloadedNew = try #require(try await db.profileFacts.find(newFact.id))
        #expect(reloadedNew.status == .active)
        for oldId in [oldA.id, oldB.id, oldC.id] {
            let reloaded = try await db.profileFacts.find(oldId)
            #expect(reloaded?.status == .superseded)
            #expect(reloaded?.supersededBy == newFact.id)
        }
    }

    @Test("confirmFact's single-column supersedesFactId path is unaffected when there are no join rows")
    func confirmFactSingleColumnPathStillWorksWithNoJoinRows() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)

        let old = makeFact(person: sarah.id, text: "Old fact")
        let new = makeFact(person: sarah.id, text: "New fact", status: .pending)
        try await db.profileFacts.upsert(old)
        try await db.profileFacts.upsert(new)
        try await db.profileFacts.markSupersedes(newFactId: new.id, oldFactId: old.id)

        try await db.profileFacts.confirmFact(new.id)

        let reloadedOld = try await db.profileFacts.find(old.id)
        #expect(reloadedOld?.status == .superseded)
        #expect(reloadedOld?.supersededBy == new.id)

        // No profileFactSupersession rows exist for this fact — the new join-table lookup was a
        // no-op, exactly as the plan documents both paths coexisting.
        let recorded = try await db.profileFacts.oldFactIds(supersededBy: new.id)
        #expect(recorded.isEmpty)
    }

    @Test("confirmFact cascades through a chained merge, retiring a never-confirmed intermediate's own targets")
    func confirmFactCascadesThroughChainedMerge() async throws {
        let db = try AppDatabase.makeInMemory()
        let sarah = makePerson()
        try await db.persons.upsert(sarah)

        // Round 1: A, B, C merge into pending fact M.
        let oldA = makeFact(person: sarah.id, text: "Old A")
        let oldB = makeFact(person: sarah.id, text: "Old B")
        let oldC = makeFact(person: sarah.id, text: "Old C")
        let factM = makeFact(person: sarah.id, text: "Merged M", status: .pending)
        try await db.profileFacts.upsert(oldA)
        try await db.profileFacts.upsert(oldB)
        try await db.profileFacts.upsert(oldC)
        try await db.profileFacts.upsert(factM)
        try await db.profileFacts.recordSupersession(
            newFactId: factM.id, oldFactIds: [oldA.id, oldB.id, oldC.id]
        )

        // Round 2 (before M is ever confirmed): M merges with an independent fact D into pending N.
        let factD = makeFact(person: sarah.id, text: "Old D")
        let factN = makeFact(person: sarah.id, text: "Merged N", status: .pending)
        try await db.profileFacts.upsert(factD)
        try await db.profileFacts.upsert(factN)
        try await db.profileFacts.recordSupersession(
            newFactId: factN.id, oldFactIds: [factM.id, factD.id]
        )

        try await db.profileFacts.confirmFact(factN.id)

        let reloadedN = try #require(try await db.profileFacts.find(factN.id))
        #expect(reloadedN.status == .active)

        let reloadedM = try #require(try await db.profileFacts.find(factM.id))
        #expect(reloadedM.status == .superseded)
        #expect(reloadedM.supersededBy == factN.id)

        let reloadedD = try #require(try await db.profileFacts.find(factD.id))
        #expect(reloadedD.status == .superseded)
        #expect(reloadedD.supersededBy == factN.id)

        // The critical assertion: A, B, C — only ever recorded against M — are now retired too,
        // each pointing at its IMMEDIATE superseder M, not the ultimate root N.
        for oldId in [oldA.id, oldB.id, oldC.id] {
            let reloaded = try await db.profileFacts.find(oldId)
            #expect(reloaded?.status == .superseded)
            #expect(reloaded?.supersededBy == factM.id)
        }

        // supersedeChain still walks the full chain to its terminal fact via the immediate pointers.
        let chain = try await db.profileFacts.supersedeChain(from: oldA.id)
        #expect(chain.map(\.id) == [oldA.id, factM.id, factN.id])
    }
}
