//
//  DiarizationServiceLikelyAttendeesTests.swift —
//  docs/plans/speaker-retag-and-calendar-candidates.md §2 #3, §5, step 5.
//
import Foundation
import Testing
@testable import AriKit

@Suite("DiarizationService.likelyAttendees — calendar-candidate resolution (#3)")
struct DiarizationServiceLikelyAttendeesTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)
    private let embeddingModel = "fluidaudio-community-1"

    private func makeMeeting(_ id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Meeting \(id.rawValue)", createdAt: instant, updatedAt: instant)
    }

    private func makePerson(_ id: PersonID, email: String? = nil, name: String) -> Person {
        Person(id: id, email: email, displayName: name, isOwner: false, createdAt: instant, updatedAt: instant)
    }

    private func makeEvent(
        _ id: CalendarEventID, meetingId: MeetingID?, attendees: [Attendee]
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: "cal-1", title: "Standup", startTime: instant,
            endTime: instant.addingTimeInterval(1800), isAllDay: false, attendees: attendees,
            meetingId: meetingId
        )
    }

    private func makeService(db: AppDatabase) -> DiarizationService {
        DiarizationService(
            database: db,
            provider: StubDiarizationProvider(
                embeddingModel: embeddingModel,
                cannedOutput: DiarizationOutput(segments: [], clusters: [], embeddingModel: embeddingModel, dim: 2)
            ),
            audioLoader: StubDiarizationAudioLoader()
        )
    }

    @Test("resolves calendar-linked attendee emails to persons, read-only, without creating stubs")
    func likelyAttendeesResolvesCalendarEmailsReadOnly() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let nia: PersonID = "person-nia"
        let sean: PersonID = "person-sean"
        try await db.persons.upsert(makePerson(nia, email: "nia@example.com", name: "Nia"))
        try await db.persons.upsert(makePerson(sean, email: "sean@example.com", name: "Sean"))

        try await db.calendarEvents.upsert(makeEvent(
            "event-1", meetingId: meetingId,
            attendees: [
                Attendee(name: "Nia", email: "nia@example.com"),
                Attendee(name: "Sean", email: "sean@example.com")
            ]
        ))

        let personCountBefore = try await db.persons.all(includingDeleted: true).count

        let service = makeService(db: db)
        let likely = try await service.likelyAttendees(inMeeting: meetingId)

        #expect(Set(likely.map(\.id)) == [nia, sean])
        let personCountAfter = try await db.persons.all(includingDeleted: true).count
        #expect(personCountAfter == personCountBefore, "likelyAttendees must never create a person stub")
    }

    @Test("an unresolved attendee email is omitted, never fabricated into a stub")
    func unresolvedAttendeeIsOmittedNeverFabricated() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        try await db.calendarEvents.upsert(makeEvent(
            "event-1", meetingId: meetingId,
            attendees: [Attendee(name: "Ghost", email: "ghost@example.com")]
        ))

        let personCountBefore = try await db.persons.all(includingDeleted: true).count

        let service = makeService(db: db)
        let likely = try await service.likelyAttendees(inMeeting: meetingId)

        #expect(likely.isEmpty)
        let personCountAfter = try await db.persons.all(includingDeleted: true).count
        #expect(personCountAfter == personCountBefore)
    }

    @Test("unions already-linked participants not present in attendees, and dedups a person present in both")
    func likelyAttendeesUnionsParticipantsAndDedups() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let inBoth: PersonID = "person-both"
        let participantOnly: PersonID = "person-participant-only"
        try await db.persons.upsert(makePerson(inBoth, email: "both@example.com", name: "Both"))
        try await db.persons.upsert(makePerson(participantOnly, name: "Participant Only"))

        try await db.calendarEvents.upsert(makeEvent(
            "event-1", meetingId: meetingId,
            attendees: [Attendee(name: "Both", email: "both@example.com")]
        ))
        try await db.persons.addParticipant(meetingId: meetingId, personId: inBoth, at: instant)
        try await db.persons.addParticipant(meetingId: meetingId, personId: participantOnly, at: instant)

        let service = makeService(db: db)
        let likely = try await service.likelyAttendees(inMeeting: meetingId)

        #expect(Set(likely.map(\.id)) == [inBoth, participantOnly])
        #expect(Set(likely.map(\.id)).count == likely.count, "must be deduped by PersonID")
    }

    @Test("empty without a calendar link or linked participants (honest empty, no placeholder)")
    func likelyAttendeesEmptyWithoutCalendarLinkOrParticipants() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(meetingId))

        let service = makeService(db: db)
        let likely = try await service.likelyAttendees(inMeeting: meetingId)

        #expect(likely.isEmpty)
    }
}
