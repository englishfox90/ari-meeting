//
//  ImporterFixtureTests.swift — end-to-end tests for the legacy-library importer (plan §5 / §7 test 3).
//
//  Builds a fixture legacy SQLite DB PROGRAMMATICALLY (the real legacy sqlx column shapes, a
//  handful of rows per table incl. the required edge cases: a malformed summary_processes.result,
//  a calendar_event with 2 attendees, a meeting_notes row, and a profile_fact supersession pair),
//  runs the importer against it, and asserts the load-bearing guarantees: full row-count
//  reconciliation (No-Fake-State), idempotency on a second run, the malformed row skipped AND
//  reported (never silently dropped), and that meeting_notes user data survives.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Legacy-library importer — fixture round-trip")
struct ImporterFixtureTests {

    /// A fixed RFC3339 timestamp the mapper's date parser accepts (sqlx/chrono DateTime<Utc> shape).
    static let ts = "2026-07-01T12:00:00Z"

    /// Writes a legacy-shaped SQLite fixture at `url`, then lets its writer connection close before
    /// the importer re-opens the file read-only.
    static func writeFixture(to url: URL) throws {
        let attendeesJSON: String = {
            let attendees = [
                Attendee(name: "Alice", email: "alice@example.com"),
                Attendee(name: "Bob", email: "bob@example.com")
            ]
            let data = try! Models.jsonEncoder.encode(attendees)
            return String(decoding: data, as: UTF8.self)
        }()

        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            // --- schema (only the columns the importer reads; all 14 legacy tables must exist) ---
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

            let ts = Self.ts
            // meetings (2)
            try db.execute(
                sql: "INSERT INTO meetings VALUES ('m1','Meeting One',?,?, '/tmp/ari/m1/audio.mp4','parakeet','v3','anthropic','claude', NULL)",
                arguments: [ts, ts]
            )
            try db.execute(
                sql: "INSERT INTO meetings VALUES ('m2','Meeting Two',?,?, NULL, NULL, NULL, NULL, NULL, NULL)",
                arguments: [ts, ts]
            )
            // persons (owner + non-owner)
            try db.execute(
                sql: "INSERT INTO persons VALUES ('p1','owner@x.com','Owner','CEO','Acme','x.com',NULL,1,?,?)",
                arguments: [ts, ts]
            )
            try db.execute(
                sql: "INSERT INTO persons VALUES ('p2','bob@x.com','Bob',NULL,NULL,NULL,NULL,0,?,?)",
                arguments: [ts, ts]
            )
            // speaker (FK person p1)
            try db.execute(
                sql: "INSERT INTO speakers VALUES ('s1','p1','Owner',?,'nomic',4,1,'provisional',12.5,?,?)",
                arguments: [Data([1, 2, 3, 4]), ts, ts]
            )
            // speaker_segment
            try db.execute(
                sql: "INSERT INTO speaker_segments VALUES ('seg1','m1','s1','c0',0.0,3.0,'microphone',NULL,?)",
                arguments: [ts]
            )
            // transcripts (2, one with speaker)
            try db.execute(sql: "INSERT INTO transcripts VALUES ('t1','m1','Hello there','00:00',0.0,3.0,3.0,'s1')")
            try db.execute(sql: "INSERT INTO transcripts VALUES ('t2','m1','General Kenobi','00:03',3.0,6.0,3.0,NULL)")
            // meeting_notes (user data — must survive)
            try db.execute(
                sql: "INSERT INTO meeting_notes VALUES ('m1','# My note\\n\\nremember this','{\"v\":1}',?,?)",
                arguments: [ts, ts]
            )
            // summary_processes: m1 valid, m2 malformed (skip+report), ghost = orphan whose
            // meeting_id has no matching meetings row (must be COUNTED + skipped, not silently
            // excluded from sourceRowCount — the HIGH finding on the old inner-JOIN read).
            try db.execute(
                sql: "INSERT INTO summary_processes VALUES ('m1',?,?,?)",
                arguments: ["{\"data\":{\"markdown\":\"# Summary\\n\\nBody text\"}}", ts, ts]
            )
            try db.execute(
                sql: "INSERT INTO summary_processes VALUES ('m2',?,?,?)",
                arguments: ["{ this is not valid json", ts, ts]
            )
            try db.execute(
                sql: "INSERT INTO summary_processes VALUES ('ghost-meeting',?,?,?)",
                arguments: ["{\"data\":{\"markdown\":\"orphan summary\"}}", ts, ts]
            )
            // profile_facts supersession pair: fact-a superseded_by fact-b
            try db.execute(
                sql: "INSERT INTO profile_facts VALUES ('fact-a','p1','Old title: VP','role','m1',NULL,'inferred',0.7,'superseded','fact-b',?)",
                arguments: [ts]
            )
            try db.execute(
                sql: "INSERT INTO profile_facts VALUES ('fact-b','p1','Title: CEO','role','m1',NULL,'inferred',0.9,'active',NULL,?)",
                arguments: [ts]
            )
            // profile_fact_source for fact-b
            try db.execute(
                sql: "INSERT INTO profile_fact_sources VALUES ('src1','fact-b','m1','seg-ref','inferred','affirms',0.9,?)",
                arguments: [ts]
            )
            // meeting_series + ledger + member
            try db.execute(
                sql: "INSERT INTO meeting_series VALUES ('ser1','Weekly Sync','wk-1','recurring','weekly','p1',?,?,NULL)",
                arguments: [ts, ts]
            )
            try db
                .execute(
                    sql: "INSERT INTO series_ledger VALUES ('ser1','## Ledger\\n\\nopen items','{\"open\":[]}','m1',3,?,?)",
                    arguments: [ts, ts]
                )
            try db.execute(
                sql: "INSERT INTO meeting_series_members VALUES ('ser1','m1','2026-07-01','auto',?)",
                arguments: [ts]
            )
            // calendar_event with 2 attendees + sync setting
            try db.execute(
                sql: "INSERT INTO calendar_events VALUES ('ev1','cal1','Work','Weekly Sync',?,?,0,'Room 1',NULL,'owner@x.com',?, 'm1','auto','wk-1',1,NULL,0)",
                arguments: [ts, ts, attendeesJSON]
            )
            try db.execute(sql: "INSERT INTO calendar_sync_settings VALUES ('cal1','Work','#1B3A8C',1)")
        }
        // queue deinits at end of scope; importer re-opens read-only.
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ari-legacy-fixture-\(UUID().uuidString).sqlite")
    }

    @Test("Imports every table, fully reconciled, honest about the malformed summary row")
    func importsAndReconciles() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(to: url)

        let store = try AppDatabase.makeInMemory()
        let report = await LegacyDatabaseImporter.run(sourceURL: url, into: store)

        #expect(report.sourceError == nil)
        #expect(report.isFullyReconciled, "every source row must be imported or explicitly skipped")

        // summary_processes: 3 source rows → 1 imported, 2 skipped-and-reported (malformed m2 +
        // the orphan ghost-meeting). The orphan MUST be in sourceRowCount (not silently excluded
        // by an inner JOIN) — this is the regression guard for the reviewer's HIGH finding.
        let summaryResult = try #require(report.tables.first { $0.table == "summary_processes" })
        #expect(summaryResult.sourceRowCount == 3)
        #expect(summaryResult.importedCount == 1)
        #expect(summaryResult.skippedCount == 2)
        #expect(
            summaryResult.skipReasons.contains { $0.contains("m2") },
            "the malformed row must be named in skipReasons, not silently dropped"
        )
        #expect(
            summaryResult.skipReasons.contains { $0.contains("ghost-meeting") },
            "the orphan (no matching meeting) must be counted + reported, not invisible"
        )

        // core data landed
        #expect(try await store.meetings.all().count == 2)
        #expect(try await store.persons.all().count == 2)
        #expect(try await store.transcripts.forMeeting(MeetingID("m1")).count == 2)

        // the valid summary imported with parsed markdown
        let sum = try #require(try await store.summaries.forMeeting(MeetingID("m1")))
        #expect(sum.bodyMarkdown.contains("Body text"))

        // audio referenced (not copied), path preserved verbatim
        let m1 = try #require(try await store.meetings.find(MeetingID("m1")))
        #expect(m1.audioReference?.path == "/tmp/ari/m1/audio.mp4")
    }

    @Test("meeting_notes user data survives the import faithfully")
    func meetingNotesPreserved() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(to: url)

        let store = try AppDatabase.makeInMemory()
        _ = await LegacyDatabaseImporter.run(sourceURL: url, into: store)

        let note = try #require(try await store.meetingNotes.find(MeetingID("m1")))
        #expect(note.notesMarkdown?.contains("remember this") == true)
        #expect(note.notesJson == "{\"v\":1}")
    }

    @Test("profile-fact supersession pointer is set by the two-pass import")
    func supersessionChainResolved() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(to: url)

        let store = try AppDatabase.makeInMemory()
        _ = await LegacyDatabaseImporter.run(sourceURL: url, into: store)

        let factA = try #require(try await store.profileFacts.find(ProfileFactID("fact-a")))
        #expect(factA.supersededBy == ProfileFactID("fact-b"), "pass 2 must set the self-FK pointer")

        let chain = try await store.profileFacts.supersedeChain(from: ProfileFactID("fact-a"))
        #expect(chain.contains { $0.id == ProfileFactID("fact-b") })

        // read-time sourceCount reflects the one real source row on fact-b (No-Fake-State)
        let factBProvenance = try #require(try await store.profileFacts.withProvenance(ProfileFactID("fact-b")))
        #expect(factBProvenance.fact.sourceCount == 1)
    }

    @Test("calendar event round-trips its 2 attendees from the inline JSON blob")
    func calendarAttendeesRoundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(to: url)

        let store = try AppDatabase.makeInMemory()
        _ = await LegacyDatabaseImporter.run(sourceURL: url, into: store)

        let event = try #require(try await store.calendarEvents.find(CalendarEventID("ev1")))
        #expect(event.attendees.count == 2)
        #expect(event.attendees.contains { $0.email == "alice@example.com" })
    }

    @Test("second import run is idempotent — no duplicates, identical end state")
    func idempotentReRun() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeFixture(to: url)

        let store = try AppDatabase.makeInMemory()
        _ = await LegacyDatabaseImporter.run(sourceURL: url, into: store)
        let firstMeetings = try await store.meetings.all().count
        let firstFacts = try await store.profileFacts.all().count

        // run again against the same source into the same store
        let secondReport = await LegacyDatabaseImporter.run(sourceURL: url, into: store)
        #expect(secondReport.isFullyReconciled)
        #expect(try await store.meetings.all().count == firstMeetings)
        #expect(try await store.profileFacts.all().count == firstFacts)
    }

    @Test("a missing legacy file is a reported sourceError, not a crash")
    func missingSourceReported() async throws {
        let store = try AppDatabase.makeInMemory()
        let missing = tempURL() // never written
        let report = await LegacyDatabaseImporter.run(sourceURL: missing, into: store)
        #expect(report.sourceError != nil)
        #expect(report.tables.isEmpty)
    }
}
