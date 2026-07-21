//
//  SchemaMigrator.swift — the `DatabaseMigrator` for the AriKit store (plan §6).
//
//  A fresh Swift migration history — NOT a port of the Rust engine's `_sqlx_migrations`. One
//  `v1_baseline` migration creates every table in its final shape; every later schema change is a
//  NEW registered migration, never an edit to `v1_baseline` after it ships.
//
//  ⚠️ `v1_baseline` is STILL BEING BUILT INCREMENTALLY (plan §10 slice-1 findings): because it
//  has not shipped/been released anywhere, later slices extend this same migration directly
//  rather than opening `v2_...`. Slice 2 (plan §10 steps 3–5) added `summary`, `meetingNote`,
//  `person`, `profileFact`, and `profileFactSource` to the foundation slice's
//  `meeting`/`speaker`/`speakerSegment`/`transcript`. Slice 3 (plan §10 step 6) adds §4.7
//  (`series`+`seriesLedger`+`seriesMember`) and §4.8 (`calendarEvent`+`calendarSyncSetting`).
//  Recall Slice 2 (docs/plans/arikit-recall-slice2.md §4) appends `recallChunk`,
//  `recallIndexState`, `recallFts` (FTS5), and the schema-only `askConversation`/`askMessage`.
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
                // `supersedesFactId`/`lastConfirmedAt` (Phase 3.4 Track H, `arikit-engine-extras.md`
                // §2.3) — Store-internal only, NOT on `AriKit.Models.ProfileFact` yet (same
                // documented gap as `Meeting.templateId`/`Series.templateId`/
                // `CalendarEventRecord.syncedAt`). `supersedesFactId` is the DEFERRED-supersession
                // pointer a pending replacement carries (← `mark_supersedes`, `person.rs:632`) —
                // forward from the new/pending fact to the old fact it proposes to replace; the
                // OLD fact stays active until a future confirm flow retires it via the existing
                // `supersededBy` pointer above. `lastConfirmedAt` resets the staleness clock (←
                // `touch_confirmed`, `person.rs:699`), read by `factsNeedingReview`.
                t.column("supersedesFactId", .text)
                    .indexed()
                    .references("profileFact", onDelete: .setNull)
                t.column("lastConfirmedAt", .datetime)
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

            // `meetingParticipant` (Phase 3.4 Track H, `arikit-engine-extras.md` §2.3/§6-5) — the
            // real meeting↔person link table extraction/reconciliation read as their participant
            // roster (← `list_participants`, `person.rs:370`). A pure link row (composite PK, no
            // tombstone — mirrors `seriesMember`'s precedent, §4.7): a person either is or isn't a
            // participant, so membership is added/removed directly via
            // `PersonRepository.addParticipant`/`removeParticipant`. `meeting`/`person` both
            // precede this table, so both FKs are inline.
            try db.create(table: "meetingParticipant") { t in
                t.column("meetingId", .text)
                    .notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("personId", .text)
                    .notNull()
                    .indexed()
                    .references("person", onDelete: .cascade)
                t.column("linkSource", .text)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["meetingId", "personId"])
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

            // `series` (§4.7) — after `person` (`ownerPersonId` FK) so it can be declared inline.
            try db.create(table: "series") { t in
                t.primaryKey("id", .text)
                t.column("seriesKey", .text).unique()
                t.column("title", .text).notNull()
                t.column("detectedType", .text)
                t.column("cadence", .text)
                t.column("ownerPersonId", .text)
                    .indexed()
                    .references("person", onDelete: .setNull)
                // Not yet on `AriKit.Models.Series` — same documented gap as `Meeting.templateId`
                // (see `Records/SeriesRecord.swift`'s header). Always persisted as `NULL` here.
                t.column("templateId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `seriesLedger` (§4.7) — one row per series (PK is the FK itself). No tombstone
            // columns: §4.7 does not list them, and its lifecycle is tied to its parent `series`
            // row via `ON DELETE CASCADE` (mirrors the `speakerSegment` precedent, plan §10 step 7
            // folds tombstones in for every table that gets one).
            try db.create(table: "seriesLedger") { t in
                t.primaryKey("seriesId", .text)
                    .references("series", onDelete: .cascade)
                t.column("ledgerMarkdown", .text)
                t.column("structuredJson", .text)
                t.column("updatedFromMeetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                // `nil` = no ledger yet (plan §4.7).
                t.column("ledgerVersion", .integer)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // `seriesMember` (§4.7) — a link row, composite PK, no tombstone (plan §4.7 lists
            // none; a meeting either is or isn't a member, so its row is added/removed directly).
            try db.create(table: "seriesMember") { t in
                t.column("seriesId", .text)
                    .notNull()
                    .indexed()
                    .references("series", onDelete: .cascade)
                t.column("meetingId", .text)
                    .notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("occurrenceTime", .text)
                t.column("linkSource", .text)
                t.column("createdAt", .datetime).notNull()
                t.primaryKey(["seriesId", "meetingId"])
            }

            // `calendarEvent` (§4.8) — attendees kept as an inline JSON column (§0.1(2)).
            try db.create(table: "calendarEvent") { t in
                t.primaryKey("id", .text)
                t.column("calendarId", .text).notNull()
                t.column("calendarTitle", .text)
                t.column("title", .text).notNull()
                t.column("startTime", .datetime).notNull()
                t.column("endTime", .datetime).notNull()
                t.column("isAllDay", .boolean).notNull()
                t.column("location", .text)
                t.column("notes", .text)
                t.column("organizer", .text)
                t.column("attendeesJson", .text).notNull()
                t.column("meetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                t.column("linkSource", .text)
                // Recurrence signals (§4.8) — nullable, matching the domain type's `Optional`
                // "not captured" semantics (see `Models/CalendarEvent.swift`'s header).
                t.column("seriesKey", .text)
                t.column("hasRecurrence", .boolean)
                t.column("occurrenceDate", .datetime)
                t.column("isDetached", .boolean)
                // Store-internal only — not on the domain type yet, same documented gap as
                // `Meeting.templateId` (see `Records/CalendarEventRecord.swift`'s header).
                t.column("syncedAt", .datetime)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            // `calendarSyncSetting` (§4.8) — config/selection, not a synced text record (the
            // domain-level `CalendarInfo` DTO was deliberately deferred, arikit-models.md §7.7);
            // no tombstone, no dedicated repository — folded into `CalendarEventRepository`.
            try db.create(table: "calendarSyncSetting") { t in
                t.primaryKey("calendarId", .text)
                t.column("calendarTitle", .text)
                t.column("color", .text)
                t.column("selected", .boolean).notNull().defaults(to: false)
            }

            // Recall Slice 2 (docs/plans/arikit-recall-slice2.md §4) — index tables + the
            // schema-only Ask conversation tables. Appended after `calendarSyncSetting`
            // (the migration's prior last table) per the slice's own decision to extend
            // `v1_baseline` in place while it remains unshipped. `meeting` already exists above,
            // so `recallChunk`/`recallIndexState` (FK→`meeting`) are inline from the start.

            // `recallChunk` (§4.1) — the Swift schema ADDS an FK beyond the Rust plain index
            // (single-owner rationale, plan §4.1).
            try db.create(table: "recallChunk") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .notNull()
                    .indexed()
                    .references("meeting", onDelete: .cascade)
                t.column("chunkIndex", .integer).notNull()
                t.column("chunkText", .text).notNull()
                t.column("startTime", .double)
                t.column("endTime", .double)
                t.column("timestampLabel", .text)
                t.column("embedding", .blob)
                t.column("embeddingModel", .text)
                t.column("dim", .integer)
                t.column("tokenEstimate", .integer)
                t.column("createdAt", .text).notNull()
            }

            // `recallIndexState` (§4.2) — Swift schema ADDS an FK beyond Rust's bare PK.
            try db.create(table: "recallIndexState") { t in
                t.primaryKey("meetingId", .text)
                    .references("meeting", onDelete: .cascade)
                t.column("contentHash", .text).notNull()
                t.column("chunkCount", .integer).notNull()
                t.column("embeddingModel", .text)
                t.column("embeddedCount", .integer).notNull().defaults(to: 0)
                t.column("indexedAt", .text).notNull()
            }

            // `recallFts` (§4.3) — standalone (non-external-content) FTS5 virtual table, "for
            // robustness" per the Rust migration's own comment. No FK — SQLite does not support
            // declared foreign keys on a virtual table, and Rust has none either.
            try db.create(virtualTable: "recallFts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("chunkText")
                t.column("chunkId").notIndexed()
                t.column("meetingId").notIndexed()
            }

            // `askConversation` (§4.4) — schema only in Slice 2; no repository yet (Slice 6).
            try db.create(table: "askConversation") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                t.column("title", .text)
                t.column("createdAt", .text).notNull()
                t.column("updatedAt", .text).notNull().indexed()
            }

            // `askMessage` (§4.5) — schema only in Slice 2; no repository yet (Slice 6).
            try db.create(table: "askMessage") { t in
                t.primaryKey("id", .text)
                t.column("conversationId", .text)
                    .notNull()
                    .indexed()
                    .references("askConversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sourcesJson", .text)
                t.column("createdAt", .text).notNull()
            }
        }

        return migrator
    }
}
