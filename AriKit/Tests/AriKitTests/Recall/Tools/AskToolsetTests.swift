//
//  AskToolsetTests.swift — plan §8.2 `AskToolsetTests` (`ask-meetings-agentic-tools.md`).
//
//  Built on `AppDatabase.makeInMemory()` + real repositories (never a raw SQLite handle), mirroring
//  `RecallToolsTests`'/`PeopleContextTests`' fixture pattern.
//
import Foundation
import Testing
@testable import AriKit

@Suite("AskToolset — the 6 tool-first Ask Meetings tools")
struct AskToolsetTests {
    private struct UnavailableEmbedder: RecallEmbedder {
        struct Unavailable: Error {}
        let modelTag = "unavailable"
        func embed(_: [String]) async throws -> [[Float]] {
            throw Unavailable()
        }
    }

    private func makeToolset(_ db: AppDatabase, allowedMeetingIds: Set<MeetingID>? = nil) -> AskToolset {
        AskToolset(
            tools: RecallTools(
                meetings: db.meetings, persons: db.persons, series: db.series,
                calendarEvents: db.calendarEvents, summaries: db.summaries
            ),
            hybridSearch: HybridSearch(
                recallIndex: db.recallIndex, meetings: db.meetings, summaries: db.summaries,
                transcripts: db.transcripts, embedder: UnavailableEmbedder()
            ),
            meetings: db.meetings,
            allowedMeetingIds: allowedMeetingIds
        )
    }

    private func makeMeeting(
        id: String, title: String = "Fixture meeting", createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: createdAt, updatedAt: createdAt)
    }

    private func call(_ tool: String, _ argsJSON: String) -> AgenticToolCall {
        AgenticToolCall(id: UUID().uuidString, name: tool, argumentsJSON: argsJSON)
    }

    // MARK: - search_transcripts

    @Test("search_transcripts: happy path returns a numbered, sourced excerpt and registers the source")
    func searchTranscriptsHappyPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m1", title: "Budget review")
        try await db.meetings.upsert(meeting)
        try await db.transcripts.upsert(Transcript(
            id: TranscriptID("t1"), meetingId: meeting.id,
            transcript: "We reviewed the Q3 budget numbers.", timestamp: "00:05", audioStartTime: 5
        ))
        let toolset = makeToolset(db)
        let state = ToolTurnState()

        let result = await toolset.dispatch(call("search_transcripts", #"{"query": "budget"}"#), state: state)
        #expect(result.contains("[S1]"))
        #expect(result.contains("Budget review"))
        #expect(await state.sources.count == 1)
        #expect(await state.isSurfaced(meeting.id))
    }

    @Test("search_transcripts: zero matches returns an honest no-match string, never fabricated")
    func searchTranscriptsZeroMatches() async throws {
        let db = try AppDatabase.makeInMemory()
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(
            call("search_transcripts", #"{"query": "nonexistent topic"}"#),
            state: state
        )
        #expect(result.contains("No matching"))
        #expect(await state.sources.isEmpty)
    }

    @Test("search_transcripts: invalid arguments returns an honest error, never throws")
    func searchTranscriptsInvalidArguments() async throws {
        let db = try AppDatabase.makeInMemory()
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("search_transcripts", "{}"), state: state)
        #expect(result.contains("Invalid arguments"))
    }

    @Test("search_transcripts: an oversized result is bounded at maxToolResultChars")
    func searchTranscriptsBoundedOutput() async throws {
        let db = try AppDatabase.makeInMemory()
        for index in 0 ..< 8 {
            let meeting = makeMeeting(id: "m\(index)", title: "Budget meeting \(index)")
            try await db.meetings.upsert(meeting)
            try await db.transcripts.upsert(Transcript(
                id: TranscriptID("t\(index)"), meetingId: meeting.id,
                transcript: String(repeating: "budget details ", count: 400), timestamp: "00:00", audioStartTime: 0
            ))
        }
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(
            call("search_transcripts", #"{"query": "budget", "limit": 8}"#),
            state: state
        )
        #expect(Recall.scalars(result).count <= RecallBounds.maxToolResultChars)
    }

    // MARK: - find_person

    @Test("find_person: happy path attaches a .person card and surfaces recent meetings")
    func findPersonHappyPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-sarah", title: "Budget sync")
        try await db.meetings.upsert(meeting)
        let person = Person(
            id: PersonID("p1"), email: "sarah@example.com", displayName: "Sarah Ammon", role: "PM",
            isOwner: false, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e1"), calendarId: "cal-1", title: "Budget sync",
            startTime: meeting.createdAt, endTime: meeting.createdAt.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "Sarah Ammon", email: "sarah@example.com")],
            meetingId: meeting.id, linkSource: .calendar
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("find_person", #"{"name": "Sarah"}"#), state: state)

        #expect(result.contains("Sarah Ammon"))
        #expect(result.contains(meeting.id.rawValue))
        #expect(await state.cards.count == 1)
        #expect(await state.isSurfaced(meeting.id), "the person's recent meeting id must be surfaced [P1]")
        guard case .person = await state.cards.first else {
            Issue.record("expected a .person card")
            return
        }
    }

    @Test("find_person: zero/ambiguous match returns an honest string, never a card")
    func findPersonZeroMatch() async throws {
        let db = try AppDatabase.makeInMemory()
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("find_person", #"{"name": "Nobody"}"#), state: state)
        #expect(result.contains("No unique person"))
        #expect(await state.cards.isEmpty)
    }

    // MARK: - find_meeting

    @Test("find_meeting: happy path attaches a .meeting card, surfaces its id")
    func findMeetingHappyPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-budget", title: "Q3 budget planning")
        try await db.meetings.upsert(meeting)
        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"), meetingId: meeting.id, bodyMarkdown: "Reviewed Q3 numbers.",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("find_meeting", #"{"title_or_topic": "Q3 budget"}"#), state: state)

        #expect(result.contains(meeting.id.rawValue))
        #expect(result.contains("has a saved summary"))
        #expect(await state.isSurfaced(meeting.id))
        guard case .meeting = await state.cards.first else {
            Issue.record("expected a .meeting card")
            return
        }
    }

    @Test("find_meeting: zero/ambiguous match returns an honest no-match string")
    func findMeetingZeroMatch() async throws {
        let db = try AppDatabase.makeInMemory()
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("find_meeting", #"{"title_or_topic": "nonexistent"}"#), state: state)
        #expect(result.contains("No unique meeting"))
    }

    // MARK: - get_meeting_summary

    @Test("get_meeting_summary: accepts a meeting id surfaced earlier this turn by find_person")
    func getMeetingSummaryAcceptsSurfacedId() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-landon", title: "Landon sync")
        try await db.meetings.upsert(meeting)
        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"), meetingId: meeting.id, bodyMarkdown: "Discussed the roadmap with Landon.",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        ))
        let person = Person(
            id: PersonID("p-landon"), email: "landon@example.com", displayName: "Landon Star",
            isOwner: false, createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        )
        try await db.persons.upsert(person)
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-landon"), calendarId: "cal-1", title: "Landon sync",
            startTime: meeting.createdAt, endTime: meeting.createdAt.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "Landon Star", email: "landon@example.com")],
            meetingId: meeting.id, linkSource: .calendar
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        _ = await toolset.dispatch(call("find_person", #"{"name": "Landon"}"#), state: state)
        let summary = await toolset.dispatch(
            call("get_meeting_summary", #"{"meeting_id": "\#(meeting.id.rawValue)"}"#), state: state
        )
        #expect(summary.contains("Discussed the roadmap with Landon."))
    }

    @Test("get_meeting_summary: rejects a meeting id NOT surfaced earlier this turn")
    func getMeetingSummaryRejectsUnsurfacedId() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-hidden", title: "Hidden meeting")
        try await db.meetings.upsert(meeting)
        try await db.summaries.upsert(Summary(
            id: SummaryID("s1"), meetingId: meeting.id, bodyMarkdown: "Secret content.",
            createdAt: meeting.createdAt, updatedAt: meeting.createdAt
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(
            call("get_meeting_summary", #"{"meeting_id": "\#(meeting.id.rawValue)"}"#), state: state
        )
        #expect(result.contains("Unknown meeting id"))
        #expect(!result.contains("Secret content"))
    }

    // MARK: - todays_events

    @Test("todays_events: hour filter narrows to events matching that local hour")
    func todaysEventsHourFilter() async throws {
        let db = try AppDatabase.makeInMemory()
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = 18
        components.minute = 0
        let sixPM = try #require(calendar.date(from: components))
        components.hour = 9
        let nineAM = try #require(calendar.date(from: components))

        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-6pm"), calendarId: "cal-1", title: "Evening sync",
            startTime: sixPM, endTime: sixPM.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-9am"), calendarId: "cal-1", title: "Morning standup",
            startTime: nineAM, endTime: nineAM.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "Sarah Ammon", email: "sarah@example.com")]
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("todays_events", #"{"hour": 18}"#), state: state)
        #expect(result.contains("Evening sync"))
        #expect(!result.contains("Morning standup"))
    }

    @Test("todays_events: attendee email match works, and non-today events are excluded")
    func todaysEventsAttendeeEmailMatch() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-today"), calendarId: "cal-1", title: "Today's sync",
            startTime: now, endTime: now.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-yesterday"), calendarId: "cal-1", title: "Yesterday's sync",
            startTime: yesterday, endTime: yesterday.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))

        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("todays_events", #"{"attendee": "james@example.com"}"#), state: state)
        #expect(result.contains("Today's sync"))
        #expect(!result.contains("Yesterday's sync"))
    }

    @Test("todays_events: scheduled-≠-recorded wording is present for an unlinked event")
    func todaysEventsScheduledWording() async throws {
        let db = try AppDatabase.makeInMemory()
        let now = Date()
        try await db.calendarEvents.upsert(CalendarEvent(
            id: CalendarEventID("e-unlinked"), calendarId: "cal-1", title: "Ad hoc sync",
            startTime: now, endTime: now.addingTimeInterval(1800), isAllDay: false,
            attendees: [Attendee(name: "James Nance", email: "james@example.com")]
        ))
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("todays_events", "{}"), state: state)
        #expect(result.contains("Scheduled only"))
        #expect(await state.cards.count == 1)
    }

    // MARK: - list_recent_meetings

    @Test("list_recent_meetings: lists newest-first meetings, respects limit, surfaces ids")
    func listRecentMeetingsHappyPath() async throws {
        let db = try AppDatabase.makeInMemory()
        for index in 0 ..< 5 {
            try await db.meetings.upsert(makeMeeting(
                id: "m\(index)", title: "Meeting \(index)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 3600)
            ))
        }
        let toolset = makeToolset(db)
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("list_recent_meetings", #"{"limit": 2}"#), state: state)
        #expect(result.contains("m4"))
        #expect(result.contains("m3"))
        #expect(!result.contains("m0"))
        #expect(await state.isSurfaced(MeetingID("m4")))
    }

    @Test("list_recent_meetings: series-scoped toolset only lists allowed member meetings")
    func listRecentMeetingsSeriesScoped() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(makeMeeting(id: "m-in", title: "In series"))
        try await db.meetings.upsert(makeMeeting(id: "m-out", title: "Out of series"))
        let toolset = makeToolset(db, allowedMeetingIds: [MeetingID("m-in")])
        let state = ToolTurnState()
        let result = await toolset.dispatch(call("list_recent_meetings", "{}"), state: state)
        #expect(result.contains("m-in"))
        #expect(!result.contains("m-out"))
    }
}
