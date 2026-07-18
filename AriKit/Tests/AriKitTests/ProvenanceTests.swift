//
//  ProvenanceTests.swift — plan §5 test 5.
//
//  The provenance / never-invents-citations data-level invariant (plan §6): an inferred
//  `ProfileFact` carries its origin, source refs, timestamp, and confidence; a multi-entry
//  `[ProfileFactSource]` lineage records origin + reaffirmation + carried-forward corroboration;
//  and the `supersededBy` pointer models a resolvable supersession chain.
//
import Foundation
import Testing
@testable import AriKit

@Suite struct ProvenanceTests {
    @Test func inferredFactCarriesProvenance() {
        let fact = ModelSamples.profileFact
        #expect(fact.origin == .selfReported)
        #expect(fact.sourceMeetingId == MeetingID("meeting-1"))
        #expect(fact.sourceSegmentRef == "seg:3.0-5.5")
        #expect(fact.confidence == 0.82)
        #expect(fact.sourceCount == 2)
    }

    @Test func unsourcedInferredFactIsExpressible() {
        // A fact with no source refs is representable (nullable provenance) while still typed.
        let fact = ProfileFact(
            id: "fact-x",
            personId: "person-1",
            factText: "Manually added.",
            factKind: .other,
            origin: .attributed,
            confidence: 1.0,
            sourceCount: 0,
            status: .active,
            createdAt: ModelSamples.instant
        )
        #expect(fact.sourceMeetingId == nil)
        #expect(fact.sourceSegmentRef == nil)
        #expect(fact.sourceCount == 0)
    }

    @Test func multiEntryLineageRecordsAllRelations() {
        let base = ModelSamples.profileFactSource
        let sources: [ProfileFactSource] = [
            base,
            ProfileFactSource(
                id: "factsource-2",
                factId: "fact-1",
                meetingId: "meeting-2",
                origin: .attributed,
                relation: .reaffirmed,
                confidence: 0.7,
                observedAt: ModelSamples.laterInstant
            ),
            ProfileFactSource(
                id: "factsource-3",
                factId: "fact-1",
                origin: .attributed,
                relation: .carried,
                confidence: 0.5,
                observedAt: ModelSamples.laterInstant
            )
        ]
        let relations = sources.map(\.relation)
        #expect(relations == [.origin, .reaffirmed, .carried])

        let aggregate = ProfileFactWithProvenance(fact: ModelSamples.profileFact, sources: sources)
        #expect(aggregate.sources.count == 3)
    }

    @Test func twoHopSupersessionChainResolves() {
        // fact-1 → fact-2 → fact-3 (current). Walk the `supersededBy` pointers to the terminal.
        let f1 = makeFact(id: "fact-1", supersededBy: "fact-2", status: .superseded)
        let f2 = makeFact(id: "fact-2", supersededBy: "fact-3", status: .superseded)
        let f3 = makeFact(id: "fact-3", supersededBy: nil, status: .active)
        let byID: [ProfileFactID: ProfileFact] = [f1.id: f1, f2.id: f2, f3.id: f3]

        let terminal = resolveSupersession(from: f1, in: byID)
        #expect(terminal.id == f3.id)
        #expect(terminal.status == .active)
        #expect(terminal.supersededBy == nil)
    }

    // MARK: - Helpers

    private func makeFact(
        id: ProfileFactID,
        supersededBy: ProfileFactID?,
        status: FactStatus
    ) -> ProfileFact {
        ProfileFact(
            id: id,
            personId: "person-1",
            factText: "fact \(id.rawValue)",
            factKind: .project,
            origin: .selfReported,
            confidence: 0.8,
            sourceCount: 1,
            status: status,
            supersededBy: supersededBy,
            createdAt: ModelSamples.instant
        )
    }

    /// Walks the supersession chain to the fact no longer superseded by anything.
    private func resolveSupersession(
        from start: ProfileFact,
        in facts: [ProfileFactID: ProfileFact]
    ) -> ProfileFact {
        var current = start
        var visited: Set<ProfileFactID> = [current.id]
        while let next = current.supersededBy, let node = facts[next], !visited.contains(next) {
            visited.insert(next)
            current = node
        }
        return current
    }
}
