//
//  SchemaMigrator.swift — the `DatabaseMigrator` for the AriKit store (plan §6).
//
//  A fresh Swift migration history — NOT a port of the Rust engine's `_sqlx_migrations`. One
//  `v1_baseline` migration creates every table in its final shape; every later schema change is a
//  NEW registered migration, never an edit to `v1_baseline` after it ships.
//
//  ⚠️ `v1_baseline` is STILL BEING BUILT INCREMENTALLY (plan §10 slice-1 findings): because it
//  has not shipped/been released anywhere, later slices extend this same migration directly
//  rather than opening `v2_...`. This commit (plan §10 steps 3–5) adds `summary`, `meetingNote`,
//  `person`, `profileFact`, and `profileFactSource` to the foundation slice's
//  `meeting`/`speaker`/`speakerSegment`/`transcript`. §4.7 (`series`+`seriesLedger`+
//  `seriesMember`) and §4.8 (`calendarEvent`+`calendarSyncSetting`) are NOT here yet (plan step 6).
//
//  ⚠️ Table order is now parent-before-child throughout, per the slice-1 finding: `person` is
//  declared BEFORE `speaker` so `speaker.personId REFERENCES person(id)` can be inline from the
//  start (SQLite validates a FK's parent table exists at `CREATE TABLE` time under
//  `PRAGMA foreign_keys = ON` — a forward reference fails migration outright, "no such table:
//  person"). This resolves the foundation slice's `speaker.personId` deferred-FK gap: the column
//  now carries `REFERENCES person(id) ON DELETE SET NULL` inline, matching §4.3.
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

            // `person` before `speaker` (§4.5) so `speaker.personId` can carry an inline
            // `REFERENCES person(id)` — see file header.
            try db.create(table: "person") { t in
                t.primaryKey("id", .text)
                // Plain UNIQUE already behaves as "unique where not null" in SQLite (NULL is
                // never considered equal to NULL in a UNIQUE index), so this satisfies §4.5's
                // "UNIQUE WHERE NOT NULL" without a partial index.
                t.column("email", .text).unique()
                t.column("displayName", .text).notNull()
                t.column("role", .text)
                t.column("organization", .text)
                t.column("domain", .text)
                t.column("notes", .text)
                // Single-true-row invariant enforced by `PersonRepository.setOwner(_:)`, not a
                // DB constraint (plan §0.1(4) — SQLite has no partial-unique-on-boolean
                // primitive that survives CloudKit per-record conflict resolution cleanly).
                t.column("isOwner", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            try db.create(table: "speaker") { t in
                t.primaryKey("id", .text)
                // Now inline (§4.3) — `person` is declared above. Foundation-slice deviation
                // resolved: see file header.
                t.column("personId", .text)
                    .indexed()
                    .references("person", onDelete: .setNull)
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
                // free-text cache columns (superseded by the dedicated `summary` table below).
            }

            // `profileFact` (§4.6) — after `person`/`meeting` so its FKs are inline.
            // `sourceMeetingTitle`/`sourceCount` are deliberately NOT columns here (No-Fake-State,
            // §0.1) — `ProfileFactRepository` computes them at read time.
            try db.create(table: "profileFact") { t in
                t.primaryKey("id", .text)
                t.column("personId", .text)
                    .notNull()
                    .indexed()
                    .references("person", onDelete: .cascade)
                t.column("factText", .text).notNull()
                t.column("factKind", .text).notNull()
                t.column("sourceMeetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                t.column("sourceSegmentRef", .text)
                t.column("origin", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("status", .text).notNull()
                // Self-referencing FK: safe to declare inline within the same CREATE TABLE
                // (SQLite resolves a table's own name against itself while parsing its DDL).
                t.column("supersededBy", .text)
                    .indexed()
                    .references("profileFact", onDelete: .setNull)
                t.column("createdAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `profileFactSource` (§4.6) — after `profileFact`/`meeting`. Tombstone columns
            // folded in here even though §4.6's literal listing omits them for this table — see
            // `Records/ProfileFactSourceRecord.swift`'s header for the documented deviation.
            try db.create(table: "profileFactSource") { t in
                t.primaryKey("id", .text)
                t.column("factId", .text)
                    .notNull()
                    .indexed()
                    .references("profileFact", onDelete: .cascade)
                t.column("meetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                t.column("segmentRef", .text)
                t.column("origin", .text).notNull()
                t.column("relation", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("observedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `summary` (§4.9) — NEW, no Rust source row (resolves `arikit-models.md` decision 0.2).
            try db.create(table: "summary") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .unique()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("bodyMarkdown", .text).notNull()
                t.column("provider", .text)
                t.column("model", .text)
                t.column("templateId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `meetingNote` (§4.12) — NEW, kept per data-preservation (plan §0.1(1)). Primary key
            // is `meetingId` itself, matching the legacy `meeting_notes` row shape exactly (see
            // `Models/MeetingNote.swift`'s header) — one note row per meeting, no synthetic id.
            try db.create(table: "meetingNote") { t in
                t.primaryKey("meetingId", .text)
                    .references("meeting", onDelete: .cascade)
                t.column("notesMarkdown", .text)
                t.column("notesJson", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }
        }

        return migrator
    }
}
