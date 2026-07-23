//
//  OwnerSaveMergeTests.swift — PersonRepository.saveOwner(_:at:) and its email-collision merge.
//
//  Regression cover for the silent owner-save failure: the owner is seeded once from the macOS
//  account name (no email) and the same human is imported once as a calendar attendee (with an
//  email), so a later owner edit that adds that email would hit `email UNIQUE`. saveOwner resolves
//  it by merging the colliding person into the owner rather than failing.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("PersonRepository.saveOwner — email-collision merge")
struct OwnerSaveMergeTests {
    private func makePerson(id: String, displayName: String, email: String?, isOwner: Bool) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: displayName,
            isOwner: isOwner,
            createdAt: ModelSamples.instant,
            updatedAt: ModelSamples.instant
        )
    }

    @Test("Saving the owner with an email held by another person merges that person into the owner")
    func mergesCollidingPersonIntoOwner() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)

        // The email-less owner seed + the email-keyed attendee that carries the meeting link.
        let ownerSeed = makePerson(id: "owner", displayName: "Paul Fox-Reeks", email: nil, isOwner: true)
        let attendee = makePerson(
            id: "attendee",
            displayName: "Paul Fox-Reeks",
            email: "paul@arivo.com",
            isOwner: false
        )
        try await db.persons.upsert(ownerSeed)
        try await db.persons.upsert(attendee)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: attendee.id)

        // Edit the owner to add the email the attendee already holds.
        var edited = ownerSeed
        edited.email = "paul@arivo.com"
        edited.role = "Founder"
        let saved = try await db.persons.saveOwner(edited)

        // Owner now carries the email + role, and is the SOLE owner.
        #expect(saved.email == "paul@arivo.com")
        #expect(saved.role == "Founder")
        let owner = try await db.persons.owner()
        #expect(owner?.id == ownerSeed.id)
        #expect(owner?.email == "paul@arivo.com")

        // The colliding attendee row is gone and its meeting link moved to the owner.
        #expect(try await db.persons.find(attendee.id) == nil)
        let links = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(links.map(\.id) == [ownerSeed.id])

        // Exactly one person remains.
        #expect(try await db.persons.all().count == 1)
    }

    @Test("Overlapping meeting participation is de-duplicated (no composite-PK clash)")
    func mergeHandlesOverlappingParticipation() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)

        let ownerSeed = makePerson(id: "owner", displayName: "Paul", email: nil, isOwner: true)
        let attendee = makePerson(id: "attendee", displayName: "Paul", email: "paul@arivo.com", isOwner: false)
        try await db.persons.upsert(ownerSeed)
        try await db.persons.upsert(attendee)
        // BOTH are linked to the same meeting — the PK-clash case.
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: ownerSeed.id)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: attendee.id)

        var edited = ownerSeed
        edited.email = "paul@arivo.com"
        _ = try await db.persons.saveOwner(edited)

        // The merge collapses the duplicate link to a single owner row for that meeting.
        let links = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(links.map(\.id) == [ownerSeed.id])
        #expect(try await db.persons.find(attendee.id) == nil)
    }

    @Test("Saving the owner with a fresh email (no collision) is a plain upsert")
    func noCollisionPlainSave() async throws {
        let db = try AppDatabase.makeInMemory()
        let ownerSeed = makePerson(id: "owner", displayName: "Paul", email: nil, isOwner: true)
        try await db.persons.upsert(ownerSeed)

        var edited = ownerSeed
        edited.email = "paul@arivo.com"
        edited.organization = "Arivo"
        let saved = try await db.persons.saveOwner(edited)

        #expect(saved.email == "paul@arivo.com")
        #expect(saved.organization == "Arivo")
        #expect(try await db.persons.all().count == 1)
        #expect(try await db.persons.owner()?.id == ownerSeed.id)
    }

    @Test("saveOwner enforces the single-owner invariant (any prior owner is unset)")
    func enforcesSingleOwner() async throws {
        let db = try AppDatabase.makeInMemory()
        let priorOwner = makePerson(id: "prior", displayName: "Old Owner", email: "old@arivo.com", isOwner: true)
        let newOwner = makePerson(id: "new", displayName: "New Owner", email: "new@arivo.com", isOwner: false)
        try await db.persons.upsert(priorOwner)
        try await db.persons.upsert(newOwner)

        _ = try await db.persons.saveOwner(newOwner)

        let owner = try await db.persons.owner()
        #expect(owner?.id == newOwner.id)
        // The prior owner still exists but is no longer flagged.
        let all = try await db.persons.all()
        #expect(all.filter(\.isOwner).map(\.id) == [newOwner.id])
    }
}
