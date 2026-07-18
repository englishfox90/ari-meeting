//
//  RoundTripFidelityTests.swift — upsert each domain value through its repository, read it back,
//  assert fidelity (plan §7 test 2).
//
//  Reuses `ModelSamples` (the Models test suite's canonical fixtures) so these tests exercise
//  the same values already proven Codable-round-trip-clean at the Models layer.
//
//  Foundation slice (plan §10 steps 1–2) covered meeting/transcript/speaker/speakerSegment.
//  Slice 2 (plan §10 steps 3–5) adds summary/meetingNote/person below. Slice 3 (plan §10 step 6)
//  adds series (+ its ledger/membership tables) and calendarEvent below.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Round-trip fidelity — meeting/transcript/speaker/speakerSegment")
struct RoundTripFidelityTests {
    @Test("Meeting round-trips through MeetingRepository")
    func meetingRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = ModelSamples.meeting

        try await db.meetings.upsert(meeting)
        let fetched = try await db.meetings.find(meeting.id)

        #expect(fetched == meeting)
    }

    @Test("Meeting upsert is idempotent (insert then update)")
    func meetingUpsertUpdates() async throws {
        let db = try AppDatabase.makeInMemory()
        var meeting = ModelSamples.meeting
        try await db.meetings.upsert(meeting)

        meeting.title = "Renamed"
        try await db.meetings.upsert(meeting)

        let fetched = try await db.meetings.find(meeting.id)
        #expect(fetched?.title == "Renamed")

        let all = try await db.meetings.all()
        #expect(all.count == 1)
    }

    @Test("Meeting soft-delete tombstones rather than deletes")
    func meetingSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        let meeting = ModelSamples.meeting
        try await db.meetings.upsert(meeting)

        let deletedAt = Date(timeIntervalSince1970: 1_700_010_000)
        try await db.meetings.softDelete(meeting.id, at: deletedAt)

        let visibleByDefault = try await db.meetings.all()
        #expect(visibleByDefault.isEmpty)

        let includingDeleted = try await db.meetings.all(includingDeleted: true)
        #expect(includingDeleted.count == 1)

        // The row itself must still exist and be readable — a tombstone, never a hard delete.
        let stillFindable = try await db.meetings.find(meeting.id)
        #expect(stillFindable != nil)
    }

    @Test("Transcript round-trips, dropping the pre-chunking-era text fields (plan §4.2)")
    func transcriptRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker) // transcript.speakerId FK target
        let transcript = ModelSamples.transcript

        try await db.transcripts.upsert(transcript)
        let fetched = try await db.transcripts.find(transcript.id)

        var expected = transcript
        expected.summary = nil
        expected.actionItems = nil
        expected.keyPoints = nil
        #expect(fetched == expected)
    }

    @Test("Transcript.forMeeting scopes by meetingId and excludes tombstoned rows")
    func transcriptForMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker) // transcript.speakerId FK target
        let transcript = ModelSamples.transcript
        try await db.transcripts.upsert(transcript)

        let forMeeting = try await db.transcripts.forMeeting(ModelSamples.meeting.id)
        #expect(forMeeting.count == 1)

        try await db.transcripts.softDelete(transcript.id, at: Date())
        let afterDelete = try await db.transcripts.forMeeting(ModelSamples.meeting.id)
        #expect(afterDelete.isEmpty)
    }

    @Test("Speaker round-trips including Data centroid, enum, and Date precision")
    func speakerRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        let speaker = ModelSamples.speaker

        try await db.speakers.upsert(speaker)
        let fetched = try await db.speakers.find(speaker.id)

        #expect(fetched == speaker)
    }

    @Test("Speaker enrollmentState tolerates an unknown raw value")
    func speakerUnknownEnrollmentState() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        var speaker = ModelSamples.speaker
        speaker.id = "speaker-unknown"
        speaker.enrollmentState = .unknown("future_state")

        try await db.speakers.upsert(speaker)
        let fetched = try await db.speakers.find(speaker.id)

        #expect(fetched?.enrollmentState == .unknown("future_state"))
    }

    @Test("SpeakerSegment round-trips including optional embedding blob")
    func speakerSegmentRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker)
        let segment = ModelSamples.speakerSegment

        try await db.speakerSegments.upsert(segment)
        let fetched = try await db.speakerSegments.find(segment.id)

        #expect(fetched == segment)
    }

    @Test("SpeakerSegment.delete performs a genuine hard delete (no tombstone column yet)")
    func speakerSegmentHardDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker)
        let segment = ModelSamples.speakerSegment
        try await db.speakerSegments.upsert(segment)

        let deleted = try await db.speakerSegments.delete(segment.id)
        #expect(deleted)

        let fetched = try await db.speakerSegments.find(segment.id)
        #expect(fetched == nil)
    }

    @Test("Deleting a meeting cascades to its transcripts and speakerSegments (FK ON DELETE CASCADE)")
    func meetingCascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker)
        try await db.transcripts.upsert(ModelSamples.transcript)
        try await db.speakerSegments.upsert(ModelSamples.speakerSegment)

        // A real DELETE on the parent row (not the repository's soft-delete) is the only way to
        // observe the FK cascade — this proves the migrator actually wired `ON DELETE CASCADE`.
        // `dbWriter` is module-internal (not part of the public repository surface); reached
        // here only via `@testable import` to exercise the raw FK behavior directly.
        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [ModelSamples.meeting.id.rawValue])
        }

        let transcripts = try await db.transcripts.all(includingDeleted: true)
        let segments = try await db.speakerSegments.all()
        #expect(transcripts.isEmpty)
        #expect(segments.isEmpty)
    }

    @Test("Deleting a speaker nulls out speakerId on transcripts/speakerSegments (FK ON DELETE SET NULL)")
    func speakerDeleteSetsNull() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.persons.upsert(ModelSamples.person) // speaker.personId FK target
        try await db.speakers.upsert(ModelSamples.speaker)
        try await db.transcripts.upsert(ModelSamples.transcript)
        try await db.speakerSegments.upsert(ModelSamples.speakerSegment)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(sql: "DELETE FROM speaker WHERE id = ?", arguments: [ModelSamples.speaker.id.rawValue])
        }

        let transcript = try await db.transcripts.find(ModelSamples.transcript.id)
        let segment = try await db.speakerSegments.find(ModelSamples.speakerSegment.id)
        #expect(transcript?.speakerId == nil)
        #expect(segment?.speakerId == nil)
    }

    // MARK: - Slice 2: summary

    @Test("Summary round-trips through SummaryRepository")
    func summaryRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let summary = ModelSamples.summary

        try await db.summaries.upsert(summary)
        let fetched = try await db.summaries.find(summary.id)

        #expect(fetched == summary)
    }

    @Test("Summary.forMeeting finds the unique summary for a meeting")
    func summaryForMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.summaries.upsert(ModelSamples.summary)

        let found = try await db.summaries.forMeeting(ModelSamples.meeting.id)
        #expect(found == ModelSamples.summary)
    }

    @Test("Summary soft-delete tombstones rather than deletes")
    func summarySoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.summaries.upsert(ModelSamples.summary)

        try await db.summaries.softDelete(ModelSamples.summary.id, at: Date())
        #expect(try await db.summaries.all().isEmpty)
        #expect(try await db.summaries.all(includingDeleted: true).count == 1)
    }

    @Test("Deleting a meeting cascades to its summary (FK ON DELETE CASCADE)")
    func summaryCascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.summaries.upsert(ModelSamples.summary)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [ModelSamples.meeting.id.rawValue]
            )
        }

        let all = try await db.summaries.all(includingDeleted: true)
        #expect(all.isEmpty)
    }

    // MARK: - Slice 2: meetingNote

    @Test("MeetingNote round-trips through MeetingNoteRepository, keyed on meetingId")
    func meetingNoteRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        let note = ModelSamples.meetingNote

        try await db.meetingNotes.upsert(note)
        let fetched = try await db.meetingNotes.find(note.meetingId)

        #expect(fetched == note)
    }

    @Test("MeetingNote soft-delete tombstones rather than deletes")
    func meetingNoteSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.meetingNotes.upsert(ModelSamples.meetingNote)

        try await db.meetingNotes.softDelete(ModelSamples.meetingNote.meetingId, at: Date())
        #expect(try await db.meetingNotes.all().isEmpty)
        #expect(try await db.meetingNotes.all(includingDeleted: true).count == 1)
    }

    @Test("Deleting a meeting cascades to its note (FK ON DELETE CASCADE)")
    func meetingNoteCascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.meetingNotes.upsert(ModelSamples.meetingNote)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [ModelSamples.meeting.id.rawValue]
            )
        }

        let all = try await db.meetingNotes.all(includingDeleted: true)
        #expect(all.isEmpty)
    }

    // MARK: - Slice 2: person

    @Test("Person round-trips through PersonRepository")
    func personRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let person = ModelSamples.person

        try await db.persons.upsert(person)
        let fetched = try await db.persons.find(person.id)

        #expect(fetched == person)
    }

    @Test("Person soft-delete tombstones rather than deletes")
    func personSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)

        try await db.persons.softDelete(ModelSamples.person.id, at: Date())
        #expect(try await db.persons.all().isEmpty)
        #expect(try await db.persons.all(includingDeleted: true).count == 1)
    }

    @Test("Deleting a person nulls out speaker.personId (FK ON DELETE SET NULL)")
    func personDeleteSetsSpeakerPersonIdNull() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.speakers.upsert(ModelSamples.speaker)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM person WHERE id = ?",
                arguments: [ModelSamples.person.id.rawValue]
            )
        }

        let speaker = try await db.speakers.find(ModelSamples.speaker.id)
        #expect(speaker?.personId == nil)
    }

    @Test("PersonRepository.setOwner atomically enforces the single-true-row invariant")
    func setOwnerEnforcesSingleTrueRow() async throws {
        let db = try AppDatabase.makeInMemory()
        var first = ModelSamples.person
        first.isOwner = true
        var second = ModelSamples.person
        second.id = "person-2"
        second.email = "second@example.com"
        second.isOwner = false

        try await db.persons.upsert(first)
        try await db.persons.upsert(second)

        try await db.persons.setOwner(second.id)

        let all = try await db.persons.all()
        let owners = all.filter(\.isOwner)
        #expect(owners.count == 1)
        #expect(owners.first?.id == second.id)

        let previousOwner = try await db.persons.find(first.id)
        #expect(previousOwner?.isOwner == false)
    }

    @Test("PersonRepository.setOwner throws for an unknown person")
    func setOwnerThrowsForUnknownPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        await #expect(throws: PersonRepositoryError.personNotFound("does-not-exist")) {
            try await db.persons.setOwner("does-not-exist")
        }
    }

    // MARK: - Slice 2: profileFact

    @Test("ProfileFact round-trips through ProfileFactRepository (sourceCount computed live)")
    func profileFactRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)
        var fact = ModelSamples.profileFact
        fact.sourceCount = 0 // no sources recorded in this test — the repository computes it live

        try await db.profileFacts.upsert(fact)
        let fetched = try await db.profileFacts.find(fact.id)

        #expect(fetched == fact)
    }

    @Test("ProfileFact soft-delete tombstones rather than deletes")
    func profileFactSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)
        var fact = ModelSamples.profileFact
        fact.sourceCount = 0
        try await db.profileFacts.upsert(fact)

        try await db.profileFacts.softDelete(fact.id, at: Date())
        #expect(try await db.profileFacts.all().isEmpty)
        #expect(try await db.profileFacts.all(includingDeleted: true).count == 1)
    }

    @Test("Deleting a person cascades to their profileFacts (FK ON DELETE CASCADE)")
    func profileFactCascadeDeleteOnPerson() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)
        var fact = ModelSamples.profileFact
        fact.sourceCount = 0
        try await db.profileFacts.upsert(fact)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM person WHERE id = ?",
                arguments: [ModelSamples.person.id.rawValue]
            )
        }

        let all = try await db.profileFacts.all(includingDeleted: true)
        #expect(all.isEmpty)
    }

    // MARK: - Slice 3: series (+ seriesLedger reconciliation, seriesMember)

    @Test("Series round-trips through SeriesRepository, reconciling series ⊕ seriesLedger")
    func seriesRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person) // series.ownerPersonId FK target
        let series = ModelSamples.series

        try await db.series.upsert(series)
        let fetched = try await db.series.find(series.id)

        #expect(fetched == series)
    }

    @Test("Series upsert updates the ledger without wiping structuredJson/updatedFromMeetingId")
    func seriesUpsertPreservesLedgerExtras() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)
        var series = ModelSamples.series
        try await db.series.upsert(series)

        // A field not on `Series` — set via the fine-grained ledger API.
        try await db.series.updateLedger(
            seriesId: series.id,
            ledgerMarkdown: series.ledgerMarkdown,
            structuredJson: "{\"themes\":[]}",
            updatedFromMeetingId: ModelSamples.meeting.id,
            ledgerVersion: series.ledgerVersion,
            at: ModelSamples.laterInstant
        )

        // A plain `upsert(_:)` (e.g. renaming the series) must not clobber that extra state.
        series.title = "Renamed series"
        try await db.series.upsert(series)

        let ledgerRow = try await db.dbWriter.read { rawDb in
            try Row.fetchOne(
                rawDb,
                sql: "SELECT * FROM seriesLedger WHERE seriesId = ?",
                arguments: [series.id.rawValue]
            )
        }
        #expect(ledgerRow?["structuredJson"] as String? == "{\"themes\":[]}")
        #expect(ledgerRow?["updatedFromMeetingId"] as String? == ModelSamples.meeting.id.rawValue)

        let fetched = try await db.series.find(series.id)
        #expect(fetched?.title == "Renamed series")
    }

    @Test("Series with no ledger yet round-trips ledgerVersion as nil")
    func seriesNoLedgerYet() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        var series = ModelSamples.series
        series.id = "series-no-ledger"
        series.ledgerMarkdown = nil
        series.ledgerVersion = nil

        try await db.series.upsert(series)
        let fetched = try await db.series.find(series.id)

        #expect(fetched?.ledgerVersion == nil)
        #expect(fetched?.ledgerMarkdown == nil)
    }

    @Test("Series soft-delete tombstones rather than deletes")
    func seriesSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.series.upsert(ModelSamples.series)

        try await db.series.softDelete(ModelSamples.series.id, at: Date())
        #expect(try await db.series.all().isEmpty)
        #expect(try await db.series.all(includingDeleted: true).count == 1)
    }

    @Test("Deleting the owning person nulls out series.ownerPersonId (FK ON DELETE SET NULL)")
    func seriesOwnerDeleteSetsNull() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.series.upsert(ModelSamples.series)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM person WHERE id = ?",
                arguments: [ModelSamples.person.id.rawValue]
            )
        }

        let fetched = try await db.series.find(ModelSamples.series.id)
        #expect(fetched?.ownerPersonId == nil)
    }

    @Test("Series membership: add/list/remove meetings via seriesMember")
    func seriesMembership() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.series.upsert(ModelSamples.series)
        try await db.meetings.upsert(ModelSamples.meeting)

        try await db.series.addMember(
            seriesId: ModelSamples.series.id,
            meetingId: ModelSamples.meeting.id,
            occurrenceTime: "2023-11-14T22:00:00Z",
            linkSource: "calendar"
        )

        let members = try await db.series.meetingIds(inSeries: ModelSamples.series.id)
        #expect(members == [ModelSamples.meeting.id])

        let removed = try await db.series.removeMember(
            seriesId: ModelSamples.series.id,
            meetingId: ModelSamples.meeting.id
        )
        #expect(removed)
        let afterRemove = try await db.series.meetingIds(inSeries: ModelSamples.series.id)
        #expect(afterRemove.isEmpty)
    }

    @Test("Deleting a series cascades to its seriesLedger and seriesMember rows (FK ON DELETE CASCADE)")
    func seriesCascadeDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.persons.upsert(ModelSamples.person)
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.series.upsert(ModelSamples.series)
        try await db.series.addMember(seriesId: ModelSamples.series.id, meetingId: ModelSamples.meeting.id)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM series WHERE id = ?",
                arguments: [ModelSamples.series.id.rawValue]
            )
        }

        let ledgerCount = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM seriesLedger") ?? -1
        }
        let memberCount = try await db.dbWriter.read { rawDb in
            try Int.fetchOne(rawDb, sql: "SELECT COUNT(*) FROM seriesMember") ?? -1
        }
        #expect(ledgerCount == 0)
        #expect(memberCount == 0)
    }

    // MARK: - Slice 3: calendarEvent

    @Test("CalendarEvent round-trips through CalendarEventRepository, including attendees JSON")
    func calendarEventRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting) // calendarEvent.meetingId FK target
        let event = ModelSamples.calendarEvent

        try await db.calendarEvents.upsert(event)
        let fetched = try await db.calendarEvents.find(event.id)

        #expect(fetched == event)
    }

    @Test("CalendarEvent round-trips recurrence signals and multiple attendees")
    func calendarEventRecurrenceRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        var event = ModelSamples.calendarEvent
        event.id = "event-recurring"
        event.meetingId = nil
        event.attendees = [
            Attendee(name: "Guest One", email: "one@example.com"),
            Attendee(name: nil, email: "two@example.com")
        ]
        event.seriesKey = "ext-abc-123"
        event.hasRecurrence = true
        event.occurrenceDate = instantForCalendarTests
        event.isDetached = false

        try await db.calendarEvents.upsert(event)
        let fetched = try await db.calendarEvents.find(event.id)

        #expect(fetched == event)
    }

    @Test("CalendarEvent soft-delete tombstones rather than deletes")
    func calendarEventSoftDelete() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting) // calendarEvent.meetingId FK target
        try await db.calendarEvents.upsert(ModelSamples.calendarEvent)

        try await db.calendarEvents.softDelete(ModelSamples.calendarEvent.id, at: Date())
        #expect(try await db.calendarEvents.all().isEmpty)
        #expect(try await db.calendarEvents.all(includingDeleted: true).count == 1)
    }

    @Test("CalendarEvent.forMeeting scopes by meetingId and excludes tombstoned rows")
    func calendarEventForMeeting() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.calendarEvents.upsert(ModelSamples.calendarEvent)

        let forMeeting = try await db.calendarEvents.forMeeting(ModelSamples.meeting.id)
        #expect(forMeeting.count == 1)

        try await db.calendarEvents.softDelete(ModelSamples.calendarEvent.id, at: Date())
        let afterDelete = try await db.calendarEvents.forMeeting(ModelSamples.meeting.id)
        #expect(afterDelete.isEmpty)
    }

    @Test("Deleting a linked meeting nulls out calendarEvent.meetingId (FK ON DELETE SET NULL)")
    func calendarEventMeetingDeleteSetsNull() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.meetings.upsert(ModelSamples.meeting)
        try await db.calendarEvents.upsert(ModelSamples.calendarEvent)

        try await db.dbWriter.write { rawDb in
            try rawDb.execute(
                sql: "DELETE FROM meeting WHERE id = ?",
                arguments: [ModelSamples.meeting.id.rawValue]
            )
        }

        let fetched = try await db.calendarEvents.find(ModelSamples.calendarEvent.id)
        #expect(fetched?.meetingId == nil)
    }

    // MARK: - Slice 3: calendarSyncSetting

    @Test("calendarSyncSetting round-trips through CalendarEventRepository")
    func calendarSyncSettingRoundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1",
            calendarTitle: "Work",
            color: "#E8A020",
            selected: true
        )

        let settings = try await db.calendarEvents.syncSettings()
        #expect(settings.count == 1)
        #expect(settings.first?.calendarId == "cal-1")
        #expect(settings.first?.selected == true)

        try await db.calendarEvents.setSyncSetting(
            calendarId: "cal-1",
            calendarTitle: "Work",
            color: "#E8A020",
            selected: false
        )
        let updated = try await db.calendarEvents.syncSettings()
        #expect(updated.count == 1)
        #expect(updated.first?.selected == false)
    }
}

private let instantForCalendarTests = Date(timeIntervalSince1970: 1_700_006_000)
