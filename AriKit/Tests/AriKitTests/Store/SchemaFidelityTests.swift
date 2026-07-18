//
//  SchemaFidelityTests.swift — introspects the migrated `v1_baseline` schema and asserts it
//  matches docs/plans/arikit-store.md §4.1–§4.6, §4.9, §4.12 exactly (plan §7 test 1).
//
//  Foundation slice (plan §10 steps 1–2) covered `meeting`/`speaker`/`speakerSegment`/
//  `transcript`. Slice 2 (plan §10 steps 3–5) adds `summary`, `meetingNote`, `person`,
//  `profileFact`, `profileFactSource`. Slice 3 (plan §10 step 6) adds `series`, `seriesLedger`,
//  `seriesMember`, `calendarEvent`, `calendarSyncSetting`.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

/// One expected column: name + declared SQLite type affinity + NOT NULL-ness.
private struct ExpectedColumn {
    let name: String
    let type: String
    let notNull: Bool
}

/// Normalizes a declared SQLite column type to its storage affinity family, so `REAL` (the plan's
/// vocabulary, §4) and `DOUBLE` (what GRDB actually declares for `.double` columns) compare equal
/// — both are the SQLite REAL affinity, just different spellings of the same declared type.
private func affinity(of declaredType: String) -> String {
    switch declaredType.uppercased() {
    case "REAL", "DOUBLE", "FLOAT": "REAL"
    case "INT", "INTEGER": "INTEGER"
    case "BOOL", "BOOLEAN": "BOOLEAN"
    case let other: other
    }
}

@Suite("Schema fidelity — v1_baseline core tables")
struct SchemaFidelityTests {
    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SchemaMigrator.migrator.migrate(queue)
        return queue
    }

    private func columns(of table: String, in queue: DatabaseQueue) throws -> [ColumnInfo] {
        try queue.read { db in try db.columns(in: table) }
    }

    private func assertColumns(
        _ actual: [ColumnInfo],
        match expected: [ExpectedColumn],
        table: String
    ) {
        let actualNames = Set(actual.map(\.name))
        let expectedNames = Set(expected.map(\.name))
        #expect(actualNames == expectedNames, "\(table): column set mismatch")

        for column in expected {
            guard let found = actual.first(where: { $0.name == column.name }) else { continue }
            #expect(
                affinity(of: found.type) == affinity(of: column.type),
                "\(table).\(column.name): expected type \(column.type), got \(found.type)"
            )
            #expect(
                found.isNotNull == column.notNull,
                "\(table).\(column.name): expected notNull=\(column.notNull), got \(found.isNotNull)"
            )
        }
    }

    @Test("meeting table matches §4.1")
    func meetingSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "meeting", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "title", type: "TEXT", notNull: true),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "audioReferencePath", type: "TEXT", notNull: false),
            ExpectedColumn(name: "transcriptionProvider", type: "TEXT", notNull: false),
            ExpectedColumn(name: "transcriptionModel", type: "TEXT", notNull: false),
            ExpectedColumn(name: "summaryProvider", type: "TEXT", notNull: false),
            ExpectedColumn(name: "summaryModel", type: "TEXT", notNull: false),
            ExpectedColumn(name: "templateId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "meeting")
    }

    @Test("transcript table matches §4.2")
    func transcriptSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "transcript", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "transcript", type: "TEXT", notNull: true),
            ExpectedColumn(name: "timestamp", type: "TEXT", notNull: true),
            ExpectedColumn(name: "audioStartTime", type: "REAL", notNull: false),
            ExpectedColumn(name: "audioEndTime", type: "REAL", notNull: false),
            ExpectedColumn(name: "duration", type: "REAL", notNull: false),
            ExpectedColumn(name: "speakerId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "transcript")

        // Confirm the dropped/dead columns really are absent (plan §4.2/§4.10).
        let names = Set(actual.map(\.name))
        #expect(!names.contains("speaker"))
        #expect(!names.contains("summary"))
        #expect(!names.contains("action_items"))
        #expect(!names.contains("key_points"))
    }

    @Test("speaker table matches §4.3")
    func speakerSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "speaker", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "personId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "label", type: "TEXT", notNull: false),
            ExpectedColumn(name: "centroid", type: "BLOB", notNull: true),
            ExpectedColumn(name: "embeddingModel", type: "TEXT", notNull: true),
            ExpectedColumn(name: "dim", type: "INTEGER", notNull: true),
            ExpectedColumn(name: "samples", type: "INTEGER", notNull: true),
            ExpectedColumn(name: "enrollmentState", type: "TEXT", notNull: true),
            ExpectedColumn(name: "totalSpeechSecs", type: "REAL", notNull: true),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "speaker")
    }

    @Test("speakerSegment table matches §4.4 (no tombstone columns yet)")
    func speakerSegmentSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "speakerSegment", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "speakerId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "clusterKey", type: "TEXT", notNull: true),
            ExpectedColumn(name: "startTime", type: "REAL", notNull: true),
            ExpectedColumn(name: "endTime", type: "REAL", notNull: true),
            ExpectedColumn(name: "source", type: "TEXT", notNull: true),
            ExpectedColumn(name: "embedding", type: "BLOB", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true)
        ], table: "speakerSegment")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("isDeleted"))
        #expect(!names.contains("deletedAt"))
    }

    @Test("foreign keys are enabled")
    func foreignKeysPragma() throws {
        let queue = try migratedQueue()
        let enabled = try queue.read { db in
            try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
        }
        #expect(enabled)
    }

    @Test("only the foundation-slice + slice-2 + slice-3 tables exist")
    func noExtraTablesYet() throws {
        let queue = try migratedQueue()
        let tableNames = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
            )
        }
        #expect(Set(tableNames) == [
            "meeting", "speaker", "speakerSegment", "transcript",
            "person", "profileFact", "profileFactSource", "summary", "meetingNote",
            "series", "seriesLedger", "seriesMember", "calendarEvent", "calendarSyncSetting"
        ])
    }

    @Test("person table matches §4.5")
    func personSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "person", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "email", type: "TEXT", notNull: false),
            ExpectedColumn(name: "displayName", type: "TEXT", notNull: true),
            ExpectedColumn(name: "role", type: "TEXT", notNull: false),
            ExpectedColumn(name: "organization", type: "TEXT", notNull: false),
            ExpectedColumn(name: "domain", type: "TEXT", notNull: false),
            ExpectedColumn(name: "notes", type: "TEXT", notNull: false),
            ExpectedColumn(name: "isOwner", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "person")
    }

    @Test("speaker.personId now carries an inline FK to person")
    func speakerPersonForeignKey() throws {
        let queue = try migratedQueue()
        let foreignKeys = try queue.read { db in try db.foreignKeys(on: "speaker") }
        let personFK = foreignKeys.first { $0.destinationTable == "person" }
        #expect(personFK != nil, "speaker.personId should reference person(id)")
    }

    @Test("profileFact table matches §4.6 (sourceMeetingTitle/sourceCount NOT columns)")
    func profileFactSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "profileFact", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "personId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "factText", type: "TEXT", notNull: true),
            ExpectedColumn(name: "factKind", type: "TEXT", notNull: true),
            ExpectedColumn(name: "sourceMeetingId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "sourceSegmentRef", type: "TEXT", notNull: false),
            ExpectedColumn(name: "origin", type: "TEXT", notNull: true),
            ExpectedColumn(name: "confidence", type: "REAL", notNull: true),
            ExpectedColumn(name: "status", type: "TEXT", notNull: true),
            ExpectedColumn(name: "supersededBy", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "profileFact")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("sourceMeetingTitle"))
        #expect(!names.contains("sourceCount"))
    }

    @Test("profileFactSource table matches §4.6 (tombstones folded in per slice-2 scope)")
    func profileFactSourceSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "profileFactSource", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "factId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "segmentRef", type: "TEXT", notNull: false),
            ExpectedColumn(name: "origin", type: "TEXT", notNull: true),
            ExpectedColumn(name: "relation", type: "TEXT", notNull: true),
            ExpectedColumn(name: "confidence", type: "REAL", notNull: true),
            ExpectedColumn(name: "observedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "profileFactSource")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("meetingTitle"))
    }

    @Test("series table matches §4.7")
    func seriesSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "series", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "seriesKey", type: "TEXT", notNull: false),
            ExpectedColumn(name: "title", type: "TEXT", notNull: true),
            ExpectedColumn(name: "detectedType", type: "TEXT", notNull: false),
            ExpectedColumn(name: "cadence", type: "TEXT", notNull: false),
            ExpectedColumn(name: "ownerPersonId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "templateId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "series")
    }

    @Test("series.ownerPersonId carries an inline FK to person")
    func seriesOwnerForeignKey() throws {
        let queue = try migratedQueue()
        let foreignKeys = try queue.read { db in try db.foreignKeys(on: "series") }
        let personFK = foreignKeys.first { $0.destinationTable == "person" }
        #expect(personFK != nil, "series.ownerPersonId should reference person(id)")
    }

    @Test("seriesLedger table matches §4.7 (no tombstone columns)")
    func seriesLedgerSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "seriesLedger", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "seriesId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "ledgerMarkdown", type: "TEXT", notNull: false),
            ExpectedColumn(name: "structuredJson", type: "TEXT", notNull: false),
            ExpectedColumn(name: "updatedFromMeetingId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "ledgerVersion", type: "INTEGER", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true)
        ], table: "seriesLedger")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("isDeleted"))
        #expect(!names.contains("deletedAt"))
    }

    @Test("seriesMember table matches §4.7 (composite PK, no tombstone columns)")
    func seriesMemberSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "seriesMember", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "seriesId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "occurrenceTime", type: "TEXT", notNull: false),
            ExpectedColumn(name: "linkSource", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true)
        ], table: "seriesMember")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("isDeleted"))
        #expect(!names.contains("deletedAt"))

        let primaryKey = try queue.read { db in try db.primaryKey("seriesMember") }
        #expect(Set(primaryKey.columns) == ["seriesId", "meetingId"])
    }

    @Test("calendarEvent table matches §4.8")
    func calendarEventSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "calendarEvent", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "calendarId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "calendarTitle", type: "TEXT", notNull: false),
            ExpectedColumn(name: "title", type: "TEXT", notNull: true),
            ExpectedColumn(name: "startTime", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "endTime", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isAllDay", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "location", type: "TEXT", notNull: false),
            ExpectedColumn(name: "notes", type: "TEXT", notNull: false),
            ExpectedColumn(name: "organizer", type: "TEXT", notNull: false),
            ExpectedColumn(name: "attendeesJson", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "linkSource", type: "TEXT", notNull: false),
            ExpectedColumn(name: "seriesKey", type: "TEXT", notNull: false),
            ExpectedColumn(name: "hasRecurrence", type: "BOOLEAN", notNull: false),
            ExpectedColumn(name: "occurrenceDate", type: "DATETIME", notNull: false),
            ExpectedColumn(name: "isDetached", type: "BOOLEAN", notNull: false),
            ExpectedColumn(name: "syncedAt", type: "DATETIME", notNull: false),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "calendarEvent")

        // No separate `attendee` link table — attendees are kept inline as JSON (§0.1(2)).
        let tableNames = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'attendee'"
            )
        }
        #expect(tableNames.isEmpty)
    }

    @Test("calendarSyncSetting table matches §4.8 (no tombstone columns)")
    func calendarSyncSettingSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "calendarSyncSetting", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "calendarId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "calendarTitle", type: "TEXT", notNull: false),
            ExpectedColumn(name: "color", type: "TEXT", notNull: false),
            ExpectedColumn(name: "selected", type: "BOOLEAN", notNull: true)
        ], table: "calendarSyncSetting")

        let names = Set(actual.map(\.name))
        #expect(!names.contains("isDeleted"))
        #expect(!names.contains("deletedAt"))
    }

    @Test("summary table matches §4.9")
    func summarySchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "summary", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "bodyMarkdown", type: "TEXT", notNull: true),
            ExpectedColumn(name: "provider", type: "TEXT", notNull: false),
            ExpectedColumn(name: "model", type: "TEXT", notNull: false),
            ExpectedColumn(name: "templateId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "summary")
    }

    @Test("meetingNote table matches §4.12 (PK is meetingId itself, per the legacy row shape)")
    func meetingNoteSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "meetingNote", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "notesMarkdown", type: "TEXT", notNull: false),
            ExpectedColumn(name: "notesJson", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "DATETIME", notNull: true),
            ExpectedColumn(name: "isDeleted", type: "BOOLEAN", notNull: true),
            ExpectedColumn(name: "deletedAt", type: "DATETIME", notNull: false)
        ], table: "meetingNote")

        // No separate synthetic `id` column — the legacy `meeting_notes` row's PK is `meeting_id`.
        let names = Set(actual.map(\.name))
        #expect(!names.contains("id"))
    }
}
