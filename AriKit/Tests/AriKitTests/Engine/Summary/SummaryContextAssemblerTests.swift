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
        // Bleed fix: every surfaced fact is explicitly framed as background, never a bare assertion.
        #expect(block.contains("fact-4 (background)"))
    }

    // MARK: - Bleed fix: facts are framed as background and ranked/labelled by series relevance

    @Test("Facts sourced from the current meeting's own series rank first and are framed as plain background")
    func factsClausePrefersSameSeriesFacts() async throws {
        let db = try AppDatabase.makeInMemory()

        let person = Person(
            id: PersonID("person-1"),
            displayName: "Amy Teuscher",
            isOwner: false,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(person)

        // Two prior meetings: one in the same series as the meeting being summarized, one wholly
        // unrelated. Both produced a fact about this person.
        let seriesMeeting = makeMeeting(id: "m-series-prior", title: "Prior 1:1")
        try await db.meetings.upsert(seriesMeeting)
        let unrelatedMeeting = makeMeeting(id: "m-unrelated", title: "Unrelated training session")
        try await db.meetings.upsert(unrelatedMeeting)

        let currentMeeting = makeMeeting(id: "m-current", title: "1:1 with Amy")
        try await db.meetings.upsert(currentMeeting)
        try await db.persons.addParticipant(meetingId: currentMeeting.id, personId: person.id, at: epoch)

        let series = Series(
            id: SeriesID("series-amy"),
            title: "Amy 1:1",
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: seriesMeeting.id, at: epoch)
        try await db.series.addMember(seriesId: series.id, meetingId: currentMeeting.id, at: epoch)
        // `unrelatedMeeting` is deliberately NOT added to any series.

        // Lower confidence than the unrelated fact, so a naive confidence-only sort would rank the
        // unrelated fact first — the point of this test is that series relevance wins that tie-break.
        try await db.profileFacts.upsert(ProfileFact(
            id: ProfileFactID("fact-series"),
            personId: person.id,
            factText: "Leading the Q1 reorg plan",
            factKind: .project,
            sourceMeetingId: seriesMeeting.id,
            origin: .attributed,
            confidence: 0.5,
            sourceCount: 1,
            status: .active,
            createdAt: epoch
        ))
        try await db.profileFacts.upsert(ProfileFact(
            id: ProfileFactID("fact-unrelated"),
            personId: person.id,
            factText: "Metro 2 reporting accuracy concerns",
            factKind: .project,
            sourceMeetingId: unrelatedMeeting.id,
            origin: .attributed,
            confidence: 0.9,
            sourceCount: 1,
            status: .active,
            createdAt: epoch
        ))

        let block = await SummaryContextAssembler(database: db).contextBlock(for: currentMeeting.id)

        // The same-series fact is framed as plain background (no "unrelated" label)...
        #expect(block.contains("Leading the Q1 reorg plan (background,"))
        // ...and the cross-meeting fact is never silently dropped, but IS explicitly marked unrelated.
        #expect(block.contains("Metro 2 reporting accuracy concerns (unrelated background,"))

        // Relevance ranks before confidence: the same-series fact appears before the unrelated one,
        // even though the unrelated fact has the higher raw confidence.
        let seriesRange = try #require(block.range(of: "Leading the Q1 reorg plan"))
        let unrelatedRange = try #require(block.range(of: "Metro 2 reporting accuracy concerns"))
        #expect(seriesRange.lowerBound < unrelatedRange.lowerBound)
    }

    @Test("A fact with no recorded source meeting is framed as background with no date, never labelled unrelated")
    func factsClauseWithoutSourceMeetingOmitsDateAndUnrelatedLabel() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = Person(
            id: PersonID("owner-nosource"),
            displayName: "Owner",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)
        let meeting = makeMeeting(id: "m-nosource")
        try await db.meetings.upsert(meeting)

        try await db.profileFacts.upsert(ProfileFact(
            id: ProfileFactID("fact-nosource"),
            personId: owner.id,
            factText: "Enjoys mentoring new hires",
            factKind: .interest,
            origin: .selfReported,
            confidence: 0.8,
            sourceCount: 1,
            status: .active,
            createdAt: epoch
        ))

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)
        #expect(block.contains("Enjoys mentoring new hires (background)"))
        #expect(!block.contains("unrelated"))
    }

    // MARK: - T-A3 (docs/plans/custom-vocabulary.md §5) — zero vocabulary terms changes nothing

    @Test("Byte-identical full block with zero vocabulary terms (Step 4 must not change existing output)")
    func existingBlocksAreByteIdenticalWithZeroTerms() async throws {
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

        let series = Series(
            id: SeriesID("series-1"),
            title: "Amy 1:1",
            ledgerMarkdown: "- Open: finalize reorg plan by Q1.",
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: meeting.id, at: epoch)

        // No vocabulary terms inserted at all — the DB genuinely has none.
        let vocabularyTermCountBeforeAssembly = try await db.vocabulary.all().count
        #expect(vocabularyTermCountBeforeAssembly == 0)

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)

        // Same fixture as `fullBlock` above — this is the exact pre-Step-4 output, pinned
        // byte-for-byte (not just `.contains`), so a `### Glossary` section (or any other stray
        // byte) introduced by the vocabulary wiring would fail this test.
        let dateString = SummaryContextAssembler.eventDateFormatter.string(from: event.startTime)
        let expected = [
            "### Meeting context (for the summarizer)",
            "Organization: Arivo (everyone below works at Arivo unless noted).",
            "Owner: Paul Fox-Reeks, Manager",
            "Participants:",
            "- Amy Teuscher (Department Manager)",
            "### Calendar event (authoritative attendee roster)",
            "Title: 1:1 Amy / Paul",
            "Date: \(dateString)",
            "Description: Discuss department reorg.",
            "Attendees: Amy Teuscher <amy@arivo.com>, Paul Fox-Reeks <paul@arivo.com>",
            "### Series ledger (running context from prior meetings in this series)",
            "- Open: finalize reorg plan by Q1."
        ].joined(separator: "\n")

        #expect(block == expected)
        #expect(!block.contains("Glossary"))
    }
}
