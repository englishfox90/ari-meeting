//
//  PeopleContextTests.swift — plan §6 `PeopleContextTests` (Recall Slice 7, PARTIAL by design,
//  ← ari-engine/src/recall/context.rs).
//
//  Built on `AppDatabase.makeInMemory()`, seeding real `Person`/`CalendarEvent`/`ProfileFact`
//  rows through their repositories (never a raw SQLite handle). No test asserts a
//  diarization-derived speaker name — that half is gated to Phase 3.5 and intentionally absent
//  (see `PeopleContext.swift`'s file-header PARTIAL PORT note).
//
import Foundation
import Testing
@testable import AriKit

@Suite("People context (Ask Meetings) — Recall Slice 7, PARTIAL by design")
struct PeopleContextTests {
    private func makeContext(_ db: AppDatabase) -> PeopleContext {
        PeopleContext(
            persons: db.persons,
            profileFacts: db.profileFacts,
            calendarEvents: db.calendarEvents
        )
    }

    private func makeMeeting(id: String, title: String = "Fixture meeting") -> Meeting {
        Meeting(
            id: MeetingID(id),
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - 1. Owner block + meeting-scoped fact truncation

    @Test("Owner block includes name/role/org; a matched attendee's active fact is truncated at maxFactChars")
    func ownerBlockAndTruncatedFact() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let owner = Person(
            id: PersonID("owner-1"),
            email: "owner@example.com",
            displayName: "Ada Lovelace",
            role: "Engineering Lead",
            organization: "Arivo",
            isOwner: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.persons.upsert(owner)

        let meeting = makeMeeting(id: "meeting-owner")
        try await db.meetings.upsert(meeting)

        let event = CalendarEvent(
            id: CalendarEventID("event-owner"),
            calendarId: "cal-1",
            title: "Weekly sync",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: "Ada Lovelace", email: "owner@example.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        )
        try await db.calendarEvents.upsert(event)

        let longFactText = String(repeating: "a", count: 200)
        let fact = ProfileFact(
            id: ProfileFactID("fact-owner-1"),
            personId: owner.id,
            factText: longFactText,
            factKind: .project,
            origin: .selfReported,
            confidence: 0.9,
            sourceCount: 1,
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.profileFacts.upsert(fact)

        let block = await context.peopleContextBlock(sources: [], scopedMeetingId: meeting.id)

        #expect(block.contains("Owner (you): Ada Lovelace, Engineering Lead at Arivo."))
        // Truncated to exactly maxFactChars scalars + the ellipsis marker, never the full 200.
        let expectedTruncated = String(repeating: "a", count: RecallBounds.maxFactChars) + "…"
        #expect(block.contains("- Ada Lovelace: \(expectedTruncated)"))
        #expect(!block.contains(longFactText))
    }

    @Test("Owner block omits role/org when absent, and trims whitespace-only role/org")
    func ownerBlockOmitsBlankRoleAndOrganization() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let owner = Person(
            id: PersonID("owner-2"),
            displayName: "Grace Hopper",
            role: "   ",
            organization: nil,
            isOwner: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await db.persons.upsert(owner)

        let block = await context.peopleContextBlock(sources: [], scopedMeetingId: nil)
        #expect(block.contains("Owner (you): Grace Hopper."))
        #expect(!block.contains(","))
    }

    // MARK: - 2. Attendee block — capped at maxPeoplePerMeeting

    @Test("Meeting-scoped attendee line is capped at maxPeoplePerMeeting (seed 9, assert 8)")
    func attendeeLineCappedAtMaxPeoplePerMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let meeting = makeMeeting(id: "meeting-attendees")
        try await db.meetings.upsert(meeting)

        let attendeeCount = 9
        var attendees: [Attendee] = []
        for index in 0 ..< attendeeCount {
            let email = "attendee\(index)@example.com"
            attendees.append(Attendee(name: "Attendee \(index)", email: email))
            try await db.persons.upsert(Person(
                id: PersonID("person-attendee-\(index)"),
                email: email,
                displayName: "Attendee \(index)",
                isOwner: false,
                createdAt: meeting.createdAt,
                updatedAt: meeting.createdAt
            ))
        }

        let event = CalendarEvent(
            id: CalendarEventID("event-attendees"),
            calendarId: "cal-1",
            title: "All hands",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(3600),
            isAllDay: false,
            attendees: attendees,
            meetingId: meeting.id,
            linkSource: .calendar
        )
        try await db.calendarEvents.upsert(event)

        let block = await context.peopleContextBlock(sources: [], scopedMeetingId: meeting.id)

        let attendeeLine = try #require(
            block.split(separator: "\n").first { $0.hasPrefix("Calendar event") }
        )
        let listedNames = (0 ..< attendeeCount).map { "Attendee \($0)" }
            .filter { attendeeLine.contains($0) }
        #expect(listedNames.count == RecallBounds.maxPeoplePerMeeting)
        #expect(attendeeLine.contains("All hands"))
    }

    @Test("Attendees with no name fall back to their e-mail address")
    func attendeeLineFallsBackToEmailWhenNameMissing() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let meeting = makeMeeting(id: "meeting-email-fallback")
        try await db.meetings.upsert(meeting)

        let event = CalendarEvent(
            id: CalendarEventID("event-email-fallback"),
            calendarId: "cal-1",
            title: "Vendor call",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            attendees: [Attendee(name: nil, email: "vendor@example.com")],
            meetingId: meeting.id,
            linkSource: .calendar
        )
        try await db.calendarEvents.upsert(event)

        let block = await context.peopleContextBlock(sources: [], scopedMeetingId: meeting.id)
        #expect(block.contains("vendor@example.com"))
    }

    @Test("Event notes are included, truncated at maxNoteChars")
    func eventNotesAreIncludedAndTruncated() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let meeting = makeMeeting(id: "meeting-notes")
        try await db.meetings.upsert(meeting)

        let longNotes = String(repeating: "n", count: 400)
        let event = CalendarEvent(
            id: CalendarEventID("event-notes"),
            calendarId: "cal-1",
            title: "Planning",
            startTime: meeting.createdAt,
            endTime: meeting.createdAt.addingTimeInterval(1800),
            isAllDay: false,
            notes: longNotes,
            attendees: [],
            meetingId: meeting.id,
            linkSource: .calendar
        )
        try await db.calendarEvents.upsert(event)

        let block = await context.peopleContextBlock(sources: [], scopedMeetingId: meeting.id)
        let expected = String(repeating: "n", count: RecallBounds.maxNoteChars) + "…"
        #expect(block.contains("Event notes: \(expected)"))
        #expect(!block.contains(longNotes))
    }

    // MARK: - 3. Empty — honest "" when nothing real exists

    @Test("No owner, no calendar event, no sources -> peopleContextBlock returns an empty string")
    func emptyWhenNothingReal() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let meeting = makeMeeting(id: "meeting-empty")
        try await db.meetings.upsert(meeting)

        let scopedBlock = await context.peopleContextBlock(sources: [], scopedMeetingId: meeting.id)
        #expect(scopedBlock.isEmpty)

        let globalBlock = await context.peopleContextBlock(sources: [], scopedMeetingId: nil)
        #expect(globalBlock.isEmpty)
    }

    @Test("Global scope: sources with empty speakers contribute nothing; non-empty speakers render a bounded line")
    func globalScopeUsesOnlyRealSpeakerData() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        let silentSource = RecallSource(
            meetingId: "meeting-silent",
            title: "Silent meeting",
            matchContext: "…",
            timestamp: "00:00",
            meetingDate: "2026-07-18T00:00:00Z",
            speakers: []
        )
        let identifiedSource = RecallSource(
            meetingId: "meeting-identified",
            title: "Identified meeting",
            matchContext: "…",
            timestamp: "00:00",
            meetingDate: "2026-07-19T00:00:00Z",
            speakers: ["Ada Lovelace", "Grace Hopper"]
        )

        let block = await context.peopleContextBlock(
            sources: [silentSource, identifiedSource],
            scopedMeetingId: nil
        )
        #expect(!block.contains("Silent meeting"))
        // The per-meeting line renders the people and a LOCAL-day date. The exact day depends on
        // the device timezone (this path uses `.current`, unlike `buildContext`'s injectable one),
        // so assert the tz-independent invariant: the people render, and the raw RFC3339 UTC string
        // never leaks into the prompt (the fix for the 2026-07-23 timezone bug — was `prefix(10)`).
        #expect(block.contains("- \"Identified meeting\" ("))
        #expect(block.contains(") — people: Ada Lovelace, Grace Hopper."))
        #expect(block.contains("2026"))
        #expect(!block.contains("2026-07-19"))
        #expect(!block.contains("T00:00:00Z"))
    }

    // MARK: - 4. The diarization-derived half is absent (documented; no speaker-name assertions)

    @Test("attachPeople is a documented no-op today — it never invents a speakers label (Phase 3.5 gate)")
    func attachPeopleNeverInventsSpeakers() async throws {
        let db = try AppDatabase.makeInMemory()
        let context = makeContext(db)

        var sources = [
            RecallSource(
                meetingId: "meeting-1",
                title: "Some meeting",
                matchContext: "…",
                timestamp: "00:00"
            )
        ]
        #expect(sources[0].speakers.isEmpty)

        await context.attachPeople(&sources)

        // No diarization/participant-linking signal exists yet (gated to Phase 3.5) — `speakers`
        // must stay exactly as supplied, never fabricated from calendar/attendee data.
        #expect(sources[0].speakers.isEmpty)
    }
}
