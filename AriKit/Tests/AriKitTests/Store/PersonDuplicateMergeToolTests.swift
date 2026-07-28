//
//  PersonDuplicateMergeToolTests.swift — `PersonDuplicateMergeTool` (docs/plans/
//  duplicate-person-merge.md), the dry-run-first, name-matched owner/duplicate finder that sits
//  in front of `PersonRepository.merge(duplicateId:into:)`.
//
import Foundation
import Testing
@testable import AriKit

@Suite("PersonDuplicateMergeTool")
struct PersonDuplicateMergeToolTests {
    private func makePerson(
        id: String, displayName: String, email: String? = nil, isOwner: Bool = false
    ) -> Person {
        Person(
            id: PersonID(id), email: email, displayName: displayName, isOwner: isOwner,
            createdAt: ModelSamples.instant, updatedAt: ModelSamples.instant
        )
    }

    @Test("noOwner when no owner is set")
    func noOwnerOutcome() async throws {
        let db = try AppDatabase.makeInMemory()
        let outcome = try await PersonDuplicateMergeTool(database: db).planOwnerDuplicateMerge()
        #expect(outcome == .noOwner)
    }

    @Test("noCandidates when no non-owner person shares the owner's name")
    func noCandidatesOutcome() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true))
        try await db.persons.upsert(makePerson(id: "amy", displayName: "Amy Teuscher"))

        let outcome = try await PersonDuplicateMergeTool(database: db).planOwnerDuplicateMerge()
        #expect(outcome == .noCandidates)
    }

    @Test("ambiguous when MORE THAN ONE non-owner person shares the owner's name — never guesses")
    func ambiguousOutcome() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true))
        try await db.persons.upsert(makePerson(id: "dup-1", displayName: "Paul Fox-Reeks", email: "a@x.com"))
        try await db.persons.upsert(makePerson(id: "dup-2", displayName: "paul fox-reeks", email: "b@x.com"))

        let outcome = try await PersonDuplicateMergeTool(database: db).planOwnerDuplicateMerge()
        guard case let .ambiguous(ids) = outcome else {
            Issue.record("expected .ambiguous, got \(outcome)")
            return
        }
        #expect(Set(ids) == Set([PersonID("dup-1"), PersonID("dup-2")]))

        // mergeOwnerDuplicate() must refuse to guess too — surfaces the same ambiguity as a thrown error.
        await #expect(throws: PersonDuplicateMergeToolError.ambiguousCandidates([
            PersonID("dup-1"),
            PersonID("dup-2")
        ])) {
            _ = try await PersonDuplicateMergeTool(database: db).mergeOwnerDuplicate()
        }
    }

    @Test("Reports exact counts for a real duplicate (matches the live-DB shape this tool repairs)")
    func readyReportCounts() async throws {
        let db = try AppDatabase.makeInMemory()
        let owner = makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul Fox-Reeks", email: "paul.foxreeks@arivo.com")
        try await db.persons.upsert(owner)
        try await db.persons.upsert(duplicate)

        try await db.meetings.upsert(ModelSamples.meeting)
        let secondMeeting = Meeting(
            id: "meeting-2", title: "Another meeting",
            createdAt: ModelSamples.instant, updatedAt: ModelSamples.instant
        )
        try await db.meetings.upsert(secondMeeting)

        // One meeting where ONLY the duplicate is linked (a clean move), one where BOTH are
        // linked (a collision the merge must drop, not double up).
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: duplicate.id)
        try await db.persons.addParticipant(meetingId: secondMeeting.id, personId: owner.id, linkSource: "speaker")
        try await db.persons.addParticipant(meetingId: secondMeeting.id, personId: duplicate.id, linkSource: "calendar")

        var fact1 = ModelSamples.profileFact
        fact1.personId = duplicate.id
        try await db.profileFacts.upsert(fact1)
        var fact2 = ModelSamples.profileFact
        fact2.id = "fact-2"
        fact2.personId = duplicate.id
        try await db.profileFacts.upsert(fact2)

        let outcome = try await PersonDuplicateMergeTool(database: db).planOwnerDuplicateMerge()
        guard case let .ready(report) = outcome else {
            Issue.record("expected .ready, got \(outcome)")
            return
        }

        #expect(report.ownerId == owner.id)
        #expect(report.duplicateId == duplicate.id)
        #expect(report.duplicateEmail == "paul.foxreeks@arivo.com")
        #expect(report.ownerEmailBefore == nil)
        #expect(report.profileFactsToMove == 2)
        #expect(report.participantLinksToMove == 1, "meeting-1: only the duplicate is linked")
        #expect(report.participantLinksToDrop == 1, "meeting-2: both are linked, the owner's row wins")
        #expect(report.speakersToMove == 0)
        #expect(report.seriesToRepoint == 0)

        // Planning must never write anything.
        #expect(try await db.persons.all().count == 2)
    }

    @Test("mergeOwnerDuplicate() commits exactly what planOwnerDuplicateMerge() reported")
    func mergeCommitsThePlan() async throws {
        let db = try AppDatabase.makeInMemory()
        let owner = makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul Fox-Reeks", email: "paul.foxreeks@arivo.com")
        try await db.persons.upsert(owner)
        try await db.persons.upsert(duplicate)
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: duplicate.id)
        var fact = ModelSamples.profileFact
        fact.personId = duplicate.id
        try await db.profileFacts.upsert(fact)

        let merged = try await PersonDuplicateMergeTool(database: db).mergeOwnerDuplicate()

        #expect(merged?.id == owner.id)
        #expect(merged?.email == "paul.foxreeks@arivo.com")
        #expect(try await db.persons.find(duplicate.id) == nil)
        #expect(try await db.persons.all().count == 1)
        let movedFact = try await db.profileFacts.find(fact.id)
        #expect(movedFact?.personId == owner.id)
    }

    @Test("mergeOwnerDuplicate() is nil (no-op) when there's nothing to merge")
    func mergeNoOpWhenNothingToDo() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true))

        let result = try await PersonDuplicateMergeTool(database: db).mergeOwnerDuplicate()
        #expect(result == nil)
        #expect(try await db.persons.all().count == 1)
    }
}
