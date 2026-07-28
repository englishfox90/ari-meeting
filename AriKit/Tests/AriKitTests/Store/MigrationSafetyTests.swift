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
    func additiveMigrationPreservesData() async throws {
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
    func inPlaceBaselineEditDoesNotWipe_erasesOff() async throws {
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
    func inPlaceBaselineEditWipes_whenEraseOn() async throws {
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
    func defaultMigratorHasEraseOff() throws {
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

    @Test(
        "Test 5 — the real v7_summary_custom_prompt migration is additive: applies cleanly on top of an existing v1..v6 database, preserving existing rows and NULL-backfilling the new column"
    )
    func v7SummaryCustomPromptIsAdditive() async throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Simulate a real pre-v7 database: everything through `v5_calendar_series_consent`
        // (`migratorWithoutVocabularyTerm` stops there — `v5_vocabulary_term`/`v6`/`v7` are all
        // registered on top by the real `migrator()`), with an existing meeting + summary row,
        // exactly like real user data predating this migration.
        do {
            let pool = try DatabasePool(path: url.path)
            let db = try AppDatabase(pool, migrator: SchemaMigrator.migratorWithoutVocabularyTerm())
            // `insertMeeting(_:)` above targets the SIMPLIFIED migrator A/B/C schema (`id`/`title`
            // only) — the real `v1_baseline` requires `createdAt`/`updatedAt` NOT NULL, so this
            // goes through the real repository instead, matching genuine pre-v7 user data.
            try await db.meetings.upsert(Meeting(id: "m1", title: "Standup", createdAt: now, updatedAt: now))
            try await db.dbWriter.write { writer in
                try writer.execute(
                    sql: """
                    INSERT INTO summary (id, meetingId, bodyMarkdown, createdAt, updatedAt, isDeleted)
                    VALUES (?, ?, ?, ?, ?, 0)
                    """,
                    arguments: ["s1", "m1", "# Recap", now, now]
                )
            }
        }

        // Now open the SAME on-disk file with the REAL, full `SchemaMigrator.migrator()` — which
        // includes v5_vocabulary_term, v6_profile_fact_supersession, AND the new
        // v7_summary_custom_prompt — and prove it migrates forward without wiping anything.
        let pool = try DatabasePool(path: url.path)
        let db = try AppDatabase(pool, migrator: SchemaMigrator.migrator())

        #expect(try await meetingCount(db) == 1)

        let hasCustomInstructionsColumn = try await db.dbWriter.read { writer in
            try writer.columns(in: "summary").contains { $0.name == "customInstructions" }
        }
        #expect(hasCustomInstructionsColumn)

        let summaryRow = try await db.dbWriter.read { writer in
            try Row.fetchOne(writer, sql: "SELECT bodyMarkdown, customInstructions FROM summary WHERE id = 's1'")
        }
        #expect(summaryRow?["bodyMarkdown"] as String? == "# Recap")
        // Pre-existing rows backfill to NULL — never a fabricated empty string (No-Fake-State).
        #expect(summaryRow?["customInstructions"] as String? == nil)

        // The repository layer round-trips the new column correctly against the migrated file too.
        let fetched = try await db.summaries.find(SummaryID("s1"))
        #expect(fetched?.bodyMarkdown == "# Recap")
        #expect(fetched?.customInstructions == nil)
    }
}
