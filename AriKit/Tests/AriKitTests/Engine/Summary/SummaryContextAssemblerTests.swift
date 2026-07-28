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

        // Five active facts, ascending confidence, all sourced from the meeting being summarized
        // (eligible) — only the top 4 should appear, and the lowest-confidence one ("fact-0",
        // confidence 0.10) must be dropped.
        for index in 0 ..< 5 {
            try await db.profileFacts.upsert(ProfileFact(
                id: ProfileFactID("fact-\(index)"),
                personId: owner.id,
                factText: "fact-\(index)",
                factKind: .project,
                sourceMeetingId: meeting.id,
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
        // Bleed fix: every surfaced fact is explicitly framed as dated background, never a bare assertion.
        #expect(block.contains("fact-4 (background, from"))
    }

    // MARK: - Bleed fix: facts are a provable-relevance WHITELIST, not an include-and-label

    @Test("A fact sourced from a same-series meeting IS injected, framed as dated background")
    func factsClauseIncludesSameSeriesFact() async throws {
        let db = try AppDatabase.makeInMemory()

        let person = Person(
            id: PersonID("person-1"),
            displayName: "Amy Teuscher",
            isOwner: false,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(person)

        let seriesMeeting = makeMeeting(id: "m-series-prior", title: "Prior 1:1")
        try await db.meetings.upsert(seriesMeeting)
        let currentMeeting = makeMeeting(id: "m-current", title: "1:1 with Amy")
        try await db.meetings.upsert(currentMeeting)
        try await db.persons.addParticipant(meetingId: currentMeeting.id, personId: person.id, at: epoch)

        let series = Series(id: SeriesID("series-amy"), title: "Amy 1:1", createdAt: epoch, updatedAt: epoch)
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: seriesMeeting.id, at: epoch)
        try await db.series.addMember(seriesId: series.id, meetingId: currentMeeting.id, at: epoch)

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

        let block = await SummaryContextAssembler(database: db).contextBlock(for: currentMeeting.id)
        #expect(block.contains("Leading the Q1 reorg plan (background,"))
        #expect(!block.contains("unrelated"))
    }

    @Test("A fact sourced from an unrelated (different-series) meeting is NOT injected")
    func factsClauseExcludesUnrelatedMeetingFact() async throws {
        let db = try AppDatabase.makeInMemory()

        let person = Person(
            id: PersonID("person-1"),
            displayName: "Amy Teuscher",
            isOwner: false,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(person)

        let unrelatedMeeting = makeMeeting(id: "m-unrelated", title: "Unrelated training session")
        try await db.meetings.upsert(unrelatedMeeting)
        let currentMeeting = makeMeeting(id: "m-current", title: "1:1 with Amy")
        try await db.meetings.upsert(currentMeeting)
        try await db.persons.addParticipant(meetingId: currentMeeting.id, personId: person.id, at: epoch)

        let series = Series(id: SeriesID("series-amy"), title: "Amy 1:1", createdAt: epoch, updatedAt: epoch)
        try await db.series.upsert(series)
        try await db.series.addMember(seriesId: series.id, meetingId: currentMeeting.id, at: epoch)
        // `unrelatedMeeting` is deliberately NOT added to any series.

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
        #expect(!block.contains("Metro 2 reporting accuracy concerns"))
        // Nothing else to inject for this participant, so the clause is dropped cleanly.
        #expect(!block.contains("- Amy Teuscher:"))
    }

    @Test(
        "A fact with a nil/empty sourceMeetingId is NOT injected (unresolvable provenance is excluded, not assumed relevant)"
    )
    func factsClauseExcludesFactWithNoSourceMeeting() async throws {
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
        #expect(!block.contains("Enjoys mentoring new hires"))
        // The owner line still renders (no dangling ":" once the only fact is filtered out).
        #expect(block.contains("Owner: Owner"))
        #expect(!block.contains("Owner: Owner:"))
    }

    @Test("A fact whose sourceMeetingId points at a nonexistent meeting row is NOT injected")
    func factsClauseExcludesFactWithDanglingSourceMeeting() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = Person(
            id: PersonID("owner-dangling"),
            displayName: "Owner",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)
        let meeting = makeMeeting(id: "m-dangling")
        try await db.meetings.upsert(meeting)

        // A real shape seen in the store: a legacy-imported id that never resolves to a row. The
        // `profileFact.sourceMeetingId` FK is real (`onDelete: .setNull`), so inserting a genuinely
        // dangling reference through the repository is rejected — exactly the same protection real
        // corrupt/legacy rows evade via a raw insert with FK checks off. Reproduce that shape
        // directly against the writer (test-only; production code never does this).
        try await db.dbWriter.writeWithoutTransaction { conn in
            try conn.execute(sql: "PRAGMA foreign_keys = OFF")
            try conn.execute(
                sql: """
                INSERT INTO profileFact
                    (id, personId, factText, factKind, sourceMeetingId, origin, confidence, status, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "fact-dangling",
                    owner.id.rawValue,
                    "Announce GPM decisions",
                    FactKind.project.rawValue,
                    "meeting-does-not-exist",
                    FactOrigin.attributed.rawValue,
                    0.98,
                    FactStatus.active.rawValue,
                    epoch
                ]
            )
            try conn.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let block = await SummaryContextAssembler(database: db).contextBlock(for: meeting.id)
        #expect(!block.contains("Announce GPM decisions"))
    }

    @Test(
        "Owner-fact leak regression: an unrelated high-confidence fact merged onto the owner is NOT injected into the owner line"
    )
    func ownerLineExcludesUnrelatedFacts() async throws {
        let db = try AppDatabase.makeInMemory()

        let owner = Person(
            id: PersonID("owner-leak"),
            displayName: "Paul Fox-Reeks",
            role: "Manager",
            domain: "Engineering",
            isOwner: true,
            createdAt: epoch,
            updatedAt: epoch
        )
        try await db.persons.upsert(owner)

        let unrelatedMeeting = makeMeeting(id: "m-unrelated-work", title: "Unrelated work meeting")
        try await db.meetings.upsert(unrelatedMeeting)
        let currentMeeting = makeMeeting(id: "m-1on1", title: "Personal mentorship 1:1")
        try await db.meetings.upsert(currentMeeting)

        // The owner has no series membership at all here — a duplicate-person merge consolidated
        // facts from unrelated work meetings onto the owner row, exactly the leak this fix targets.
        try await db.profileFacts.upsert(ProfileFact(
            id: ProfileFactID("fact-owner-leak"),
            personId: owner.id,
            factText: "Navigate Payment Manager role transition (Peter)",
            factKind: .project,
            sourceMeetingId: unrelatedMeeting.id,
            origin: .attributed,
            confidence: 0.98,
            sourceCount: 1,
            status: .active,
            createdAt: epoch
        ))

        let block = await SummaryContextAssembler(database: db).contextBlock(for: currentMeeting.id)
        #expect(!block.contains("Payment Manager"))
        // Authored identity still renders even with every fact filtered out.
        #expect(block.contains("Owner: Paul Fox-Reeks, Manager — Engineering"))
        #expect(!block.contains("Owner: Paul Fox-Reeks, Manager — Engineering:"))
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
