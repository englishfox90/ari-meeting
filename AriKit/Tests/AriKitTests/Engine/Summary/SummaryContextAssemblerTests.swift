//
//  SummaryContextAssemblerTests.swift — the F3 summary-context block that the first Swift
//  migration of the summary path dropped (← ari-engine `summary_context_for_meeting_impl`).
//
//  Built on `AppDatabase.makeInMemory()`, seeding real Person/CalendarEvent/ProfileFact/Series
//  rows through their repositories (never a raw SQLite handle). Asserts the block the summarizer
//  now receives — the fix for summaries that said "Date: Not explicitly stated in the transcript".
//
import Foundation
import Testing
@testable import AriKit

@Suite("Summary context assembler (F3 injection restored)")
struct SummaryContextAssemblerTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeMeeting(id: String, title: String = "Fixture meeting") -> Meeting {
        Meeting(id: MeetingID(id), title: title, createdAt: epoch, updatedAt: epoch)
    }

    // MARK: - Empty case (No-Fake-State)

    @Test("Returns empty when there is no owner and no participants")
    func emptyWithoutAnchor() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = makeMeeting(id: "m-empty")
        try await db.meetings.upsert(meeting)

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)
        #expect(block.isEmpty)
    }

    // MARK: - Full block

    @Test("Assembles owner, participants, linked calendar event (Title/Date/Description/Attendees) and series ledger")
    func fullBlock() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = Person(
            id: PersonID("owner-1"),
            email: "paul@arivo.com",
            displayName: "Paul Fox-Reeks",
            role: "Manager",
            organization: "Arivo",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)

        let amy = Person(
            id: PersonID("amy-1"),
            email: "amy@arivo.com",
            displayName: "Amy Teuscher",
            role: "Department Manager",
            isOwner: false,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(amy)

        let meeting = makeMeeting(id: "m-full", title: "1:1 with Amy")
        try await db.meetings.upsert(meeting)
        try await db.persons.addParticipant(meetingId: meeting.id, personId: amy.id, at: epoch)

        let event = CalendarEvent(
            id: CalendarEventID("evt-full"),
            calendarId: "cal-1",
            title: "1:1 Amy / Paul",
            startTime: epoch,
            endTime: epoch.addingTimeInterval(1800),
            isAllDay: false,
            notes: "Discuss department reorg.",
            attendees: [
                Attendee(name: "Amy Teuscher", email: "amy@arivo.com"),
                Attendee(name: "Paul Fox-Reeks", email: "paul@arivo.com")
            ],
            meetingId: meeting.id,
            linkSource: .calendar
        )
        try await db.calendarEvents.upsert(event)

        // Series with a running ledger.
        let series = Series(
            id: SeriesID("series-1"),
            title: "Amy 1:1",
            ledgerMarkdown: "- Open: finalize reorg plan by Q1.",
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: meeting.id, at: epoch)

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)

        #expect(block.contains("### Meeting context (for the summarizer)"))
        #expect(block.contains("Organization: Arivo"))
        #expect(block.contains("Owner: Paul Fox-Reeks, Manager"))
        #expect(block.contains("Participants:"))
        #expect(block.contains("- Amy Teuscher (Department Manager)"))
        #expect(block.contains("### Calendar event (authoritative attendee roster)"))
        #expect(block.contains("Title: 1:1 Amy / Paul"))
        // The added Date line — the direct fix for "Date: Not explicitly stated in the transcript".
        #expect(block.contains("Date: "))
        #expect(block.contains("Description: Discuss department reorg."))
        #expect(block.contains("Attendees: Amy Teuscher <amy@arivo.com>, Paul Fox-Reeks <paul@arivo.com>"))
        #expect(block.contains("### Series ledger (running context from prior meetings in this series)"))
        #expect(block.contains("- Open: finalize reorg plan by Q1."))
    }

    // MARK: - Facts clause capped at maxPersonFacts

    @Test("Owner facts clause joins active facts, capped at maxPersonFacts, most-confident first")
    func factsClauseCapped() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = Person(
            id: PersonID("owner-facts"),
            displayName: "Owner",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)
        let meeting = makeMeeting(id: "m-facts")
        try await db.meetings.upsert(meeting)

        // Five active facts, ascending confidence — only the top 4 should appear, and the
        // lowest-confidence one ("fact-0", confidence 0.10) must be dropped.
        for index in 0 ..< 5 {
            try await db.profileFacts.upsert(ProfileFact(
                id: ProfileFactID("fact-\(index)"),
                personId: owner.id,
                factText: "fact-\(index)",
                factKind: .project,
                origin: .selfReported,
                confidence: 0.10 + Double(index) * 0.15,
                sourceCount: 1,
                status: .active,
                createdAt: epoch
            ))
        }

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)
        #expect(block.contains("fact-4"))
        #expect(!block.contains("fact-0"))
    }
}
