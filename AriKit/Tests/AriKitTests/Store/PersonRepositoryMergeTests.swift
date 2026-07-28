//
//  PersonRepositoryMergeTests.swift — `PersonRepository.merge(duplicateId:into:)`
//  (docs/plans/duplicate-person-merge.md).
//
//  General-purpose duplicate merge, distinct from `saveOwner`'s narrower email-collision path
//  (`OwnerSaveMergeTests`): re-homes every FK the schema knows about (`meetingParticipant`,
//  `profileFact`, `speaker`, `series.ownerPersonId`), carries missing identity fields onto the
//  survivor, and is safe to call twice (idempotent).
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("PersonRepository.merge(duplicateId:into:)")
struct PersonRepositoryMergeTests {
    private func makePerson(
        id: String,
        displayName: String,
        email: String? = nil,
        role: String? = nil,
        organization: String? = nil,
        domain: String? = nil,
        notes: String? = nil,
        isOwner: Bool = false
    ) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: displayName,
            role: role,
            organization: organization,
            domain: domain,
            notes: notes,
            isOwner: isOwner,
            createdAt: ModelSamples.instant,
            updatedAt: ModelSamples.instant
        )
    }

    @Test("Moves profileFact, speaker, and series.ownerPersonId references onto the survivor")
    func movesAllFourReferenceKinds() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)

        let survivor = makePerson(id: "owner", displayName: "Paul Fox-Reeks", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul Fox-Reeks", email: "paul@arivo.com")
        try await db.persons.upsert(survivor)
        try await db.persons.upsert(duplicate)

        try await db.persons.addParticipant(
            meetingId: ModelSamples.meeting.id, personId: duplicate.id, linkSource: "calendar"
        )

        var fact = ModelSamples.profileFact
        fact.personId = duplicate.id
        try await db.profileFacts.upsert(fact)

        var speaker = ModelSamples.speaker
        speaker.personId = duplicate.id
        try await db.speakers.upsert(speaker)

        var series = ModelSamples.series
        series.ownerPersonId = duplicate.id
        try await db.series.upsert(series)

        let merged = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)

        #expect(merged.id == survivor.id)
        #expect(merged.email == "paul@arivo.com", "the survivor carries the duplicate's email")

        // The duplicate is gone.
        #expect(try await db.persons.find(duplicate.id) == nil)
        #expect(try await db.persons.all().count == 1)

        // Every reference re-points to the survivor.
        let links = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(links.map(\.id) == [survivor.id])

        let movedFact = try await db.profileFacts.find(fact.id)
        #expect(movedFact?.personId == survivor.id)

        let movedSpeaker = try await db.speakers.find(speaker.id)
        #expect(movedSpeaker?.personId == survivor.id)

        let movedSeries = try await db.series.find(series.id)
        #expect(movedSeries?.ownerPersonId == survivor.id)
    }

    @Test("Overlapping meetingParticipant links: the SURVIVOR's row wins, the duplicate's is dropped")
    func collisionSurvivorWins() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)

        let survivor = makePerson(id: "owner", displayName: "Paul", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul", email: "paul@arivo.com")
        try await db.persons.upsert(survivor)
        try await db.persons.upsert(duplicate)

        // Both already linked to the SAME meeting — survivor via a more-specific "speaker" link,
        // duplicate via a calendar link. The survivor's row (and its linkSource) must win.
        try await db.persons.addParticipant(
            meetingId: ModelSamples.meeting.id, personId: survivor.id, linkSource: "speaker"
        )
        try await db.persons.addParticipant(
            meetingId: ModelSamples.meeting.id, personId: duplicate.id, linkSource: "calendar"
        )

        _ = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)

        let links = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(links.map(\.id) == [survivor.id])
        #expect(try await db.persons.all().count == 1)
    }

    @Test("Never overwrites a survivor field that's already set — only fills in the missing ones")
    func neverOverwritesExistingFields() async throws {
        let db = try AppDatabase.makeInMemory()
        let survivor = makePerson(id: "owner", displayName: "Paul", role: "Founder", isOwner: true)
        let duplicate = makePerson(
            id: "dup", displayName: "Paul", email: "paul@arivo.com",
            role: "Attendee", organization: "Arivo", domain: "arivo.com", notes: "met at a conference"
        )
        try await db.persons.upsert(survivor)
        try await db.persons.upsert(duplicate)

        let merged = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)

        #expect(merged.role == "Founder", "the survivor's existing role is preserved, not overwritten")
        #expect(merged.email == "paul@arivo.com", "email was missing on the survivor, so it's carried over")
        #expect(merged.organization == "Arivo")
        #expect(merged.domain == "arivo.com")
        #expect(merged.notes == "met at a conference")
    }

    @Test("The duplicate's email is cleared before the survivor's is set — UNIQUE(email) never trips")
    func neverTripsEmailUniqueConstraint() async throws {
        let db = try AppDatabase.makeInMemory()
        let survivor = makePerson(id: "owner", displayName: "Paul", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul", email: "paul@arivo.com")
        try await db.persons.upsert(survivor)
        try await db.persons.upsert(duplicate)

        // Would throw `SQLITE_CONSTRAINT` if the merge ever briefly held the same email on two rows.
        _ = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)

        let owner = try await db.persons.find(survivor.id)
        #expect(owner?.email == "paul@arivo.com")
    }

    @Test("No-ops (returns the survivor unchanged) when duplicateId == survivorId")
    func noOpOnSameID() async throws {
        let db = try AppDatabase.makeInMemory()
        let person = makePerson(id: "owner", displayName: "Paul", email: "paul@arivo.com", isOwner: true)
        try await db.persons.upsert(person)

        let merged = try await db.persons.merge(duplicateId: person.id, into: person.id)
        #expect(merged.id == person.id)
        #expect(merged.email == "paul@arivo.com")
        #expect(try await db.persons.all().count == 1)
    }

    @Test("Idempotent: re-running after the duplicate is already gone is a safe no-op")
    func idempotentReRun() async throws {
        let db = try AppDatabase.makeInMemory()
        let survivor = makePerson(id: "owner", displayName: "Paul", isOwner: true)
        let duplicate = makePerson(id: "dup", displayName: "Paul", email: "paul@arivo.com")
        try await db.persons.upsert(survivor)
        try await db.persons.upsert(duplicate)

        _ = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)
        // Second call: `duplicate.id` no longer exists.
        let secondResult = try await db.persons.merge(duplicateId: duplicate.id, into: survivor.id)

        #expect(secondResult.id == survivor.id)
        #expect(secondResult.email == "paul@arivo.com")
        #expect(try await db.persons.all().count == 1)
    }

    @Test("Throws personNotFound when the survivor doesn't exist")
    func throwsWhenSurvivorMissing() async throws {
        let db = try AppDatabase.makeInMemory()
        let duplicate = makePerson(id: "dup", displayName: "Paul")
        try await db.persons.upsert(duplicate)

        await #expect(throws: PersonRepositoryError.personNotFound(PersonID("missing"))) {
            _ = try await db.persons.merge(duplicateId: duplicate.id, into: PersonID("missing"))
        }
    }
}
