---
name: sqlite-schema
description: Schema design and migration authoring for the AriKit SQLite store — the meeting-intelligence data model (meetings, transcripts, summaries, speakers, persons, profile facts, calendar events, series, embedding index), additive/non-destructive migration discipline, provenance/supersession for inferred facts, and the CloudKit results-layer split (text syncs, audio stays local). Use when adding or porting a table.
---

# SQLite schema for AriKit.Store

The data model the Swift store must carry over from the Rust engine (26 migrations today), plus the net-new tables the PRD's F1/F2/F4/F7 features need. Pair this with the **`grdb`** skill for the code.

## Design rules

- **Additive and non-destructive by default.** New capability = new table or new nullable column + a new registered migration. Never edit a shipped migration; never drop/retype a column with live data without a data-migration path and explicit sign-off. (Mirrors the Rust `migration-writer` agent's discipline.)
- **Provenance on every inferred fact** (PRD §7, F2). Anything the app *infers* about a person carries: source meeting + segment, timestamp, self-reported-vs-attributed, confidence, and `supersededBy`. Authored identity and inferred facts are two tiers — don't collapse them.
- **The results/audio split** (plan principle 5). Text records (meetings, transcripts, summaries, persons, series, facts) are small and **sync via CloudKit** (bidirectionally — the future mobile app records too); **meeting audio stays device-local** (referenced by path, fetched on demand as a `CKAsset` only if ever needed). Encode this in the model: no audio blobs in synced tables.
- **Foreign keys + indexes on query paths.** `PRAGMA foreign_keys = ON`. Index every column you filter/join on (`transcript.meetingId`, `transcript.speakerId`, `profileFact.personId`, `meetingEvent.meetingId`).

## The core model (target shape)

| Table | Purpose | Key columns / notes |
|---|---|---|
| `meeting` | one recording | `id`, `title`, `createdAt`, `audioPath` (local only, **not** synced) |
| `transcript` | a transcript line/segment | `id`, `meetingId→meeting`, `text`, `startTime`, `endTime`, `speakerId→speaker` (nullable) |
| `summary` | generated summary + provenance | `id`, `meetingId`, `body`, `provider`, `model` (mirrors today's summary-provenance) |
| `speaker` | a within/cross-meeting voiceprint | `id`, `personId→person` (nullable until confirmed), `embeddingModel`, `dim` |
| `speakerSegment` | cluster embedding per meeting | `id`, `speakerId`, `embedding` (blob), `meetingId` |
| `person` | authored identity (tier 1) | `id`, `displayName`, `email` (calendar-seeded), `isOwner` |
| `profileFact` | inferred fact (tier 2) | `id`, `personId`, `fact`, `sourceMeetingId`, `sourceSegmentId`, `observedAt`, `origin` (self/attributed), `confidence`, `supersededBy→profileFact` |
| `calendarEvent` | EventKit event | `id`, `externalId` (`calendarItemExternalIdentifier`), `title`, `start`, `end` |
| `meetingEvent` | meeting ↔ event link | `meetingId`, `calendarEventId` |
| `attendee` | event attendee | `calendarEventId`, `email`, `personId` (resolved) |
| `series` | recurring-meeting group | `id`, `externalSeriesKey`, `title` (F9) |
| `seriesLedger` | living per-series ledger | `seriesId`, open items / decisions / themes (JSON), updated after each summary |
| `transcriptChunk` | per-chunk text + embedding | `id`, `meetingId`, `chunkText`, `embedding` (blob), for F7 hybrid retrieval |

⚠️ **Do not reuse the dead `speaker` *column*** from the Rust migration `20251110000001` (a mic/system label, never read/written). Speaker identity is the `speaker` *table* + `transcript.speakerId` FK. This trap is documented in `.claude/context/open-questions.md`.

## Authoring a migration (GRDB)

```swift
m.registerMigration("v7_add_profile_facts") { db in
    try db.create(table: "profileFact") { t in
        t.primaryKey("id", .text)
        t.belongsTo("person", onDelete: .cascade).notNull()
        t.column("fact", .text).notNull()
        t.column("sourceMeetingId", .text).references("meeting")
        t.column("sourceSegmentId", .text)
        t.column("observedAt", .datetime).notNull()
        t.column("origin", .text).notNull()            // "selfReported" | "attributed"
        t.column("confidence", .double).notNull()
        t.column("supersededBy", .text).references("profileFact")  // supersession chain
    }
    try db.create(index: "idx_profileFact_person", on: "profileFact", columns: ["personId"])
}
```

## The F7 embedding index

`transcriptChunk` stores chunk text + a vector blob for hybrid retrieval (BM25 ⊕ vector RRF). Options in Swift: SQLite FTS5 (BM25, built in) for the lexical half + a vector column you cosine-score in Swift, or `sqlite-vec`. Keep the recall **safety shell** around it regardless: loopback-only embedder, bounded context (~48k chars / 64 sources), **sources returned separately from the answer — never trust model citations.** These invariants are tested; port the tests with the table.

## CloudKit mapping (sync infra lands Phase 1 / store ports Phase 3.1; mobile client consumes it Phase 6)

Each synced table → a CKRecord type in the private DB. Audio is the deliberate exception: keep `meeting.audioPath` local; if audio ever needs to travel, attach it as a `CKAsset` on demand, not as a default-synced field. Sync cursors/state persist in the DB owner, not in a helper's private files (plan principle 3). The sync layer is built and validated (Mac↔iCloud roundtrip) *before* any mobile client exists — the mobile app (Phase 6) inherits a proven schema.
