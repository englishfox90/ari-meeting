//
//  StoredCalendarHintProviderTests.swift — plan §5, D3.
//
import Foundation
import Testing
@testable import AriKit

@Suite("StoredCalendarHintProvider")
struct StoredCalendarHintProviderTests {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(id: MeetingID) -> Meeting {
        Meeting(id: id, title: "Weekly sync", createdAt: instant, updatedAt: instant)
    }

    private func makePerson(id: PersonID, name: String) -> Person {
        Person(id: id, displayName: name, isOwner: false, createdAt: instant, updatedAt: instant)
    }

    private func makeCalendarEvent(
        id: CalendarEventID,
        meetingId: MeetingID,
        attendeeCount: Int
    ) -> CalendarEvent {
        CalendarEvent(
            id: id,
            calendarId: "cal-1",
            title: "Weekly sync",
            startTime: instant,
            endTime: instant.addingTimeInterval(1800),
            isAllDay: false,
            attendees: (0 ..< attendeeCount).map { Attendee(name: "Guest \($0)") },
            meetingId: meetingId,
            linkSource: .calendar
        )
    }

    @Test("participant count is preferred over attendee count when > 0 (parity-M1)")
    func participantCountPreferredOverAttendeeCount() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(makeMeeting(id: meetingId))

        // 3 linked participants...
        for index in 0 ..< 3 {
            let personId = PersonID("person-\(index)")
            try await db.persons.upsert(makePerson(id: personId, name: "Person \(index)"))
            try await db.persons.addParticipant(meetingId: meetingId, personId: personId)
        }
        // ...vs. 8 calendar attendees. Participants win.
        try await db.calendarEvents.upsert(
            makeCalendarEvent(id: "event-1", meetingId: meetingId, attendeeCount: 8)
        )

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try #require(await provider.hint(for: meetingId))
        #expect(resolved.hint == .upperBound(3))
        #expect(resolved.origin == .calendarAttendees)
    }

    @Test("attendee count is used when no participants are linked yet")
    func attendeeCountFallbackWhenNoParticipants() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-2"
        try await db.meetings.upsert(makeMeeting(id: meetingId))
        try await db.calendarEvents.upsert(
            makeCalendarEvent(id: "event-2", meetingId: meetingId, attendeeCount: 5)
        )

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try #require(await provider.hint(for: meetingId))
        #expect(resolved.hint == .upperBound(5))
        #expect(resolved.origin == .calendarAttendees)
    }

    @Test("attendee count above the band caps at 12")
    func attendeeCountAboveBandCaps() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-cap"
        try await db.meetings.upsert(makeMeeting(id: meetingId))
        try await db.calendarEvents.upsert(
            makeCalendarEvent(id: "event-cap", meetingId: meetingId, attendeeCount: 20)
        )

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try #require(await provider.hint(for: meetingId))
        #expect(resolved.hint == .upperBound(12))
    }

    @Test("no linked event and no participants → honest nil")
    func noSignalYieldsNil() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-3"
        try await db.meetings.upsert(makeMeeting(id: meetingId))

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try await provider.hint(for: meetingId)
        #expect(resolved == nil)
    }

    @Test("a single attendee is honestly reported as no signal (n >= 2 required)")
    func singleAttendeeYieldsNil() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-4"
        try await db.meetings.upsert(makeMeeting(id: meetingId))
        try await db.calendarEvents.upsert(
            makeCalendarEvent(id: "event-4", meetingId: meetingId, attendeeCount: 1)
        )

        let provider = StoredCalendarHintProvider(database: db)
        let resolved = try await provider.hint(for: meetingId)
        #expect(resolved == nil)
    }
}
