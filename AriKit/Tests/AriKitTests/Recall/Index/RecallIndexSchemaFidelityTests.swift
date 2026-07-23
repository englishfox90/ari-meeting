//
//  RecallIndexSchemaFidelityTests.swift — introspects the migrated `v1_baseline` schema and
//  asserts the five Recall Slice 2 tables match docs/plans/arikit-recall-slice2.md §4 exactly
//  (plan §6, `RecallIndexSchemaFidelityTests`). Mirrors the Store's own `SchemaFidelityTests`
//  pattern (arikit-store.md §7 test 1).
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

/// Normalizes a declared SQLite column type to its storage affinity family (mirrors
/// `Store/SchemaFidelityTests.swift`'s helper of the same shape).
private func affinity(of declaredType: String) -> String {
    switch declaredType.uppercased() {
    case "REAL", "DOUBLE", "FLOAT": "REAL"
    case "INT", "INTEGER": "INTEGER"
    case "BOOL", "BOOLEAN": "BOOLEAN"
    case let other: other
    }
}

/// The `on_delete` action for one foreign key, read directly off `PRAGMA foreign_key_list` since
/// GRDB's public `ForeignKeyInfo` does not expose the delete rule.
private func onDeleteActions(
    forTable table: String,
    referencing destinationTable: String,
    in queue: DatabaseQueue
) throws -> [String] {
    try queue.read { db in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
            .filter { $0["table"] == destinationTable }
            .map { ($0["on_delete"] as String).uppercased() }
    }
}

@Suite("Recall index schema fidelity — Recall Slice 2")
struct RecallIndexSchemaFidelityTests {
    private func migratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try SchemaMigrator.migrator().migrate(queue)
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

    @Test("recallChunk table matches §4.1")
    func recallChunkSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "recallChunk", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "chunkIndex", type: "INTEGER", notNull: true),
            ExpectedColumn(name: "chunkText", type: "TEXT", notNull: true),
            ExpectedColumn(name: "startTime", type: "REAL", notNull: false),
            ExpectedColumn(name: "endTime", type: "REAL", notNull: false),
            ExpectedColumn(name: "timestampLabel", type: "TEXT", notNull: false),
            ExpectedColumn(name: "embedding", type: "BLOB", notNull: false),
            ExpectedColumn(name: "embeddingModel", type: "TEXT", notNull: false),
            ExpectedColumn(name: "dim", type: "INTEGER", notNull: false),
            ExpectedColumn(name: "tokenEstimate", type: "INTEGER", notNull: false),
            ExpectedColumn(name: "createdAt", type: "TEXT", notNull: true),
            // v2_recall_chunk_source_kind (ask-meetings-tools-and-cards.md §3.2/§7) — additive,
            // NOT NULL DEFAULT 'transcript'.
            ExpectedColumn(name: "sourceKind", type: "TEXT", notNull: true)
        ], table: "recallChunk")
    }

    @Test("recallChunk.meetingId carries a CASCADE FK to meeting (the Swift-added delta)")
    func recallChunkMeetingForeignKeyCascades() throws {
        let queue = try migratedQueue()
        let foreignKeys = try queue.read { db in try db.foreignKeys(on: "recallChunk") }
        #expect(foreignKeys.contains { $0.destinationTable == "meeting" })
        let actions = try onDeleteActions(
            forTable: "recallChunk", referencing: "meeting", in: queue
        )
        #expect(actions == ["CASCADE"])
    }

    @Test("recallIndexState table matches §4.2")
    func recallIndexStateSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "recallIndexState", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "contentHash", type: "TEXT", notNull: true),
            ExpectedColumn(name: "chunkCount", type: "INTEGER", notNull: true),
            ExpectedColumn(name: "embeddingModel", type: "TEXT", notNull: false),
            ExpectedColumn(name: "embeddedCount", type: "INTEGER", notNull: true),
            ExpectedColumn(name: "indexedAt", type: "TEXT", notNull: true)
        ], table: "recallIndexState")
    }

    @Test("recallIndexState.meetingId carries a CASCADE FK to meeting (the Swift-added delta)")
    func recallIndexStateMeetingForeignKeyCascades() throws {
        let queue = try migratedQueue()
        let foreignKeys = try queue.read { db in try db.foreignKeys(on: "recallIndexState") }
        #expect(foreignKeys.contains { $0.destinationTable == "meeting" })
        let actions = try onDeleteActions(
            forTable: "recallIndexState", referencing: "meeting", in: queue
        )
        #expect(actions == ["CASCADE"])
    }

    @Test("recallFts exists as a porter/unicode61 FTS5 virtual table")
    func recallFtsIsFTS5() throws {
        let queue = try migratedQueue()
        let sql = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE name = 'recallFts'"
            )
        }
        let ddl = try #require(sql)
        #expect(ddl.contains("USING fts5") || ddl.contains("USING FTS5"))
        #expect(ddl.contains("porter"))
    }

    @Test("askConversation table matches §4.4 + ari-ask-ui.md Phase 0, meetingId/seriesId SET NULL FKs")
    func askConversationSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "askConversation", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "meetingId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "seriesId", type: "TEXT", notNull: false),
            ExpectedColumn(name: "title", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "TEXT", notNull: true),
            ExpectedColumn(name: "updatedAt", type: "TEXT", notNull: true)
        ], table: "askConversation")

        let meetingActions = try onDeleteActions(
            forTable: "askConversation", referencing: "meeting", in: queue
        )
        #expect(meetingActions == ["SET NULL"])

        let seriesActions = try onDeleteActions(
            forTable: "askConversation", referencing: "series", in: queue
        )
        #expect(seriesActions == ["SET NULL"])
    }

    @Test("askMessage table matches §4.5, conversationId CASCADE FK to askConversation")
    func askMessageSchema() throws {
        let queue = try migratedQueue()
        let actual = try columns(of: "askMessage", in: queue)
        assertColumns(actual, match: [
            ExpectedColumn(name: "id", type: "TEXT", notNull: true),
            ExpectedColumn(name: "conversationId", type: "TEXT", notNull: true),
            ExpectedColumn(name: "role", type: "TEXT", notNull: true),
            ExpectedColumn(name: "content", type: "TEXT", notNull: true),
            ExpectedColumn(name: "sourcesJson", type: "TEXT", notNull: false),
            ExpectedColumn(name: "createdAt", type: "TEXT", notNull: true)
        ], table: "askMessage")

        let actions = try onDeleteActions(
            forTable: "askMessage", referencing: "askConversation", in: queue
        )
        #expect(actions == ["CASCADE"])
    }
}
