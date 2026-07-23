//
//  RecallToolsTests.swift — plan §8 Slice B `RecallToolsTests` (`ask-meetings-tools-and-cards.md`).
//
//  Built on `AppDatabase.makeInMemory()` + real repositories (never a raw SQLite handle), mirroring
//  `PeopleContextTests`' fixture pattern for `Person`/`CalendarEvent`/`Attendee`.
//
import Foundation
import Testing
@testable import AriKit

@Suite("RecallTools — Slice B fixed tool set")
struct RecallToolsTests {
    private func makeTools(_ db: AppDatabase) -> RecallTools {
        RecallTools(
            meetings: db.meetings,
            persons: db.persons,
            series: db.series,
            calendarEvents: db.calendarEvents
        )
    }

    private func makeMeeting(
        id: String,
        title: String = "Fixture meeting",
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    private func makePerson(id: String, name: String, email: String? = nil) -> Person {
        Person(
            id: PersonID(id),
            email: email,
            displayName: name,
            isOwner: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - findPerson: nil for zero/multiple, real row for exactly one

    @Test("findPerson returns nil when no name matches")
    func findPersonReturnsNilForZeroMatches() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "p1", name: "Ada Lovelace"))
        let tools = makeTools(db)

        let result = try await tools.findPerson(nameContaining: "Sarah")
        #expect(result == nil)
    }

    @Test("findPerson returns nil when the query matches more than one person (ambiguity is never guessed)")
    func findPersonReturnsNilForMultipleMatches() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "p1", name: "Sarah Ammon"))
        try await db.persons.upsert(makePerson(id: "p2", name: "Sarah Chen"))
        let tools = makeTools(db)

        let result = try await tools.findPerson(nameContaining: "Sarah")
        #expect(result == nil)
    }

    @Test("findPerson resolves a single case-insensitive substring match")
    func findPersonResolvesUnambiguousMatch() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(makePerson(id: "p1", name: "Sarah Ammon"))
        try await db.persons.upsert(makePerson(id: "p2", name: "Grace Hopper"))
        let tools = makeTools(db)

        let result = try await tools.findPerson(nameContaining: "sarah")
        #expect(result?.id == PersonID("p1"))
    }

    // MARK: - findMeeting / findSeries: same ambiguity discipline

    @Test("findMeeting returns nil for zero or multiple title matches, resolves a single match")
    func findMeetingAmbiguityDiscipline() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting(id: "m1", title: "Q3 budget review"))
        try await db.meetings.upsert(makeMeeting(id: "m2", title: "Q3 budget planning"))
        let tools = makeTools(db)

        #expect(try await tools.findMeeting(titleContaining: "nonexistent") == nil)
        #expect(try await tools.findMeeting(titleContaining: "Q3 budget") == nil)
        let resolved = try await tools.findMeeting(titleContaining: "review")
        #expect(resolved?.id == MeetingID("m1"))
    }

    @Test("findSeries returns nil for zero or multiple title matches, resolves a single match")
    func findSeriesAmbiguityDiscipline() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.series.upsert(Series(
            id: SeriesID("s1"),
            title: "Design team sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await db.series.upsert(Series(
            id: SeriesID("s2"),
            title: "Design team retro",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let tools = makeTools(db)

        #expect(try await tools.findSeries(titleContaining: "nonexistent") == nil)
        #expect(try await tools.findSeries(titleContaining: "design team") == nil)
        let resolved = try await tools.findSeries(titleContaining: "sync")
        #expect(resolved?.id == SeriesID("s1"))
    }

    // MARK: - meetings(withPerson:) — calendar-attendee matching only, never fabricated

    @Test("meetings(withPerson:) returns only calendar-attendee-linked meetings, newest first")
    func meetingsWithPersonReturnsOnlyCalendarLinkedMeetings() async throws {
        let db = try AppDatabase.makeInMemory()
        let person = makePerson(id: "p1", name: "Sarah Ammon", email: "sarah@example.com")
        try await db.persons.upsert(person)

        let olderMeeting = makeMeeting(
            id: "m-older", title: "Older sync", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let newerMeeting = makeMeeting(
            id: "m-newer", title: "Newer sync", createdAt: Date(timeIntervalSince1970: 1_700_100_000)
        )
        let unlinkedMeeting = makeMeeting(id: "m-unlinked", title: "No attendee overlap")
        try await db.meetings.upsert(olderMeeting)
        try await db.meetings.upsert(newerMeeting)
        try await db.meetings.upsert(unlinkedMeeting)

        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-older"),
            calendarId: "cal-1",
            title: "Older sync",
            startTime: olderMeeting.createdAt,
            endTime: olderMeeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Sarah Ammon", email: "sarah@example.com")],
            meetingId: olderMeeting.id,
            linkSource: .calendar
        ))
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-newer"),
            calendarId: "cal-1",
            title: "Newer sync",
            startTime: newerMeeting.createdAt,
            endTime: newerMeeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Sarah Ammon", email: "sarah@example.com")],
            meetingId: newerMeeting.id,
            linkSource: .calendar
        ))
        // An event with no matching attendee at all — never counted.
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("event-unlinked"),
            calendarId: "cal-1",
            title: "No attendee overlap",
            startTime: unlinkedMeeting.createdAt,
            endTime: unlinkedMeeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Someone Else", email: "someone@example.com")],
            meetingId: unlinkedMeeting.id,
            linkSource: .calendar
        ))

        let tools = makeTools(db)
        let result = try await tools.meetings(withPerson: person.id)
        #expect(result.map(\.id) == [newerMeeting.id, olderMeeting.id])
    }

    @Test("meetings(withPerson:) is empty (never fabricated) for a person with no calendar-linked meetings")
    func meetingsWithPersonEmptyWhenNoCalendarLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let person = makePerson(id: "p1", name: "No Calendar Person", email: "nocal@example.com")
        try await db.persons.upsert(person)
        try await db.meetings.upsert(makeMeeting(id: "m1", title: "Some meeting"))

        let tools = makeTools(db)
        let result = try await tools.meetings(withPerson: person.id)
        #expect(result.isEmpty)
    }

    @Test("meetings(withPerson:) is empty for a person with no email at all")
    func meetingsWithPersonEmptyWhenNoEmail() async throws {
        let db = try AppDatabase.makeInMemory()
        let person = makePerson(id: "p1", name: "No Email Person", email: nil)
        try await db.persons.upsert(person)

        let tools = makeTools(db)
        let result = try await tools.meetings(withPerson: person.id)
        #expect(result.isEmpty)
    }

    // MARK: - meetings(inSeries:limit:) — respects limit + newest-first ordering

    @Test("meetings(inSeries:limit:) respects the limit and orders newest first")
    func meetingsInSeriesRespectsLimitAndOrdering() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-1"),
            title: "Weekly sync",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)

        var meetingIds: [MeetingID] = []
        for index in 0 ..< 5 {
            let meeting = makeMeeting(
                id: "m\(index)",
                title: "Occurrence \(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)
            )
            try await db.meetings.upsert(meeting)
            try await db.series.addMember(seriesId: series.id, meetingId: meeting.id)
            meetingIds.append(meeting.id)
        }

        let tools = makeTools(db)
        let limited = try await tools.meetings(inSeries: series.id, limit: 2)
        // Newest first: occurrence 4, then occurrence 3.
        #expect(limited.map(\.id) == [MeetingID("m4"), MeetingID("m3")])

        let all = try await tools.meetings(inSeries: series.id, limit: 100)
        #expect(all.map(\.id) == meetingIds.reversed())
    }

    @Test("meetingCount(inSeries:) reports the TRUE total, not the limit-capped fetch count")
    func meetingCountInSeriesIsNeverCappedByAFetchLimit() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-big"),
            title: "Daily standup",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)

        // More members than a small `limit` passed to `meetings(inSeries:limit:)`, regression-
        // guarding against reporting `meetings(inSeries:limit:).count` as the "real" total (that
        // array is capped for bounded context, not an honest count — a No-Fake-State violation if
        // ever used as one).
        for index in 0 ..< 7 {
            let meeting = makeMeeting(
                id: "m\(index)",
                title: "Standup \(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)
            )
            try await db.meetings.upsert(meeting)
            try await db.series.addMember(seriesId: series.id, meetingId: meeting.id)
        }

        let tools = makeTools(db)
        let cappedFetch = try await tools.meetings(inSeries: series.id, limit: 2)
        #expect(cappedFetch.count == 2)

        let realTotal = try await tools.meetingCount(inSeries: series.id)
        #expect(realTotal == 7)
    }

    @Test("meetings(inSeries:limit:) is empty for a series with no members")
    func meetingsInSeriesEmptyWhenNoMembers() async throws {
        let db = try AppDatabase.makeInMemory()
        let series = Series(
            id: SeriesID("series-empty"),
            title: "Empty series",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.series.upsert(series)

        let tools = makeTools(db)
        let result = try await tools.meetings(inSeries: series.id, limit: 10)
        #expect(result.isEmpty)
    }
}
