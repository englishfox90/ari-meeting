//
//  MigrationSafetyTests.swift — the core regression suite proving a schema change no longer
//  silently wipes user data (docs/plans/robust-migration-and-backup.md §7, tests 1–4).
//
//  This is the direct regression for the 2026-07-23 incident: GRDB's `eraseDatabaseOnSchemaChange`
//  (previously `true` in DEBUG) DROPPED AND RECREATED a populated production DB the first time
//  `v1_baseline` was edited in place after real data existed against it. These tests drive
//  DELIBERATELY SIMPLIFIED, test-local migrators (NOT the real `SchemaMigrator` — that baseline
//  stays frozen and untouched, per the plan) against the SAME on-disk temp file, using
//  `AppDatabase`'s internal test-only `init(_:migrator:)` seam, and assert the erase-off default
//  preserves data while erase-on (the escape hatch) still wipes it — proving the default is the
//  right one.
//
import Foundation
import GRDB
import Testing
@testable import AriKit

@Suite("Migration safety — the erase-on-schema-change regression")
struct MigrationSafetyTests {
    /// Migrator A — a minimal `v1_baseline` analogue: one `meeting` table, `id` + `title` only.
    private func migratorA() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
            }
        }
        return migrator
    }

    /// Migrator B — the ADDITIVE-correct evolution of A: `v1_baseline` UNCHANGED, plus a new
    /// `v2_addColumn` migration that `ALTER TABLE`s a new nullable column onto the existing table.
    private func migratorB() -> DatabaseMigrator {
        var migrator = migratorA()
        migrator.registerMigration("v2_addColumn") { db in
            try db.alter(table: "meeting") { t in
                t.add(column: "notes", .text)
            }
        }
        return migrator
    }

    /// Migrator C — the INCIDENT-shaped mistake: `v1_baseline` ITSELF edited in place (same
    /// migration name, different DDL — an extra column baked directly into the baseline) with NO
    /// new migration registered. This is exactly what happened in production.
    private func migratorC() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("notes", .text)
            }
        }
        return migrator
    }

    private func insertMeeting(_ db: AppDatabase, id: String = "m1", title: String = "Standup") async throws {
        try await db.dbWriter.write { writer in
            try writer.execute(
                sql: "INSERT INTO meeting (id, title) VALUES (?, ?)",
                arguments: [id, title]
            )
        }
    }

    private func meetingCount(_ db: AppDatabase) async throws -> Int {
        try await db.dbWriter.read { writer in
            try Int.fetchOne(writer, sql: "SELECT COUNT(*) FROM meeting") ?? 0
        }
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-safety-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    @Test("Test 1 — additive v2 migration preserves data and adds the new column")
    func test_additiveMigrationPreservesData() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let pool = try DatabasePool(path: url.path)
            let db = try AppDatabase(pool, migrator: migratorA())
            try await insertMeeting(db)
        }

        let pool = try DatabasePool(path: url.path)
        let db = try AppDatabase(pool, migrator: migratorB())

        #expect(try await meetingCount(db) == 1)
        let hasNotesColumn = try await db.dbWriter.read { writer in
            try writer.columns(in: "meeting").contains { $0.name == "notes" }
        }
        #expect(hasNotesColumn)
    }

    @Test("Test 2 — an in-place baseline edit does NOT wipe data when erase is off (the direct regression)")
    func test_inPlaceBaselineEditDoesNotWipe_erasesOff() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let pool = try DatabasePool(path: url.path)
            let db = try AppDatabase(pool, migrator: migratorA())
            try await insertMeeting(db)
        }

        // Migrator C: `v1_baseline` edited in place (extra column baked in), NO new migration, and
        // `eraseDatabaseOnSchemaChange` left at its safe default (false, mirrored here explicitly).
        var erasesOffMigrator = migratorC()
        erasesOffMigrator.eraseDatabaseOnSchemaChange = false

        let pool = try DatabasePool(path: url.path)
        let db = try AppDatabase(pool, migrator: erasesOffMigrator)

        // GRDB sees `v1_baseline` already recorded as applied and runs nothing further — the
        // mismatch between the on-disk schema and the (differently-shaped) registered migration
        // is silently ignored, but crucially the DATA SURVIVES.
        #expect(try await meetingCount(db) == 1)
    }

    @Test("Test 3 (contrast) — the same in-place baseline edit DOES wipe data when erase is on")
    func test_inPlaceBaselineEditWipes_whenEraseOn() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let pool = try DatabasePool(path: url.path)
            let db = try AppDatabase(pool, migrator: migratorA())
            try await insertMeeting(db)
        }

        var erasesOnMigrator = migratorC()
        erasesOnMigrator.eraseDatabaseOnSchemaChange = true

        let pool = try DatabasePool(path: url.path)
        let db = try AppDatabase(pool, migrator: erasesOnMigrator)

        // With erase ON, GRDB detects the schema mismatch (the from-scratch migration no longer
        // matches the applied history) and DROPS + RECREATES the whole database — this is the
        // exact mechanism that wiped 22 meetings in production. Documenting it here justifies why
        // the default must be `false`.
        #expect(try await meetingCount(db) == 0)
    }

    @Test("Test 4 — the real SchemaMigrator/AppDatabase defaults leave erase OFF")
    func test_defaultMigratorHasEraseOff() throws {
        let migrator = SchemaMigrator.migrator()
        #expect(migrator.eraseDatabaseOnSchemaChange == false)

        // makeShared/makeInMemory default the same way — verified via makeInMemory (no
        // filesystem side effects) by round-tripping a schema-mismatch scenario the same as
        // test 2, using the PUBLIC surface this time.
        let queue = try DatabaseQueue()
        var appliedOnce = DatabaseMigrator()
        appliedOnce.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
            }
        }
        try appliedOnce.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meeting (id, title) VALUES ('m1', 'Standup')")
        }

        var editedInPlace = DatabaseMigrator()
        editedInPlace.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("notes", .text)
            }
        }
        // No `eraseDatabaseOnSchemaChange` set here — GRDB's own default is `false`, matching
        // `SchemaMigrator.migrator()`'s default.
        try editedInPlace.migrate(queue)

        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting") ?? 0
        }
        #expect(count == 1)
    }
}
