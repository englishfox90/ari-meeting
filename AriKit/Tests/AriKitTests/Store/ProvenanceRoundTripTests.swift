//
//  ProvenanceRoundTripTests.swift — plan §7 test 4.
//
//  Persists a `ProfileFact` + a multi-entry `[ProfileFactSource]` lineage, reads it back via
//  `ProfileFactRepository.withProvenance(_:)`, and asserts:
//  1. the read-time `sourceCount` matches a real `COUNT(*)` over `profileFactSource` (No-Fake-
//     State — plan §0.1/§4.6: never a stored, driftable column);
//  2. `supersedeChain(from:)` walks `supersededBy` to the terminal (currently active) fact.
//
import Foundation
import Testing
@testable import AriKit

@Suite("Provenance round-trip — profileFact + profileFactSource")
struct ProvenanceRoundTripTests {
    @Test("withProvenance composes a fact with its full source lineage")
    func withProvenanceComposesLineage() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)

        var fact = ModelSamples.profileFact
        fact.sourceCount = 0 // never trust the in-memory value; the repository recomputes it
        try await db.profileFacts.upsert(fact)

        let origin = ModelSamples.profileFactSource
        let reaffirmed = ProfileFactSource(
            id: "factsource-2",
            factId: fact.id,
            meetingId: "meeting-1",
            origin: .attributed,
            relation: .reaffirmed,
            confidence: 0.7,
            observedAt: ModelSamples.laterInstant
        )
        try await db.profileFacts.recordSource(origin)
        try await db.profileFacts.recordSource(reaffirmed)

        let withProvenance = try await db.profileFacts.withProvenance(fact.id)
        #expect(withProvenance != nil)
        #expect(withProvenance?.sources.count == 2)
        #expect(withProvenance?.sources.map(\.relation) == [.origin, .reaffirmed])
    }

    @Test("read-time sourceCount matches a real COUNT(*) over profileFactSource")
    func sourceCountMatchesRealCount() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)

        var fact = ModelSamples.profileFact
        fact.sourceCount = 999 // deliberately wrong — proves the repository ignores this value
        try await db.profileFacts.upsert(fact)

        try await db.profileFacts.recordSource(ModelSamples.profileFactSource)
        try await db.profileFacts.recordSource(ProfileFactSource(
            id: "factsource-2",
            factId: fact.id,
            origin: .attributed,
            relation: .carried,
            confidence: 0.5,
            observedAt: ModelSamples.laterInstant
        ))

        let fetched = try await db.profileFacts.find(fact.id)
        #expect(fetched?.sourceCount == 2)

        // The independently-computed count, asserted equal to the repository's read-time value.
        let factID = fact.id.rawValue
        let rawCount = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(
                rawDb,
                sql: "SELECT COUNT(*) FROM profileFactSource WHERE factId = ?",
                arguments: [factID]
            ) ?? 0
        }
        #expect(fetched?.sourceCount == rawCount)
    }

    @Test("supersedeChain walks supersededBy to the terminal (currently active) fact")
    func supersedeChainWalksToTerminal() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)

        let f3 = ProfileFact(
            id: "fact-3",
            personId: ModelSamples.person.id,
            factText: "Leads the migration project (current).",
            factKind: .project,
            origin: .selfReported,
            confidence: 0.9,
            sourceCount: 0,
            status: .active,
            supersededBy: nil,
            createdAt: ModelSamples.laterInstant
        )
        let f2 = ProfileFact(
            id: "fact-2",
            personId: ModelSamples.person.id,
            factText: "Leads the migration project (superseded once).",
            factKind: .project,
            origin: .selfReported,
            confidence: 0.85,
            sourceCount: 0,
            status: .superseded,
            supersededBy: f3.id,
            createdAt: ModelSamples.instant
        )
        let f1 = ProfileFact(
            id: "fact-1",
            personId: ModelSamples.person.id,
            factText: "Leads the migration project (original).",
            factKind: .project,
            origin: .selfReported,
            confidence: 0.8,
            sourceCount: 0,
            status: .superseded,
            supersededBy: f2.id,
            createdAt: ModelSamples.instant
        )
        // Insertion order is terminal-first: `supersededBy` is a real inline FK (not deferred),
        // so a row can only reference an already-existing parent at INSERT time.
        try await db.profileFacts.upsert(f3)
        try await db.profileFacts.upsert(f2)
        try await db.profileFacts.upsert(f1)

        let chain = try await db.profileFacts.supersedeChain(from: f1.id)
        #expect(chain.map(\.id) == [f1.id, f2.id, f3.id])
        #expect(chain.last?.status == .active)
        #expect(chain.last?.supersededBy == nil)
    }

    @Test("activeFacts scopes to status == .active, excluding superseded/tombstoned facts")
    func activeFactsScopesCorrectly() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)

        var active = ModelSamples.profileFact
        active.status = .active
        active.sourceMeetingId = nil
        active.sourceCount = 0
        var superseded = ModelSamples.profileFact
        superseded.id = "fact-superseded"
        superseded.status = .superseded
        superseded.sourceMeetingId = nil
        superseded.sourceCount = 0

        try await db.profileFacts.upsert(active)
        try await db.profileFacts.upsert(superseded)

        let facts = try await db.profileFacts.activeFacts(for: ModelSamples.person.id)
        #expect(facts.map(\.id) == [active.id])
    }
}
