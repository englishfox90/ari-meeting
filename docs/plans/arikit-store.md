# AriKit `Store/` — SQLiteData port + legacy-data importer (plan)

> **STATUS: COMPLETE (2026-07-17).** Built on **plain GRDB** (not SQLiteData — decision recorded in §0.1(3); SQLiteData revisited at Phase 5.5). Four reviewed green slices on `main` (`e4c2a0c`→`b956e99`): foundation + core tables → Summary/MeetingNote/persons+facts → series+calendar → the legacy-data importer + `SingleOwnerTests`. The importer passed a `swift-code-reviewer` data-fidelity gate (a HIGH orphaned-`summary_processes` reconciliation hole + two MEDIUMs fixed before commit). **Step 8 (snake→camel decode adapter) is DEFERRED** — it only decodes live engine-IPC JSON, which needs the deferred daemon/bridge; no consumer yet. Store contributes ~109 of the AriKit suite's 133 tests. Title says "SQLiteData" for history; the store is GRDB.

## 0. Status & scope guard

This is Phase 3 step 1 ("Store") of `plans/swift-migration-plan.md`, folding in the deferred S4 local-store confirmation and resolving the two follow-ons flagged at the end of `docs/plans/arikit-models.md`. **Plan doc** — the implementation touches only `AriKit/Sources/AriKit/Store/**`, `AriKit/Sources/AriKit/Models/**` (additive follow-ons only, no rewrite of existing Models), `AriKit/Tests/AriKitTests/**`, and `AriKit/Package.swift`. No Rust file, no `Cargo.toml`, no `frontend/**`/`ari-engine/**` file is touched.

**WIP-limit check (principle 8):** this is the *only* active AriKit work stream. It depends on the landed Models layer and does not reopen it; it does not touch the (now-complete) Rust `ari-engine` carve.

## 0.1 Architect resolutions (2026-07-17) — these OVERRIDE the architect's "open decisions" tail

The plan-only architect pass flagged four decisions rather than guessing. Resolved here by the architect (Paul's standing requirement: **keep the existing data**):

1. **`meeting_notes` → IN SCOPE (do NOT drop).** It is real user-authored data (`20251223000000_add_meeting_notes.sql`). Add a small additive `MeetingNote` domain type to `AriKit.Models`, a `meetingNote` table (§4.12), an importer mapping (§5.2), and round-trip tests. This is a direct consequence of the data-preservation requirement — silently skipping it is not acceptable.
2. **`calendarEvent.attendees` → inline JSON column** (architect default accepted). Matches the shipped `CalendarEvent.attendees: [Attendee]` domain shape; normalize into a real `attendee` table only if per-attendee query/edit becomes a feature later.
3. **Record layer → plain GRDB `FetchableRecord`/`PersistableRecord`** — **RESOLVED with Paul 2026-07-17: GRDB chosen, NOT SQLiteData.** The implementer verified SQLiteData v1.7.0 is a `@Table` + `swift-structured-queries` paradigm (not a superset of plain records) with ~8 heavy transitive deps and no benefit until CloudKit at Phase 5.5; SQLiteData itself depends on GRDB 7.6, so GRDB keeps the same semantics. Dependency: `groue/GRDB.swift` from `7.11.0`. **Revisit SQLiteData-vs-hand-rolled-sync at Phase 5.5** (per plan §156's fallback clause). This is now the standing decision for every later slice.
4. **`person.isOwner` → repository-enforced single-owner** (atomic set-owner in one transaction that unsets any prior owner), not a DB constraint — SQLite has no partial-unique-on-boolean primitive that survives CloudKit per-record conflict resolution cleanly.

## 1. Goal & seam

Port the persistence layer — `frontend/src-tauri/migrations/*.sql` (25 timestamped migrations) + `ari-engine/src/database/{models.rs,repositories/*.rs}` — into `AriKit/Sources/AriKit/Store/`, on **Point-Free SQLiteData** over GRDB semantics (decided).

Phase 3 step 1, pulled forward to be built independently in the AriKit package (the same "no runtime dependency, gates nothing" logic the Models port used). It lands on the **target (Swift) side** of the store seam (principle 8) — the frozen Rust engine keeps its own `sqlx` schema untouched; nothing here edits it.

**Not a re-implementation of a frozen feature.** Recall itself (BM25⊕vector RRF, safety shell, citation guarantees) is a *later, separate* `AriKit.Recall` work stream (§9 deferred). This plan is the **schema + persistence substrate** recall will sit on, plus the **one genuinely novel piece the user asked for**: a one-time importer that keeps the existing meeting library.

**Confirms S4's local half:** §7 is the "SQLiteData is load-bearing on its local merits" confirmation, executed as step 1 of sequencing rather than a standalone spike.

## 2. Module & surface

### 2.1 File layout under `Store/`

```
Store/
├─ Store.swift                       module doc + AppDatabase entry point
├─ AppDatabase.swift                 single-owner connection (DatabasePool prod / DatabaseQueue test)
├─ Migrations/
│  └─ SchemaMigrator.swift           DatabaseMigrator, v1_baseline .. vN (§6)
├─ Records/                          FetchableRecord/PersistableRecord GRDB records — Store-internal,
│  ├─ MeetingRecord.swift             NOT public. Repositories translate Record ⇄ AriKit.Models.*
│  ├─ TranscriptRecord.swift
│  ├─ SpeakerRecord.swift
│  ├─ SpeakerSegmentRecord.swift
│  ├─ PersonRecord.swift
│  ├─ ProfileFactRecord.swift
│  ├─ ProfileFactSourceRecord.swift
│  ├─ SeriesRecord.swift             (meeting_series row)
│  ├─ SeriesLedgerRecord.swift       (series_ledger row — separate table, §4.7)
│  ├─ SeriesMemberRecord.swift       (meeting_series_members row)
│  ├─ CalendarEventRecord.swift      (attendees as a JSON column)
│  ├─ CalendarSyncSettingRecord.swift
│  ├─ SummaryRecord.swift            NEW table — no Rust row (§4.9)
│  └─ MeetingNoteRecord.swift        NEW table — meeting_notes (§4.12, kept per data-preservation)
├─ Repositories/                     public surface — the ONLY way feature code touches the DB
│  ├─ MeetingRepository.swift
│  ├─ TranscriptRepository.swift
│  ├─ SpeakerRepository.swift
│  ├─ PersonRepository.swift
│  ├─ ProfileFactRepository.swift
│  ├─ SeriesRepository.swift
│  ├─ CalendarEventRepository.swift
│  ├─ SummaryRepository.swift
│  └─ MeetingNoteRepository.swift
├─ Coding/
│  └─ SnakeCaseDecoding.swift        the snake→camel adapter (resolves arikit-models.md §7.7)
└─ Import/                           the legacy-library importer (§5) — its own sub-surface
   ├─ LegacyDatabaseImporter.swift
   ├─ LegacyDatabaseReader.swift     read-only sqlx-schema reader (raw GRDB read connection)
   ├─ ImportReport.swift             row-count reconciliation + skip/warn ledger (No-Fake-State analog)
   └─ ImportMapping.swift            table-by-table mapping, one function per table (§5.2)
```

All records are `internal` to `Store` — only `AriKit.Models.*` (public) and the repository protocols cross the module boundary. A feature (or future SwiftUI view model) never sees a GRDB `Row`, a `PersistableRecord`, or a raw `Database` handle — only `Meeting`, `Transcript`, etc. This is "persistence goes through repositories only" made concrete.

### 2.2 Public API surface

```swift
/// The one owner of the AriKit SQLite file (plan principle 3). Construct once at app launch;
/// hand repositories out from it. Never construct a second AppDatabase over the same path.
public actor AppDatabase {
    public static func makeShared(at url: URL) throws -> AppDatabase
    public static func makeInMemory() throws -> AppDatabase   // tests / previews

    public nonisolated var meetings: MeetingRepository { get }
    public nonisolated var transcripts: TranscriptRepository { get }
    public nonisolated var speakers: SpeakerRepository { get }
    public nonisolated var persons: PersonRepository { get }
    public nonisolated var profileFacts: ProfileFactRepository { get }
    public nonisolated var series: SeriesRepository { get }
    public nonisolated var calendarEvents: CalendarEventRepository { get }
    public nonisolated var summaries: SummaryRepository { get }
    public nonisolated var meetingNotes: MeetingNoteRepository { get }
}
```

Each repository is a small `Sendable` struct wrapping the owning `AppDatabase`'s writer. Representative surface (full method list is implementer expansion, not exhaustive here):

```swift
public struct MeetingRepository: Sendable {
    public func all(includingDeleted: Bool = false) async throws -> [Meeting]
    public func find(_ id: MeetingID) async throws -> Meeting?
    public func upsert(_ meeting: Meeting) async throws
    public func softDelete(_ id: MeetingID, at: Date) async throws   // tombstone, never a hard DELETE
    public func observeAll() -> AsyncStream<[Meeting]>               // ValueObservation-backed
}

public struct ProfileFactRepository: Sendable {
    public func activeFacts(for person: PersonID) async throws -> [ProfileFact]
    public func withProvenance(_ factID: ProfileFactID) async throws -> ProfileFactWithProvenance?
    public func supersedeChain(from: ProfileFactID) async throws -> [ProfileFact]  // walks supersededBy
    public func upsert(_ fact: ProfileFact) async throws
    public func recordSource(_ source: ProfileFactSource) async throws
}
```

- **How features obtain repositories:** the app target constructs one `AppDatabase` at launch (`makeShared(at:)`, path resolved by the app, not hardcoded in `AriKit`) and injects it into `@Observable` view models. `Store` never reads `FileManager` app-support paths itself — that stays app-target code (never hardcode filesystem paths).
- **Value in, value out.** Every repository method takes and returns `AriKit.Models.*` value types — never a GRDB record. A private mapping (`MeetingRecord.asModel()` / `Meeting.asRecord()`) lives beside each record.

## 3. Concurrency model

- **`AppDatabase` is an `actor`.** GRDB's `DatabasePool`/`DatabaseQueue` are internally thread-safe (`any DatabaseWriter` is `Sendable`), so the actor's role is narrow: it owns the single `any DatabaseWriter` and vends repository structs. Property accessors are `nonisolated` because the repository *structs* they return are `Sendable` value types holding only a `Sendable` writer reference — only *constructing* `AppDatabase` (which runs the migrator) requires isolation. No `@unchecked Sendable`, no `nonisolated(unsafe)`.
- **Repositories are `Sendable` structs**, freely passable across actor boundaries (SwiftUI `@Observable` view models, background import tasks, a future Recall module).
- **Off-main-actor by construction.** `dbWriter.read`/`.write` closures run on GRDB's own queues; repository methods are `async` and never assume `@MainActor`. Design is safe for a future Engine to patch a `Transcript.speakerId` off the hot path (the `open-questions.md` Q4 "patch the DB row when re-ID completes" contract) without a second connection.
- **`ValueObservation`** exposed as `AsyncStream`/`AsyncSequence` from repositories (`observeAll()`) for SwiftUI live-list updates.
- **Import runs as a plain `async` task** holding a *read-only* second `DatabaseQueue` on the **legacy** file (a different file — §5.1), so it is not a second writer of the AriKit file and does not violate single-owner.

## 4. Persistence — schema

**Design rules:** additive/non-destructive migrations, provenance on every inferred fact, results/audio split, FK + index on every join/filter column, and the four sync-aware constraints — stable UUID PKs (already true), nullable/defaulted synced columns, **soft-delete tombstones** (the one real gap, added here), per-record conflict granularity (normal normalization, not wide rows).

Column names below are Swift-side **camelCase** GRDB columns (matching the ported `AriKit.Models` property names) — GRDB does not require snake_case. This is a **fresh schema**, not a byte-for-byte port of the sqlx DDL — see §4.10 for the deltas and why.

### 4.1 `meeting` (← `meetings`)
`id`(TEXT PK, `MeetingID`), `title`(TEXT NOT NULL), `createdAt`/`updatedAt`(DATETIME NOT NULL), `audioReferencePath`(TEXT nullable ← `folder_path`; never synced), `transcriptionProvider`/`transcriptionModel`/`summaryProvider`/`summaryModel`(TEXT nullable), `templateId`(TEXT nullable), `isDeleted`(BOOLEAN NOT NULL DEFAULT 0 — **new tombstone**), `deletedAt`(DATETIME nullable — **new tombstone**).

### 4.2 `transcript` (← `transcripts`)
`id`(TEXT PK), `meetingId`(TEXT NOT NULL, FK→meeting ON DELETE CASCADE, indexed), `transcript`(TEXT NOT NULL), `timestamp`(TEXT NOT NULL — kept `String` per Models decision), `audioStartTime`/`audioEndTime`/`duration`(REAL nullable), `speakerId`(TEXT nullable, FK→speaker ON DELETE SET NULL, indexed — F1 resolved speaker), `isDeleted`/`deletedAt`.
⚠️ Do NOT reuse the dead Rust `speaker` mic/system column (confirmed dead). The `transcripts.summary`/`action_items`/`key_points` free-text columns are **not ported** (pre-chunking-era cache; the dedicated `summary` table §4.9 replaces them) — a documented delta (§4.10), confirm no live read path before finalizing the drop.

### 4.3 `speaker` (← `speakers`)
`id`(TEXT PK), `personId`(TEXT nullable, FK→person ON DELETE SET NULL, indexed), `label`(TEXT nullable), `centroid`(BLOB NOT NULL — opaque f32 vector; model vector not audio, so it DOES sync), `embeddingModel`(TEXT NOT NULL), `dim`(INTEGER NOT NULL), `samples`(INTEGER NOT NULL DEFAULT 1), `enrollmentState`(TEXT NOT NULL DEFAULT 'provisional'), `totalSpeechSecs`(REAL NOT NULL DEFAULT 0), `createdAt`/`updatedAt`, `isDeleted`/`deletedAt`.

### 4.4 `speakerSegment` (← `speaker_segments`)
`id`(TEXT PK), `meetingId`(FK→meeting CASCADE, indexed), `speakerId`(nullable, FK→speaker SET NULL), `clusterKey`(TEXT NOT NULL), `startTime`/`endTime`(REAL NOT NULL), `source`(TEXT NOT NULL, `SegmentSource`), `embedding`(BLOB nullable), `createdAt`.

### 4.5 `person` (← `persons`)
`id`(TEXT PK), `email`(TEXT nullable, UNIQUE WHERE NOT NULL), `displayName`(TEXT NOT NULL), `role`/`organization`/`domain`/`notes`(TEXT nullable), `isOwner`(BOOLEAN NOT NULL DEFAULT 0 — single-true-row enforced in the repository per §0.1(4)), `createdAt`/`updatedAt`, `isDeleted`/`deletedAt`.

### 4.6 `profileFact` + `profileFactSource` (← `profile_facts` + `profile_fact_sources`)
`profileFact`: `id`, `personId`(FK, indexed), `factText`, `factKind`, `sourceMeetingId`(FK nullable), `sourceSegmentRef`, `origin`(`FactOrigin`), `confidence`, `status`, `supersededBy`(FK→profileFact SET NULL, indexed), `createdAt`, `isDeleted`/`deletedAt`. **Not stored (computed at read time by the repository):** `sourceMeetingTitle` (join against `meeting.title`) and `sourceCount` (`COUNT(*)` over `profileFactSource`) — avoids a second source of truth (No-Fake-State) and honors "don't denormalize a synced table."
`profileFactSource`: `id`, `factId`(FK CASCADE, indexed), `meetingId`(FK nullable, indexed), `segmentRef`, `origin`, `relation`, `confidence`, `observedAt`.

### 4.7 `series` + `seriesLedger` + `seriesMember` (← `meeting_series` + `series_ledger` + `meeting_series_members`)
The domain `Series` type flattens what the Rust schema splits; the Store keeps the split and the repository re-joins.
`series`: `id`, `seriesKey`(nullable, UNIQUE WHERE NOT NULL), `title`, `detectedType`, `cadence`, **`ownerPersonId`**(FK→person SET NULL — Models follow-on: real stored column the IPC DTOs never exposed), `templateId`, **`createdAt`/`updatedAt`**(Models follow-on: the series' own timestamps), `isDeleted`/`deletedAt`.
`seriesLedger`: `seriesId`(PK, FK→series CASCADE), `ledgerMarkdown`, `structuredJson`, `updatedFromMeetingId`(FK nullable), **`ledgerVersion: Int?`**(nullable — `nil` = no ledger yet, resolving the wire DTO's ambiguous `0`), `createdAt`/`updatedAt`.
`seriesMember`: `seriesId`(FK CASCADE), `meetingId`(FK CASCADE), composite PK, `occurrenceTime`(TEXT nullable), `linkSource`, `createdAt`.
`SeriesRepository` reads all three and returns one `AriKit.Models.Series` (the reconciliation the Models plan deferred).

### 4.8 `calendarEvent` (← `calendar_events`) + `calendarSyncSetting`
Attendees kept as an inline JSON column (§0.1(2)).
`calendarEvent`: `id`(EventKit `eventIdentifier`), `calendarId`, `calendarTitle`, `title`, `startTime`/`endTime`(DATETIME), `isAllDay`, `location`, `notes`, `organizer`, `attendeesJson`(TEXT, JSON `[Attendee]`), `meetingId`(FK→meeting SET NULL, indexed), `linkSource`, `seriesKey`, `hasRecurrence`, `occurrenceDate`, `isDetached`, `syncedAt`, `isDeleted`/`deletedAt`.
`calendarSyncSetting` (← `calendar_sync_settings`): `calendarId`(PK), `calendarTitle`, `color`, `selected`. (Config/selection, not a synced text record — flagged as possibly belonging to a Settings layer at a later pass; kept here for parity now.)

### 4.9 `summary` — NEW, no Rust row (resolves `arikit-models.md` decision 0.2)
The frozen Rust engine has no `summary` table (a summary lives in `summary_processes.result` JSON + on `meetings.summary_*`). Define it here.
`summary`: `id`(PK), `meetingId`(FK→meeting CASCADE, UNIQUE, indexed), `bodyMarkdown`(TEXT NOT NULL), `provider`/`model`/`templateId`(TEXT nullable), `createdAt`/`updatedAt`, `isDeleted`/`deletedAt`.
**Requires a new additive `Summary` domain type in `AriKit.Models`** (`id: SummaryID`, `meetingId: MeetingID`, `bodyMarkdown: String`, `provider/model/templateId: String?`, `createdAt/updatedAt: Date`) — its own sequencing step (§10) so it stays reviewable in isolation.
**Import implication:** reconstructed from the legacy `summary_processes.result` JSON blob (best-effort parse) — a flagged lossy mapping (§5.2, §5.5).

### 4.10 Documented schema deltas vs. the Rust source
| Rust reality | Swift Store shape | Why |
|---|---|---|
| No `summary` table (JSON in `summary_processes.result`) | Dedicated `summary` table (§4.9) | Models decision 0.2; typed row not a JSON cache |
| `series_ledger` flattened in IPC `Series` | `seriesLedger` kept as its own table (§4.7) | Matches Rust's actual normalization |
| `calendar_events.attendees` inline JSON | Kept inline JSON (§4.8) | Matches domain type; §0.1(2) |
| `transcripts.summary`/`action_items`/`key_points` | **Dropped** | Pre-chunking-era; confirm no live read path first |
| `transcripts.speaker` (mic/system label) | **Not ported** | Confirmed dead |
| `meeting_series.owner_person_id`, timestamps | **Added** (§4.7) | Models follow-on |
| No soft-delete anywhere | **`isDeleted`/`deletedAt` on every synced table** | Sync-aware checklist gap |
| sqlx snake_case wire (4 un-renamed types) | camelCase columns + a decode adapter for engine JSON (§4.11) | `arikit-models.md §7.7` |

### 4.11 The snake→camel decode adapter (resolves `arikit-models.md §7.7`)
Not a schema concern — a narrow decode shim for the transition window where `AriKit.Models` must decode raw JSON from the frozen Rust engine's IPC for the four types whose Rust structs carry no `#[serde(rename_all)]` (`MeetingModel`/`Transcript`/`Speaker`/`SpeakerSegment` — confirmed; `persons`/`calendar`/`meeting_series` are all `camelCase`-renamed). `Store/Coding/SnakeCaseDecoding.swift` provides `Models.snakeCaseAdaptingDecoder` — a `JSONDecoder` with `keyDecodingStrategy = .convertFromSnakeCase` composed with the existing RFC3339 date strategy (orthogonal knobs, no change to `Models.jsonDecoder`). Lives in `Store`, not `Models` (Models stays wire-transport-agnostic). Used only where Store ingests raw engine JSON for these four types (the importer; later, any live protocol bridge). GRDB persistence never uses it — records map columns per this schema (camelCase by construction).

### 4.12 `meetingNote` — NEW, kept per data-preservation (§0.1(1))
`meeting_notes` (`20251223000000`) is real user data. Add an additive `MeetingNote` domain type to `AriKit.Models` and:
`meetingNote`: `id`(PK), `meetingId`(FK→meeting CASCADE, indexed), `bodyMarkdown`(or the legacy note text column — confirm exact column at implementation time by reading the migration), `createdAt`/`updatedAt`, `isDeleted`/`deletedAt`. Importer maps `meeting_notes` → `meetingNote` directly (§5.2). Round-trip test added (§7).

## 5. The importer — one-time, read-only, idempotent

The biggest novel piece and the user's explicit requirement ("keep the data we have"). A first-class subsystem, not a script.

### 5.1 Source-open
- **Locate:** the legacy file is `~/Library/Application Support/com.meetily.ai/meeting_minutes.db` (bundle id `com.meetily.ai`; filename confirmed in `ari-engine/src/database/manager.rs`). The app-target caller passes this `URL` in — the importer takes a source `URL`, never hardcodes it.
- **Open read-only:** `DatabaseQueue` with `configuration.readonly = true` — a second, independent connection on a **different file** than the one `AppDatabase` owns, so principle 3 holds. Read-only mode never checkpoints/writes, so it is safe alongside a still-running Tauri app in the transition window.
- **No migration run against it.** Read the legacy schema as-is (the 25 sqlx migrations are strictly additive, so any legacy file has the full column set).

### 5.2 Table-by-table mapping
| Legacy table | AriKit table(s) | Notes |
|---|---|---|
| `meetings` | `meeting` | Direct copy + `isDeleted=false`; `folder_path`→`audioReferencePath` unchanged (audio not moved, §5.4) |
| `transcripts` | `transcript` | 10 carried columns; `summary`/`action_items`/`key_points`/`speaker` read+logged, not written (§4.10) |
| `summary_processes` | `summary` | Best-effort JSON parse of `result` → `bodyMarkdown`; parse failure → skip + log (§5.5); `result_backup` not imported |
| `speakers` | `speaker` | Direct; `centroid`/`embedding`/`dim` byte-for-byte (opaque vectors) |
| `speaker_segments` | `speakerSegment` | Direct |
| `persons` | `person` | Direct; single `is_owner=1` invariant checked (§5.5) |
| `profile_facts` | `profileFact` | Direct; `source_kind`→`origin` at write time |
| `profile_fact_sources` | `profileFactSource` | Direct |
| `meeting_series` + `series_ledger` + `meeting_series_members` | `series` + `seriesLedger` + `seriesMember` | Direct across three tables (schema already matches Rust's normalization here) |
| `calendar_events` | `calendarEvent` | `attendees` JSON copied through into `attendeesJson` |
| `calendar_sync_settings` | `calendarSyncSetting` | Direct |
| `meeting_notes` | `meetingNote` | **Direct — kept per §0.1(1)** (data preservation) |
| `settings` / `transcript_settings` | *(not imported)* | API keys/secrets never live in a synced Codable type — future Keychain/Settings layer; importer never reads their values |
| `recall_chunks`/`recall_fts`/`recall_index_state`/`ask_conversations`/`ask_messages` | *(deferred to the Recall port, §9)* | Fabricating a Recall schema ahead of that module would repeat the anti-pattern the Models plan avoided |

### 5.3 Idempotent + re-runnable
Every write is an **upsert keyed on the legacy row's stable UUID PK** (`INSERT ... ON CONFLICT(id) DO UPDATE`). Running twice → same end state, no duplicates. Running after some Swift-native data exists is safe (native rows get fresh UUIDs, no collision).

### 5.4 Audio handling (principle 5: text syncs, audio stays local)
The importer **never touches audio files**. `meeting.audioReferencePath` is a `LocalAudioReference` wrapping the **same absolute path** the legacy row pointed at — no copy, no move. AriKit and legacy rows can reference the same on-disk audio during the transition (a feature, not a bug). If the legacy app-data dir is later relocated/deleted, previously-imported paths go stale — a known, accepted limitation, surfaced as a report warning if the referenced path is missing at import time.

### 5.5 Verification (a No-Fake-State analog for the importer)
```swift
public struct ImportReport: Sendable {
    public struct TableResult: Sendable {
        public let table: String
        public let sourceRowCount: Int
        public let importedCount: Int
        public let skippedCount: Int
        public let skipReasons: [String]
    }
    public let tables: [TableResult]
    public let startedAt: Date
    public let finishedAt: Date
    public var isFullyReconciled: Bool {
        tables.allSatisfy { $0.importedCount + $0.skippedCount == $0.sourceRowCount }
    }
}
```
- **Row-count reconciliation:** per mapped table, `SELECT COUNT(*)` on the source; `importedCount + skippedCount` must equal it exactly (any silent drop is a bug, caught by §7 tests).
- **Spot-check:** a sample of imported rows re-read through the Store's own repositories and compared field-by-field to the source — proves valid, readable AriKit data, not just byte-copy.
- **Known data bug carried, not masked:** the pre-existing 2× `audio_end_time` bug (per the S2 spike) is copied through faithfully (not the importer's job to fix source data) but flagged in the report where a transcript's `audio_end_time` exceeds the audio file duration.

### 5.6 Failure modes
| Failure | Behavior |
|---|---|
| Legacy file missing | Report with zero tables + top-level `.sourceNotFound` error — not a crash, not a silent success |
| Legacy file locked (Rust running) | Read-only open should succeed (SQLite readers don't block a WAL writer); if not, surface the error, no silent retry-loop |
| A row fails to map | Skip the **row**, log in `skipReasons`, continue the table — one bad row never aborts the whole import |
| Interrupted mid-run | Safe to re-run (idempotent upserts §5.3); each table's import runs in its own transaction |

## 6. Migration strategy — `DatabaseMigrator`
Fresh Swift migration history — **not** a port of `_sqlx_migrations`. One **`v1_baseline`** migration creates every table in §4 in its final (post-all-25-sqlx-migrations) shape. Every subsequent Swift-side change is a new registered migration, never editing `v1_baseline`. `PRAGMA foreign_keys = ON` in `prepareDatabase`. `DatabasePool` (WAL) in production; `DatabaseQueue` in tests/previews.

> ⚠️ **`v1_baseline` is FROZEN as of the 2026-07-22 incident, and `eraseDatabaseOnSchemaChange` is OFF by default.** The "extend-in-place while unshipped" policy below (the 2026-07-17 slice-1 finding) is **RETIRED**: a DEBUG build with `eraseDatabaseOnSchemaChange = true` detected an in-place baseline edit (`askConversation.seriesId`) and **silently wiped a real 22-meeting DB**. The baseline is now shipped — all future schema changes are new additive `v2+` migrations, a real schema mismatch surfaces as an honest `.failed` (never a wipe), and a pre-migration `VACUUM INTO` backup runs before the migrator. See **`docs/plans/robust-migration-and-backup.md`**.

**Slice-1 findings (2026-07-17) — SUPERSEDED by the freeze above; kept for history:**
- ~~**`v1_baseline` is being built incrementally while it is still unshipped.**~~ (RETIRED — see the ⚠️ note.) Slice 1 created only `meeting`/`transcript`/`speaker`/`speakerSegment` in `v1_baseline`; later slices extended it in place. The 2026-07-22 addition of `askConversation.seriesId` was the **last legal in-place edit** — the baseline is now frozen.
- **FK forward-references fail at `CREATE TABLE` time with `foreign_keys = ON`.** `speaker.personId` could NOT be declared `REFERENCES person(id)` in slice 1 because `person` doesn't exist yet (SQLite validates the parent table exists at DDL time, not lazily at DML). It's a plain indexed nullable column for now. **Step-5 action (person table):** create `person` *before* `speaker` in `v1_baseline`'s table order, then either add the `REFERENCES person(id) ON DELETE SET NULL` to `speaker.personId` (requires table-recreate since SQLite can't `ALTER` in an FK) or, simplest, define `speaker` after `person` in the baseline so the FK is inline from the start. Same applies to any other cross-table FK — order tables parent-before-child in `v1_baseline`.
- **`Meeting.templateId`** column exists (§4.1) but `AriKit.Models.Meeting` has no `templateId` field yet — persisted as `NULL`, not round-tripped. Add to the Model when template selection lands.
- **`speakerSegments` repository** was added to `AppDatabase`'s surface (not in the original §2.2 list) — fold it into §2.2.

## 7. Acceptance / invariant tests (Swift Testing preferred)
New files under `AriKit/Tests/AriKitTests/Store/`:
1. **`SchemaFidelityTests`** — for each §4 table, assert (via GRDB introspection) the migrated columns/types/nullability match the spec.
2. **`RoundTripFidelityTests`** — for every repository, `upsert` a domain value, read it back, assert equality (tolerant enums, `Identifier<T>`, `Data` blobs, `Date` precision).
3. **`ImporterFixtureTests`** — a checked-in fixture legacy `.sqlite` (mirroring §4.10's Rust shape, a few rows per table incl. one malformed `summary_processes.result`, one calendar event with 2 attendees, one `meeting_notes` row) → run importer → assert (a) `isFullyReconciled`, (b) every imported row matches source via repositories, (c) the malformed summary row is skipped+reported not silently dropped, (d) a **second** run yields an identical end state (idempotency).
4. **`ProvenanceRoundTripTests`** — persist a `ProfileFact` + `[ProfileFactSource]`, read via `withProvenance`, assert the `supersedeChain` walk and that read-time `sourceCount` matches `COUNT(*)`.
5. **`TombstoneTests`** — `softDelete` never removes a row; default `all` excludes it; `all(includingDeleted: true)` includes it with `deletedAt`; state survives round-trip.
6. **`SingleOwnerTests`** — honest about SQLite's multi-connection reality: assert exactly one `AppDatabase` construction site in the app launch path (application-level discipline), not a false claim GRDB prevents a second connection.
7. **`MeetingNoteRoundTripTests`** — persist + read a `MeetingNote`; importer maps a fixture `meeting_notes` row (folded into `ImporterFixtureTests`'s fixture).

## 8. Invariants preserved
- **One process owns the DB (principle 3).** `AppDatabase` is the sole writer of the AriKit file; the importer's second connection is read-only on a *different* file. No sqlx+GRDB dual-write.
- **Sync-aware-but-off (principle 4).** All four checklist items honored in §4; verified by `TombstoneTests` now → Phase 5.5 is a switch-on.
- **Sync text / audio local (principle 5).** Importer references audio paths, never copies bytes (§5.4).
- **No-Fake-State.** `sourceCount`/`sourceMeetingTitle` computed live, never stored-and-drifting; `ImportReport` never claims success it can't back with a count; tombstones make deletion honest.
- **Two-tier identity / provenance (F2).** `person` vs `profileFact` stay distinct tables with a real FK.
- **Consent-before-record** is out of scope (an Engine/capture concern) — `Store` has no recording-trigger logic.

## 9. Explicitly deferred
- **CloudKit wiring (Phase 5.5).** Schema is sync-*ready*; no `CKRecord` mapping/container/sync-engine config here. No later migration needed to enable it — the point of building sync-aware now.
- **FTS5 / sqlite-vec recall indices (`AriKit.Recall`, a later Phase-3 step).** `recall_chunks`/`recall_fts`/`ask_*` and the BM25⊕vector machinery are a separate work stream; this schema leaves room (no name collisions, FKs designed to be joined from a future chunk table) but does not build them.
- **Live cutover to Swift-as-sole-owner.** This produces a Store that *can* be sole owner + a one-time importer; it does not flip the running app (needs the Phase-2 shell first). The importer is a data-continuity tool usable once the Swift shell exists.
- **`calendarSyncSetting` module placement** — possibly a Settings layer, not `Store`; not resolved here.
- **Settings/API-key persistence** — future Keychain layer; out of scope.

## 10. Sequencing (each step independently testable)
All steps touch only `Store/**` + `AriKitTests/**` + two small additive `Models/` files (`Summary`, `MeetingNote`) + `Package.swift`.
1. **`AppDatabase` + migrator skeleton** — empty `v1_baseline`, in-memory + on-disk construction, actor isolation clean under Swift 6. Add the SQLiteData/GRDB dependency to `Package.swift`.
2. **Core meeting/transcript/speaker/speakerSegment tables** (§4.1–4.4) + records/repositories + `SchemaFidelityTests` + `RoundTripFidelityTests`.
3. **`Summary` domain type** (§4.9) + `summary` table + repository + tests — own reviewable step (new domain vocabulary).
4. **`MeetingNote` domain type** (§4.12) + `meetingNote` table + repository + tests — own step (data-preservation addition).
5. **Persons / profile-facts two-tier** (§4.5–4.6) + `ProvenanceRoundTripTests`.
6. **Series + calendar** (§4.7–4.8) + fidelity tests (incl. the series two-table join).
7. **Tombstones across all tables** + `TombstoneTests` (may be folded per-table into 2–6; last here to be reviewable as "the one real gap closed").
8. **The snake→camel decode adapter** (§4.11) + a decode test reusing the committed engine-JSON fixtures.
9. **The importer** (§5) — biggest step, last (depends on every repository). Sub-sequence: reader/connection → mapping functions simplest tables first (`speakers`,`persons`,`meeting_notes`) before the two-table `series` join and the lossy `summary_processes` parse → `ImportReport` → `ImporterFixtureTests` (incl. idempotency re-run).
10. **`SingleOwnerTests`** — thin discipline check; any time after step 1.

**Risks:** (a) schema drift vs the frozen Rust source — low (frozen), but re-check §4/§4.10 if a bugfix migration lands; (b) the lossy `summary_processes.result` parse — inspect several real `result` blobs from the existing `meeting_minutes.db` (the S1–S3 rigs already read it) before finalizing; (c) confirm the exact `meeting_notes` column name/shape from its migration; (d) verify SQLiteData's current `@Table` macro API before choosing GRDB-records-vs-macros at the record layer (§0.1(3)).
