//
//  SchemaMigrator.swift — the `DatabaseMigrator` for the AriKit store (plan §6).
//
//  A fresh Swift migration history — NOT a port of the Rust engine's `_sqlx_migrations`. One
//  `v1_baseline` migration creates every table in its final shape; every later schema change is a
//  NEW registered migration, never an edit to `v1_baseline` after it ships.
//
//  ⚠️ FOUNDATION SLICE (docs/plans/arikit-store.md §10 steps 1–2): `v1_baseline` in THIS commit
//  creates only `meeting`, `speaker`, `speakerSegment`, `transcript` (§4.1–§4.4) — the core
//  recording/transcription/diarization tables. The remaining §4 tables (`person`, `profileFact`
//  + `profileFactSource`, `series` + `seriesLedger` + `seriesMember`, `calendarEvent` +
//  `calendarSyncSetting`, `summary`, `meetingNote`) are steps 3–9 and are NOT here yet.
//  Because `v1_baseline` has not shipped/been released anywhere, a later slice MAY extend this
//  same migration directly (rather than opening `v2_...`) — call this out explicitly when that
//  work lands, since once this ships to a real on-disk database, `v1_baseline` is frozen and any
//  further additions become new registered migrations per the rule above.
//
//  `speaker.personId` does NOT yet carry `REFERENCES person(id)` (a deviation from §4.3 — see
//  the inline comment at its declaration below): with `PRAGMA foreign_keys = ON`, SQLite
//  validates that a FK's parent table exists at `CREATE TABLE` time, so a forward reference to
//  the not-yet-created `person` table fails migration outright ("no such table: person"). The
//  plan's §6/§10-risk-(d) assumption that this resolves lazily at DML time does not hold in
//  practice; verified empirically via `SchemaFidelityTests`. The FK constraint is added when the
//  `person` table lands (plan step 5).
//
import Foundation
import GRDB

enum SchemaMigrator {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
            // DEBUG-only convenience: drops + recreates the database on any schema mismatch.
            // Never enabled in a release build — it would silently destroy production data.
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_baseline") { db in
            try db.create(table: "meeting") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("audioReferencePath", .text)
                t.column("transcriptionProvider", .text)
                t.column("transcriptionModel", .text)
                t.column("summaryProvider", .text)
                t.column("summaryModel", .text)
                t.column("templateId", .text)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `speaker` before `speakerSegment`/`transcript` so their FKs point at an
            // already-declared table (readability only — SQLite doesn't require the order).
            try db.create(table: "speaker") { t in
                t.primaryKey("id", .text)
                // ⚠️ FOUNDATION-SLICE DEVIATION from §4.3: no `REFERENCES person(id)` yet. With
                // `PRAGMA foreign_keys = ON`, SQLite validates a FK's parent table at `CREATE
                // TABLE` time (not just at DML time as the plan's §6/§10-risk-(d) note assumed) —
                // a forward reference to the not-yet-created `person` table fails migration with
                // "no such table: person". Left a plain indexed nullable column for now; the FK
                // constraint will be added when the `person` table lands (plan step 5), as either
                // a new migration or (if `v1_baseline` still hasn't shipped anywhere) a direct
                // extension of this table's definition — call this out in that slice's report.
                t.column("personId", .text)
                    .indexed()
                t.column("label", .text)
                t.column("centroid", .blob).notNull()
                t.column("embeddingModel", .text).notNull()
                t.column("dim", .integer).notNull()
                t.column("samples", .integer).notNull().defaults(to: 1)
                t.column("enrollmentState", .text).notNull().defaults(to: "provisional")
                t.column("totalSpeechSecs", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "speakerSegment") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("speakerId", .text)
                    .indexed()
                    .references("speaker", onDelete: .setNull)
                t.column("clusterKey", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("source", .text).notNull()
                t.column("embedding", .blob)
                t.column("createdAt", .datetime).notNull()
                // No tombstone columns here — §4.4 does not list them; tombstones land for every
                // table in step 7 (docs/plans/arikit-store.md §10).
            }

            try db.create(table: "transcript") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("transcript", .text).notNull()
                t.column("timestamp", .text).notNull()
                t.column("audioStartTime", .double)
                t.column("audioEndTime", .double)
                t.column("duration", .double)
                t.column("speakerId", .text)
                    .indexed()
                    .references("speaker", onDelete: .setNull)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
                // ⚠️ Deliberately NOT ported (plan §4.2/§4.10): the dead Rust `speaker` mic/system
                // label column, and the pre-chunking-era `summary`/`action_items`/`key_points`
                // free-text cache columns (superseded by the dedicated `summary` table, step 3).
            }
        }

        return migrator
    }
}
