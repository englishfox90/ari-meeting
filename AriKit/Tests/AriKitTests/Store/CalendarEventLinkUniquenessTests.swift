//
//  CalendarEventLinkUniquenessTests.swift — strict 1:1 meeting↔calendar-event coverage
//  (docs/plans/calendar-series-intelligence.md §7 step 1, feature 4; acceptance tests §5 1–6).
//
//  Covers the partial UNIQUE index (`SchemaMigrator`), the clear-competitors write added to
//  `setManualLink`/`setAutoLink`/`upsert` (`CalendarEventRepository`), and the legacy importer's
//  deterministic dedupe pre-pass (`LegacyDatabaseImporter.importCalendarEvents`). Also covers the
//  repository-level read `linkedEvent(forMeeting:)` needed by feature 3's view model (plan §7
//  step-1 scope note: "whatever extension test 26's tombstone-read case needs at the repository
//  level").
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("CalendarEventRepository — strict 1:1 meeting↔event")
struct CalendarEventLinkUniquenessTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func calendarEvent(
        id: CalendarEventID,
        calendarId: String = "cal-1",
        title: String = "Sync",
        start: Date,
        end: Date
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarId: calendarId, calendarTitle: "Work", title: title,
            startTime: start, endTime: end, isAllDay: false, attendees: []
        )
    }

    private func meeting(id: MeetingID, createdAt: Date) -> Meeting {
        Meeting(id: id, title: "Recording", createdAt: createdAt, updatedAt: createdAt)
    }

    // MARK: - Test 1: setManualLink clears the competitor in the same tx

    @Test("setManualLink to event B for meeting M clears event A's link in the same transaction")
    func setManualLinkClearsCompetitor() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-b", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)

        try await db.calendarEvents.setManualLink(eventId: "ev-b", meetingId: meetingId)

        let eventA = try #require(try await db.calendarEvents.find("ev-a"))
        #expect(eventA.meetingId == nil)
        #expect(eventA.linkSource == nil)

        let eventB = try #require(try await db.calendarEvents.find("ev-b"))
        #expect(eventB.meetingId == meetingId)
        #expect(eventB.linkSource == .manual)
    }

    // MARK: - Test 2: setAutoLink re-points a stale auto link but never steals from manual

    @Test("setAutoLink re-points from a stale auto link")
    func setAutoLinkRepointsStaleAutoLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        let staleMeetingId: MeetingID = "meeting-stale"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.meetings.upsert(meeting(id: staleMeetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-b", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        // ev-a already auto-linked to a DIFFERENT meeting than the one we're about to auto-link
        // ev-b to; this exercises the general "re-point a competitor" path, not the manual guard.
        try await db.calendarEvents.setAutoLink(eventId: "ev-a", meetingId: meetingId)

        try await db.calendarEvents.setAutoLink(eventId: "ev-b", meetingId: meetingId)

        let eventA = try #require(try await db.calendarEvents.find("ev-a"))
        #expect(eventA.meetingId == nil)
        #expect(eventA.linkSource == nil)

        let eventB = try #require(try await db.calendarEvents.find("ev-b"))
        #expect(eventB.meetingId == meetingId)
        #expect(eventB.linkSource == .auto)
    }

    @Test("setAutoLink is skipped entirely when the meeting is manually linked elsewhere (manual wins, no partial write)")
    func setAutoLinkSkippedWhenManuallyLinkedElsewhere() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-manual", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-auto-candidate", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-manual", meetingId: meetingId)

        try await db.calendarEvents.setAutoLink(eventId: "ev-auto-candidate", meetingId: meetingId)

        // No steal: the manual link is untouched...
        let manualEvent = try #require(try await db.calendarEvents.find("ev-manual"))
        #expect(manualEvent.meetingId == meetingId)
        #expect(manualEvent.linkSource == .manual)

        // ...and no partial write: the candidate event never got the link either.
        let candidateEvent = try #require(try await db.calendarEvents.find("ev-auto-candidate"))
        #expect(candidateEvent.meetingId == nil)
        #expect(candidateEvent.linkSource == nil)
    }

    @Test("setAutoLink returns false (and writes nothing) when the meeting is manually linked elsewhere")
    func setAutoLinkReturnsFalseWhenManuallyLinkedElsewhere() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-manual", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-auto-candidate", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-manual", meetingId: meetingId)

        let linked = try await db.calendarEvents.setAutoLink(eventId: "ev-auto-candidate", meetingId: meetingId)
        #expect(linked == false)
    }

    // MARK: - M1: a tombstoned manual competitor never blocks auto-link

    @Test("A tombstoned manual competitor doesn't block auto-link; its (already-cleared) row stays cleared")
    func tombstonedManualCompetitorDoesNotBlockAutoLink() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-old-manual", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-auto-candidate", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-old-manual", meetingId: meetingId)
        try await db.calendarEvents.softDelete("ev-old-manual", at: base)

        let linked = try await db.calendarEvents.setAutoLink(eventId: "ev-auto-candidate", meetingId: meetingId)
        #expect(linked == true)

        let candidateEvent = try #require(try await db.calendarEvents.find("ev-auto-candidate"))
        #expect(candidateEvent.meetingId == meetingId)
        #expect(candidateEvent.linkSource == .auto)

        // `softDelete` alone never touches `meetingId`/`linkSource` — the tombstoned row still
        // carried the old manual link going in. The auto-link's clearing UPDATE (which never
        // filters on `isDeleted`) must still clear it in the same transaction.
        let oldRecord = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-old-manual")
        }
        #expect(oldRecord?.isDeleted == true)
        #expect(oldRecord?.meetingId == nil)
        #expect(oldRecord?.linkSource == nil)
    }

    // MARK: - Test 3: upsert (importer path) clears a competitor

    @Test("upsert of an event carrying a meetingId clears a competitor")
    func upsertClearsCompetitor() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)

        var incoming = calendarEvent(id: "ev-b", start: base, end: base.addingTimeInterval(1800))
        incoming.meetingId = meetingId
        incoming.linkSource = .manual
        try await db.calendarEvents.upsert(incoming)

        let eventA = try #require(try await db.calendarEvents.find("ev-a"))
        #expect(eventA.meetingId == nil)
        #expect(eventA.linkSource == nil)

        let eventB = try #require(try await db.calendarEvents.find("ev-b"))
        #expect(eventB.meetingId == meetingId)
        #expect(eventB.linkSource == .manual)
    }

    // MARK: - Test 4: the partial UNIQUE index is the backstop

    @Test("A raw duplicate INSERT violating the partial index throws; multiple NULL-meetingId rows still coexist")
    func partialIndexRejectsDuplicateLinkButAllowsMultipleNulls() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-b", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-c", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)

        // Two unlinked (meetingId == NULL) rows coexist fine — the index is partial.
        #expect(try await db.calendarEvents.find("ev-b") != nil)
        #expect(try await db.calendarEvents.find("ev-c") != nil)

        // A raw INSERT that bypasses the repository's clear-competitors write must still be
        // rejected by the partial UNIQUE index itself — the backstop for any future code path
        // that forgets (plan §2.1/§3).
        await #expect(throws: (any Error).self) {
            try await db.dbWriter.write { conn in
                guard var duplicate = try CalendarEventRecord.fetchOne(conn, key: "ev-b") else {
                    Issue.record("fixture row ev-b missing")
                    return
                }
                duplicate.id = "ev-duplicate"
                duplicate.meetingId = meetingId.rawValue
                duplicate.linkSource = CalendarLinkSource.manual.rawValue
                try duplicate.insert(conn)
            }
        }
    }

    // MARK: - Test 5: tombstoned competitor rows are cleared too

    @Test("A tombstoned competitor's meetingId is cleared too — the index has no isDeleted filter")
    func tombstonedCompetitorIsClearedToo() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [
                calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800)),
                calendarEvent(id: "ev-b", start: base, end: base.addingTimeInterval(1800))
            ],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)
        try await db.calendarEvents.softDelete("ev-a", at: base)

        try await db.calendarEvents.setManualLink(eventId: "ev-b", meetingId: meetingId)

        // ev-a is tombstoned AND its link was cleared (must succeed without violating the index).
        let recordA = try await db.dbWriter.read { conn in
            try CalendarEventRecord.fetchOne(conn, key: "ev-a")
        }
        #expect(recordA?.isDeleted == true)
        #expect(recordA?.meetingId == nil)
        #expect(recordA?.linkSource == nil)

        let eventB = try #require(try await db.calendarEvents.find("ev-b"))
        #expect(eventB.meetingId == meetingId)
        #expect(eventB.linkSource == .manual)
    }

    // MARK: - Test 6: importer dedupe pre-pass

    @Test("Importer dedupe: two legacy rows linked to one meeting → the later start_time keeps the link, a warning is emitted")
    func importerDedupePrefersLaterStartTime() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixtureWithDuplicateCalendarLinks(to: url)

        let store = try AppDatabase.makeInMemory()
        let report = await LegacyDatabaseImporter.run(sourceURL: url, into: store)

        #expect(report.sourceError == nil)

        let earlier = try await store.calendarEvents.find("ev-earlier")
        let later = try await store.calendarEvents.find("ev-later")
        #expect(earlier?.meetingId == nil)
        #expect(earlier?.linkSource == nil)
        #expect(later?.meetingId == "m1")
        #expect(later?.linkSource == .manual)

        #expect(
            report.warnings.contains { $0.contains("ev-earlier") && $0.contains("dropped duplicate link") },
            "expected a warning naming the dropped duplicate link; got: \(report.warnings)"
        )
    }

    // MARK: - Repository-level read for feature 3 (tombstone-read case)

    @Test("linkedEvent(forMeeting:) returns nil, not the tombstoned row, when the only link is on a deleted event")
    func linkedEventExcludesTombstonedRow() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-a", start: base, end: base.addingTimeInterval(1800))], at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)

        #expect(try await db.calendarEvents.linkedEvent(forMeeting: meetingId) != nil)

        try await db.calendarEvents.softDelete("ev-a", at: base)

        #expect(try await db.calendarEvents.linkedEvent(forMeeting: meetingId) == nil)
    }

    @Test("linkedEvent(forMeeting:) returns the live linked event")
    func linkedEventReturnsLiveEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        let meetingId: MeetingID = "meeting-1"
        try await db.meetings.upsert(meeting(id: meetingId, createdAt: base))
        try await db.calendarEvents.syncUpsert(
            [calendarEvent(id: "ev-a", title: "Standup", start: base, end: base.addingTimeInterval(1800))],
            at: base
        )
        try await db.calendarEvents.setManualLink(eventId: "ev-a", meetingId: meetingId)

        let event = try #require(try await db.calendarEvents.linkedEvent(forMeeting: meetingId))
        #expect(event.id == "ev-a")
        #expect(event.title == "Standup")
    }

    // MARK: - Fixture helper (mirrors ImporterFixtureTests's programmatic legacy-shape pattern)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ari-legacy-calendar-dedupe-fixture-\(UUID().uuidString).sqlite")
    }

    private func writeFixtureWithDuplicateCalendarLinks(to url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE meetings (id TEXT PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT,
                    folder_path TEXT, transcription_provider TEXT, transcription_model TEXT,
                    summary_provider TEXT, summary_model TEXT, template_id TEXT);
                CREATE TABLE persons (id TEXT PRIMARY KEY, email TEXT, display_name TEXT, role TEXT,
                    organization TEXT, domain TEXT, notes TEXT, is_owner INTEGER, created_at TEXT, updated_at TEXT);
                CREATE TABLE speakers (id TEXT PRIMARY KEY, person_id TEXT, label TEXT, centroid BLOB,
                    embedding_model TEXT, dim INTEGER, samples INTEGER, enrollment_state TEXT,
                    total_speech_secs REAL, created_at TEXT, updated_at TEXT);
                CREATE TABLE speaker_segments (id TEXT PRIMARY KEY, meeting_id TEXT, speaker_id TEXT,
                    cluster_key TEXT, start_time REAL, end_time REAL, source TEXT, embedding BLOB, created_at TEXT);
                CREATE TABLE transcripts (id TEXT PRIMARY KEY, meeting_id TEXT, transcript TEXT, timestamp TEXT,
                    audio_start_time REAL, audio_end_time REAL, duration REAL, speaker_id TEXT);
                CREATE TABLE meeting_notes (meeting_id TEXT PRIMARY KEY, notes_markdown TEXT, notes_json TEXT,
                    created_at TEXT, updated_at TEXT);
                CREATE TABLE summary_processes (meeting_id TEXT PRIMARY KEY, result TEXT, created_at TEXT, updated_at TEXT);
                CREATE TABLE profile_facts (id TEXT PRIMARY KEY, person_id TEXT, fact_text TEXT, fact_kind TEXT,
                    source_meeting_id TEXT, source_segment_ref TEXT, source_kind TEXT, confidence REAL,
                    status TEXT, superseded_by TEXT, created_at TEXT);
                CREATE TABLE profile_fact_sources (id TEXT PRIMARY KEY, fact_id TEXT, meeting_id TEXT,
                    segment_ref TEXT, source_kind TEXT, relation TEXT, confidence REAL, observed_at TEXT);
                CREATE TABLE meeting_series (id TEXT PRIMARY KEY, title TEXT, series_key TEXT, detected_type TEXT,
                    cadence TEXT, owner_person_id TEXT, created_at TEXT, updated_at TEXT, template_id TEXT);
                CREATE TABLE series_ledger (series_id TEXT PRIMARY KEY, ledger_markdown TEXT, structured_json TEXT,
                    updated_from_meeting_id TEXT, version INTEGER, created_at TEXT, updated_at TEXT);
                CREATE TABLE meeting_series_members (series_id TEXT, meeting_id TEXT, occurrence_time TEXT,
                    link_source TEXT, created_at TEXT, PRIMARY KEY (series_id, meeting_id));
                CREATE TABLE calendar_events (id TEXT PRIMARY KEY, calendar_id TEXT, calendar_title TEXT, title TEXT,
                    start_time TEXT, end_time TEXT, is_all_day INTEGER, location TEXT, notes TEXT, organizer TEXT,
                    attendees TEXT, meeting_id TEXT, link_source TEXT, series_key TEXT, has_recurrence INTEGER,
                    occurrence_date TEXT, is_detached INTEGER);
                CREATE TABLE calendar_sync_settings (calendar_id TEXT PRIMARY KEY, calendar_title TEXT, color TEXT, selected INTEGER);
            """)

            let ts = "2026-07-01T12:00:00Z"
            try db.execute(
                sql: "INSERT INTO meetings VALUES ('m1','Meeting One',?,?, NULL, NULL, NULL, NULL, NULL, NULL)",
                arguments: [ts, ts]
            )

            // Two legacy rows both claim meeting m1 — "shouldn't happen" per calendar.rs:286-287,
            // but the importer must still resolve it deterministically. ev-later starts after
            // ev-earlier and must keep the link; ev-earlier's link is dropped and reported.
            try db.execute(
                sql: """
                INSERT INTO calendar_events VALUES
                ('ev-earlier','cal1','Work','Earlier Occurrence','2026-06-01T09:00:00Z','2026-06-01T09:30:00Z',
                 0,NULL,NULL,NULL,'[]','m1','manual',NULL,NULL,NULL,NULL)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO calendar_events VALUES
                ('ev-later','cal1','Work','Later Occurrence','2026-06-08T09:00:00Z','2026-06-08T09:30:00Z',
                 0,NULL,NULL,NULL,'[]','m1','manual',NULL,NULL,NULL,NULL)
                """
            )
        }
    }
}
