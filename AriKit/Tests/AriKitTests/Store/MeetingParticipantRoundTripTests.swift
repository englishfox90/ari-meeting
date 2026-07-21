//
//  MeetingParticipantRoundTripTests.swift — `PersonRepository`'s participant-roster methods
//  (Phase 3.4 Track H, `arikit-engine-extras.md` §2.3/§2.6/§6-5, ← `list_participants`/
//  `link_participant`, `person.rs:348-385`).
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Round-trip fidelity — meetingParticipant (PersonRepository participant roster)")
struct MeetingParticipantRoundTripTests {
    private func makePerson(id: String, displayName: String) -> Person {
        Person(
            id: PersonID(id),
            displayName: displayName,
            isOwner: false,
            createdAt: ModelSamples.instant,
            updatedAt: ModelSamples.instant
        )
    }

    @Test("addParticipant links a person; participants(inMeeting:) lists them alphabetically")
    func addParticipantAndList() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let zed = makePerson(id: "person-zed", displayName: "Zed")
        let anna = makePerson(id: "person-anna", displayName: "Anna")
        try await db.persons.upsert(zed)
        try await db.persons.upsert(anna)

        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: zed.id)
        try await db.persons.addParticipant(
            meetingId: ModelSamples.meeting.id, personId: anna.id, linkSource: "calendar"
        )

        let participants = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(participants.map(\.displayName) == ["Anna", "Zed"])
    }

    @Test("addParticipant is idempotent (INSERT OR IGNORE — re-linking the same pair is a no-op)")
    func addParticipantIsIdempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let person = makePerson(id: "person-1", displayName: "Person One")
        try await db.persons.upsert(person)

        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)

        let participants = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(participants.count == 1)
    }

    @Test("removeParticipant unlinks a person and reports whether a row was removed")
    func removeParticipant() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let person = makePerson(id: "person-1", displayName: "Person One")
        try await db.persons.upsert(person)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)

        let removed = try await db.persons.removeParticipant(
            meetingId: ModelSamples.meeting.id, personId: person.id
        )
        #expect(removed)
        let participants = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(participants.isEmpty)

        let removedAgain = try await db.persons.removeParticipant(
            meetingId: ModelSamples.meeting.id, personId: person.id
        )
        #expect(!removedAgain)
    }

    @Test("participants(inMeeting:) excludes a soft-deleted person")
    func participantsExcludeSoftDeletedPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let person = makePerson(id: "person-1", displayName: "Person One")
        try await db.persons.upsert(person)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)

        try await db.persons.softDelete(person.id, at: Date())

        let participants = try await db.persons.participants(inMeeting: ModelSamples.meeting.id)
        #expect(participants.isEmpty)
    }

    @Test("Deleting a meeting cascades to its meetingParticipant rows (FK ON DELETE CASCADE)")
    func meetingParticipantCascadeDeleteOnMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let person = makePerson(id: "person-1", displayName: "Person One")
        try await db.persons.upsert(person)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [ModelSamples.meeting.id.rawValue])
        }

        let count = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM meetingParticipant") ?? -1
        }
        #expect(count == 0)
    }

    @Test("Deleting a person cascades to their meetingParticipant rows (FK ON DELETE CASCADE)")
    func meetingParticipantCascadeDeleteOnPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let person = makePerson(id: "person-1", displayName: "Person One")
        try await db.persons.upsert(person)
        try await db.persons.addParticipant(meetingId: ModelSamples.meeting.id, personId: person.id)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM person WHERE id = ?", arguments: [person.id.rawValue])
        }

        let count = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM meetingParticipant") ?? -1
        }
        #expect(count == 0)
    }
}
