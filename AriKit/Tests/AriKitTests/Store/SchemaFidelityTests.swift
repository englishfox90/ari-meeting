//
//  SchemaFidelityTests.swift — introspects the migrated `v1_baseline` schema and asserts it
//  matches docs/plans/arikit-store.md §4.1–§4.4 exactly (plan §7 test 1, foundation slice).
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

    @Test("only the four foundation-slice tables exist")
    func noExtraTablesYet() throws {
        let queue = try migratedQueue()
        let tableNames = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'"
            )
        }
        #expect(Set(tableNames) == ["meeting", "speaker", "speakerSegment", "transcript"])
    }
}
