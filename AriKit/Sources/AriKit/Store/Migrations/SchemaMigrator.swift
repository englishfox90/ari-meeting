//
//  SchemaMigrator.swift — the `DatabaseMigrator` for the AriKit store (plan §6;
//  docs/plans/robust-migration-and-backup.md).
//
//  A fresh Swift migration history — NOT a port of the Rust engine's `_sqlx_migrations`. One
//  `v1_baseline` migration creates every table in its final shape; every later schema change is a
//  NEW registered migration, never an edit to `v1_baseline` after it ships.
//
//  ⚠️ `v1_baseline` IS NOW FROZEN (2026-07-23, docs/plans/robust-migration-and-backup.md). Real
//  user data exists against this exact baseline (22 meetings, 3765 transcripts, hand-repaired
//  after an incident — see that plan's §2). It previously carried a "still being built
//  incrementally, extend in place" policy; that policy is RETIRED. Editing `v1_baseline` — adding,
//  removing, or retyping ANY column/table/index — is now prohibited. Every future schema change is
//  a NEW `migrator.registerMigration("v2_<desc>")`/`v3_...` block using additive-only DDL
//  (`ALTER TABLE ... ADD COLUMN`, `CREATE TABLE`, `CREATE INDEX`) — see that plan's §5 Layer 1 for
//  the shape and constraints (nullable/defaulted columns only; a destructive change needs an
//  explicit data-migration path + sign-off per the `sqlite-schema` skill).
//
//  The table order below is parent-before-child throughout (unchanged, historical rationale kept):
//  `person` is declared BEFORE `speaker` so `speaker.personId REFERENCES person(id)` can be inline
//  from the start (SQLite validates a FK's parent table exists at `CREATE TABLE` time under
//  `PRAGMA foreign_keys = ON` — a forward reference fails migration outright, "no such table:
//  person").
//
//  ⚠️ `eraseDatabaseOnSchemaChange` REMOVED from the default path (2026-07-23 incident fix): this
//  GRDB flag drops + recreates the WHOLE database on any schema mismatch — with NO thrown error —
//  which is exactly the mechanism that silently wiped a populated production DB after an in-place
//  `v1_baseline` edit. It is now an explicit, off-by-default parameter
//  (`migrator(eraseOnSchemaChange:)`) threaded from `AppDatabase.makeShared`/`makeInMemory`, which
//  in turn is only ever set `true` via the app-layer `ARI_RESET_STORE=1` opt-in
//  (`Ari/App/AppEnvironment.swift`) — never automatically, never in a normal launch. With it off, a
//  genuine schema mismatch surfaces as an honest SQLite error out of the migrator (No-Fake-State),
//  not a silent wipe.
//
import Foundation
import GRDB

enum SchemaMigrator {
    /// - Parameter eraseOnSchemaChange: deliberately OFF by default. `true` DROPS AND RECREATES
    ///   the database on any schema mismatch — the exact mechanism that wiped 22 meetings in the
    ///   2026-07-23 incident. Only ever enabled via the explicit `ARI_RESET_STORE` opt-in read in
    ///   `AppEnvironment.bootstrap()`, never in normal launch.
    static func migrator(eraseOnSchemaChange: Bool = false) -> DatabaseMigrator {
        var migrator = migratorThroughV4(eraseOnSchemaChange: eraseOnSchemaChange)

        // v5 (docs/plans/custom-vocabulary.md §4.1) — additive-only, `v1_baseline` through
        // `v4_ask_message_cards` all stay frozen. A user-editable dictionary of domain proper
        // nouns; global, not per-meeting (no FK). `normalizedTerm` is a folded duplicate-
        // detection key (`VocabularyTermRecord.normalize(_:)`), never displayed. The partial
        // unique index lets a soft-deleted term be re-added later (API verified:
        // GRDB/QueryInterface/Schema/Database+SchemaDefinition.swift:514-531).
        migrator.registerMigration("v5_vocabulary_term") { db in
            try db.create(table: "vocabularyTerm") { t in
                t.primaryKey("id", .text)
                t.column("term", .text).notNull()
                t.column("normalizedTerm", .text).notNull()
                t.column("definition", .text)
                // JSON arrays — mirrors calendarEvent.attendeesJson (line ~327 above).
                t.column("alternateFormsJson", .text)
                t.column("misheardAsJson", .text)
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                // User-authored content → tombstones, sync-aware-but-off (plan principle 5).
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("deletedAt", .datetime)
            }

            try db.create(
                index: "index_vocabularyTerm_on_normalizedTerm",
                on: "vocabularyTerm",
                columns: ["normalizedTerm"],
                options: .unique,
                condition: Column("isDeleted") == false
            )

            try db.create(
                index: "index_vocabularyTerm_on_isEnabled",
                on: "vocabularyTerm",
                columns: ["isEnabled"]
            )
        }

        return migrator
    }

    /// The full migration history EXCLUDING `v5_vocabulary_term` — a test seam
    /// (`VocabularyRepositoryTests`, mirroring `MigrationSafetyTests`'s two-migrator pattern) so a
    /// test can drive a v4-shaped DB forward with the REAL v5 migration and prove it's additive.
    /// Module-internal only; production always goes through `migrator(eraseOnSchemaChange:)` above.
    /// No DDL here differs from what `migrator(eraseOnSchemaChange:)` registers for v1–v4 — this is
    /// a code-motion split, not an edit to any frozen migration's content.
    static func migratorThroughV4(eraseOnSchemaChange: Bool = false) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = eraseOnSchemaChange

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

            // `askConversation` (§4.4) — schema only in Slice 2; repository landed in Slice 6
            // (`AskConversationStore`). `seriesId` (docs/plans/ari-ask-ui.md Phase 0) is folded in
            // here — same "extend `v1_baseline` in place while it remains unshipped" policy this
            // file's header already documents for `recallChunk`/`askConversation`/`askMessage`/
            // `setting` — rather than opening a `v2_...` migration for a table with no shipped
            // rows anywhere. `series` is declared above, so the FK is inline from the start.
            // Invariant (enforced in `AskConversationStore`, not a DB constraint SQLite can
            // express cleanly here): at most one of `meetingId`/`seriesId` is non-null; both null
            // is a global (cross-meeting, cross-series) conversation.
            try db.create(table: "askConversation") { t in
                t.primaryKey("id", .text)
                t.column("meetingId", .text)
                    .indexed()
                    .references("meeting", onDelete: .setNull)
                t.column("seriesId", .text)
                    .indexed()
                    .references("series", onDelete: .setNull)
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

            // `setting` (docs/plans/settings-ui.md §2.1) — the native Settings screen's
            // key-value config table. Appended after `askMessage` (the migration's prior last
            // table) per that plan's own decision to extend `v1_baseline` in place while it
            // remains unshipped. No FK, no tombstone columns (config, not synced content —
            // mirrors `calendarSyncSetting`'s precedent above).
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v2 (docs/plans/ask-meetings-tools-and-cards.md §3.2/§7) — additive-only, `v1_baseline`
        // stays frozen. Tags each `recallChunk` row with what text it was built from
        // ("transcript" or "summary") so retrieval/presentation can tell them apart. Every
        // existing row backfills to `'transcript'` — correct, since that's all `recallChunk` ever
        // held before this migration.
        migrator.registerMigration("v2_recall_chunk_source_kind") { db in
            try db.alter(table: "recallChunk") { t in
                t.add(column: "sourceKind", .text).notNull().defaults(to: "transcript")
            }
        }

        // v3 (docs/plans/ask-meetings-tools-and-cards.md §5.1/§7) — additive-only, `v1_baseline`
        // AND `v2_recall_chunk_source_kind` both stay frozen. A nullable JSON column carrying the
        // Slice-B-resolved `RecallCardPayload` for a persisted assistant message, mirroring
        // `sourcesJson`'s exact shape (nil = "no card," never a fabricated placeholder).
        migrator.registerMigration("v3_ask_message_card") { db in
            try db.alter(table: "askMessage") { t in
                t.add(column: "cardJson", .text)
            }
        }

        // v4 (docs/plans/ask-meetings-agentic-tools.md §5.4) — additive-only, `v1_baseline`,
        // `v2_recall_chunk_source_kind`, AND `v3_ask_message_card` all stay frozen. The tool-first
        // agentic path can resolve MORE THAN ONE entity per ask (e.g. a person + today's calendar
        // event); `cardsJson` carries the full set. `cardJson` (v3) is kept as a legacy back-compat
        // column, always `cards.first` going forward — the read path prefers `cardsJson`, falling
        // back to `cardJson` for rows persisted before this column existed.
        migrator.registerMigration("v4_ask_message_cards") { db in
            try db.alter(table: "askMessage") { t in
                t.add(column: "cardsJson", .text)
            }
        }

        return migrator
    }
}
