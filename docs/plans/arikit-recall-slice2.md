# AriKit `Recall/Index/` — Slice 2: index schema + `RecallIndexRepository` (spec)

## 0. Status & scope guard

**STATUS: COMPLETE (2026-07-18, commit `d2251f0`, branch `arikit-recall-slice2`).** Built tests-first, reviewer-verified (no BLOCKER/HIGH; 2 cosmetic fixes applied). Full suite 150 tests / 25 suites green, 0 warnings, Swift 6 strict. This doc is the as-built record.

Slice 2 of `docs/plans/arikit-recall.md` (§5, §2.3, §4) — Phase 3.1's recall stream, index-table sub-step. Builds on the **completed** Store (`docs/plans/arikit-store.md`, STATUS: COMPLETE 2026-07-17) and the **landed** Recall Slice 1 pure domain layer (`AriKit/Sources/AriKit/Recall/{Shell,Citations,Chunking,Embedding}/**`, `docs/plans/arikit-recall.md` §5 Slice 1).

**Scope guard.** This spec touches only:
- `AriKit/Sources/AriKit/Recall/Index/**` (new) — domain values + `RecallIndexRepository` + its internal GRDB records.
- `AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift` — an **additive append** to the still-unshipped `v1_baseline` migration (per `arikit-store.md` §6 slice-1 finding: extend in place, don't fork a new migration, since it hasn't shipped).
- `AriKit/Sources/AriKit/Store/AppDatabase.swift` — one new `nonisolated var recallIndex: RecallIndexRepository` accessor, mirroring every existing repository accessor.
- `AriKit/Tests/AriKitTests/Recall/Index/**` (new).

This is the explicit "additive coordination with Store" hand-off `arikit-recall.md` §0/§4 anticipated — not a re-opening of the Store work stream, and not a second migration file. No Rust file, no `Cargo.toml`, no `frontend/**`/`ari-engine/**` file is touched.

**Honest framing.** This is a Swift-side schema build for a frozen Rust feature (F7 index tables) — sanctioned porting work per plan principle 8, not new Rust capability.

## 1. Goal & seam

Give the recall subsystem a durable, queryable index: per-chunk transcript rows (`recallChunk`), per-meeting index bookkeeping (`recallIndexState`), a lexical FTS5 mirror (`recallFts`), and the (schema-only, for now) Ask conversation tables (`askConversation`/`askMessage`). Attaches to seam #2 (DB/repository layer). Lands entirely on the Swift side — the frozen Rust `recall_index.rs`/`add_recall_index.sql` are read-only reference; nothing here edits them.

Slice 2 builds the **schema + the `RecallIndexRepository`** (the chunk/state/FTS surface). It deliberately does **not** build `AskConversationStore` (Slice 6) or the search/indexer layers (Slices 4/5) — the `askConversation`/`askMessage` tables are created now (so later slices have a stable schema to build against) but have no repository yet.

## 2. Module & surface

### 2.1 File layout (new)

```
Recall/
└─ Index/
   ├─ RecallChunk.swift              public domain values: RecallChunk, RecallChunkInput,
   │                                  RecallIndexState, RecallIndexSummary, RecallFTSHit,
   │                                  RecallEmbeddingRow, RecallChunkID (typed id)
   ├─ RecallChunkRecord.swift         internal GRDB record for `recallChunk`
   ├─ RecallIndexStateRecord.swift    internal GRDB record for `recallIndexState`
   └─ RecallIndexRepository.swift    public Sendable struct — the only way feature code
                                       touches recallChunk/recallIndexState/recallFts
```

`askConversation`/`askMessage` get **no** record/repository file in Slice 2 — only table DDL in the migration (Slice 6 adds `Recall/Conversations/AskConversationStore.swift` + its records later, per `arikit-recall.md` §5 Slice 6).

Placement follows the human decision: records + repository live in `Recall/Index/`, constructed from the Store's injected `any DatabaseWriter`, obtained via a new `AppDatabase.recallIndex` accessor — identical wiring to every other repository (`AppDatabase.swift:52-90`). Records are `internal` (not `public`), matching Store's record-privacy discipline (`arikit-store.md` §2.1) — this holds even though the files live outside `Store/`, because `Recall/Index/` and `Store/` compile into the same single `AriKit` target/module (`AriKit/Package.swift:64-72`); `internal` is enforced at the module boundary, not the directory.

### 2.2 Domain value types (public)

Mirrors the Rust `RecallChunkInput`/`RecallChunk`/`RecallIndexState` (`ari-engine/src/database/repositories/recall_index.rs:6-17`, `ari-engine/src/database/models.rs:87-131`) and the typed-ID convention (`MeetingID = Identifier<Meeting>`, `Meeting.swift:17`; `Identifier<Entity>` is an unconstrained phantom-typed wrapper, `Identifier.swift:13`, so `Identifier<RecallChunk>` is valid with no new protocol conformance needed).

```swift
public typealias RecallChunkID = Identifier<RecallChunk>

/// A persisted, indexed transcript chunk (← Rust `RecallChunk`, database/models.rs:87-100).
/// `createdAt` is kept as raw RFC3339 `String`, NOT `Date` — see §4's timestamp-format note.
public struct RecallChunk: Codable, Hashable, Sendable, Identifiable {
    public var id: RecallChunkID
    public var meetingId: MeetingID
    public var chunkIndex: Int
    public var chunkText: String
    public var startTime: Double?
    public var endTime: Double?
    public var timestampLabel: String?
    public var embedding: Data?
    public var embeddingModel: String?
    public var dim: Int?
    public var tokenEstimate: Int?
    public var createdAt: String
}

/// A chunk staged for insertion (← Rust `RecallChunkInput`, recall_index.rs:6-17). The caller
/// (Slice 5's `Indexer`) mints `id` (a fresh UUID, matching `Uuid::new_v4()`, indexer.rs:109) and
/// supplies the embedding bytes already packed (`Recall.packF32`, Slice 1). `meetingId`,
/// `contentHash`, `embeddingModel` (whole-meeting), and `now` are separate `replaceMeetingChunks`
/// parameters, not part of this type — mirrors the Rust split exactly.
public struct RecallChunkInput: Sendable {
    public var id: RecallChunkID
    public var chunkIndex: Int
    public var chunkText: String
    public var startTime: Double?
    public var endTime: Double?
    public var timestampLabel: String?
    public var embedding: Data?
    public var embeddingModel: String?
    public var dim: Int?
    public var tokenEstimate: Int?

    public init(
        id: RecallChunkID, chunkIndex: Int, chunkText: String,
        startTime: Double? = nil, endTime: Double? = nil, timestampLabel: String? = nil,
        embedding: Data? = nil, embeddingModel: String? = nil, dim: Int? = nil,
        tokenEstimate: Int? = nil
    ) { /* … */ }
}

/// Per-meeting index bookkeeping (← Rust `RecallIndexState`, database/models.rs:124-131).
/// `indexedAt` is raw RFC3339 `String`, same rationale as `RecallChunk.createdAt`.
public struct RecallIndexState: Codable, Hashable, Sendable {
    public var meetingId: MeetingID
    public var contentHash: String
    public var chunkCount: Int
    public var embeddingModel: String?
    public var embeddedCount: Int
    public var indexedAt: String
}

/// (indexedMeetings, chunkCount, embeddedChunkCount) — ← Rust `index_summary`'s tuple
/// (recall_index.rs:142-155), named for a public API instead of a bare tuple.
public struct RecallIndexSummary: Sendable, Equatable {
    public var indexedMeetings: Int
    public var chunkCount: Int
    public var embeddedChunkCount: Int
}

/// One BM25 lexical hit (← Rust `fts_search`'s `(chunk_id, meeting_id, bm25)` tuple,
/// recall_index.rs:157-173). Ordered best-first — SQLite `bm25()` is ascending (more negative
/// = better match), exactly mirrored: callers must NOT re-sort.
public struct RecallFTSHit: Sendable, Equatable {
    public var chunkId: RecallChunkID
    public var meetingId: MeetingID
    public var score: Double
}

/// One embedded chunk's raw vector bytes for brute-force cosine (← Rust `all_embeddings`'s
/// `(chunk_id, meeting_id, embedding_bytes, dim)` tuple, recall_index.rs:175-187). Unpacking to
/// `[Float]` is the caller's job (`Recall.unpackF32`, Slice 1) — kept out of this repository so
/// Slice 2 has zero dependency on the search layer.
public struct RecallEmbeddingRow: Sendable {
    public var chunkId: RecallChunkID
    public var meetingId: MeetingID
    public var embedding: Data
    public var dim: Int
}
```

### 2.3 `RecallIndexRepository` — public surface

Direct map of `ari-engine/src/database/repositories/recall_index.rs`, one method per Rust associated function, same argument order:

```swift
public struct RecallIndexRepository: Sendable {
    let dbWriter: any DatabaseWriter

    /// ← `replace_meeting_chunks` (recall_index.rs:25-101). One write transaction: DELETE+
    /// re-INSERT recallChunk, DELETE+re-INSERT recallFts (kept in lockstep), UPSERT
    /// recallIndexState. `embeddedCount` is derived from `chunks` (chunks with non-nil
    /// embedding), matching the Rust `filter(|c| c.embedding.is_some()).count()`.
    public func replaceMeetingChunks(
        meetingId: MeetingID,
        chunks: [RecallChunkInput],
        contentHash: String,
        embeddingModel: String?,
        now: String
    ) async throws

    /// ← `delete_meeting` (recall_index.rs:104-120). One write transaction: DELETE from all
    /// three tables for this meeting.
    public func deleteMeeting(_ meetingId: MeetingID) async throws

    /// ← `get_index_state` (recall_index.rs:122-133).
    public func indexState(meetingId: MeetingID) async throws -> RecallIndexState?

    /// ← `count_chunks` (recall_index.rs:135-139).
    public func countChunks() async throws -> Int

    /// ← `index_summary` (recall_index.rs:142-155).
    public func indexSummary() async throws -> RecallIndexSummary

    /// ← `fts_search` (recall_index.rs:159-173). `matchQuery` is a caller-built FTS5 MATCH
    /// expression (Slice 4's `HybridSearch` builds it via `fts_terms`/`build_match_query`,
    /// search.rs:42-65) — this repository does not construct or sanitize it; it is passed
    /// through verbatim, matching the Rust boundary exactly.
    public func ftsSearch(matchQuery: String, limit: Int) async throws -> [RecallFTSHit]

    /// ← `all_embeddings` (recall_index.rs:178-187). Only rows with a non-nil `embedding`.
    public func allEmbeddings() async throws -> [RecallEmbeddingRow]

    /// ← `get_chunks_by_ids` (recall_index.rs:189-210). Empty input → empty output, no query
    /// issued (mirrors the Rust early-return, recall_index.rs:193-195).
    public func chunks(byIds ids: [RecallChunkID]) async throws -> [RecallChunk]
}
```

**`AppDatabase` addition** (`Store/AppDatabase.swift`, one new accessor, same shape as every existing one):
```swift
public nonisolated var recallIndex: RecallIndexRepository {
    RecallIndexRepository(dbWriter: dbWriter)
}
```

## 3. Concurrency model

- `RecallIndexRepository` is a plain `Sendable` struct wrapping the injected `any DatabaseWriter` — identical posture to `TranscriptRepository`/`MeetingRepository` (`TranscriptRepository.swift:8-9`). No actor of its own; `AppDatabase` (already an `actor`) is the sole isolation boundary, and its `dbWriter` is `nonisolated let` (already `Sendable`), so vending `RecallIndexRepository` from a `nonisolated` computed property is safe (`AppDatabase.swift:22,52-90`).
- **FTS5 lockstep is a hard requirement, enforced structurally, not by convention.** `replaceMeetingChunks` and `deleteMeeting` each run their multi-statement body inside **one** `dbWriter.write { db in … }` closure — GRDB's `write` closure is already a transaction (SQLite's implicit `BEGIN`/`COMMIT` around the closure), so `recallChunk`, `recallFts`, and `recallIndexState` can never be observed out of sync from any reader, mirroring the Rust `pool.begin()` / `tx.commit()` pair exactly (recall_index.rs:33,99,105,118).
- Off-main-actor by construction: every method is `async throws`, runs on GRDB's own writer queue, never assumes `@MainActor`. No new hot-path concern — Slice 2 has no embedder/search work, only CRUD.
- **Batched inserts, matching Rust's write-lock discipline.** Rust batches `chunks.chunks(200)` per `QueryBuilder` call to keep the WAL single-writer's lock window short (recall_index.rs:46,68). The Swift implementation should apply the same 200-row batching (a `for batch in chunks.chunked(into: 200)` loop using GRDB's own `insert(db)` per row, or a single multi-row `INSERT` built with bound `?` placeholders per batch) — not a strict SQLite parameter-count requirement here (GRDB doesn't hit the same `push_values` ceiling), but preserved for write-lock-window parity and because it's cheap to keep.
- **Orchestrator** — n/a for Slice 2. No `@unchecked Sendable`, no `nonisolated(unsafe)` anywhere in this slice — every type is either a plain `Sendable` value or a GRDB-owned `Sendable` protocol (`any DatabaseWriter`).

## 4. Persistence — the five tables

Migration home: **append to `v1_baseline`** in `AriKit/Sources/AriKit/Store/Migrations/SchemaMigrator.swift`, after the existing `calendarSyncSetting` table (the migration's current last table, `SchemaMigrator.swift:302-307`) — per the human decision and `arikit-store.md` §6's own precedent ("extend `v1_baseline` in place while unshipped"). Parent-before-child order: `meeting` and `person` already exist earlier in the same migration, so `recallChunk`/`recallIndexState` (FK→`meeting`) can be inline from the start — no deferred-FK gap like the foundation slice's `speaker.personId` (`SchemaMigrator.swift:15-20`) had to work around. Table declaration order within the appended block: `recallChunk` → `recallIndexState` → `recallFts` (no FK, virtual) → `askConversation` (FK→`meeting`, nullable) → `askMessage` (FK→`askConversation`).

### 4.1 `recallChunk` (← `recall_chunks`, migration `:7-24`)

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | `RecallChunkID` (UUID) |
| `meetingId` | TEXT NOT NULL | **FK→`meeting` ON DELETE CASCADE, indexed.** Rust has only a plain index (`idx_recall_chunks_meeting`, migration `:24`) — the Swift schema adds the FK since the single owner can enforce integrity (per `arikit-recall.md` §4's own stated rationale). |
| `chunkIndex` | INTEGER NOT NULL | |
| `chunkText` | TEXT NOT NULL | |
| `startTime` | REAL nullable | |
| `endTime` | REAL nullable | |
| `timestampLabel` | TEXT nullable | |
| `embedding` | BLOB nullable | Packed little-endian f32 `Data`, same convention as `speaker.centroid`/`speakerSegment.embedding` (`SpeakerSegmentRecord.swift:24`). `NULL` = lexical-only chunk. |
| `embeddingModel` | TEXT nullable | |
| `dim` | INTEGER nullable | |
| `tokenEstimate` | INTEGER nullable | |
| `createdAt` | **TEXT NOT NULL** | RFC3339 string — see the timestamp-format note below. |

```swift
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
```

### 4.2 `recallIndexState` (← `recall_index_state`, migration `:27-34`)

| Column | Type | Notes |
|---|---|---|
| `meetingId` | TEXT PK | **FK→`meeting` ON DELETE CASCADE** — Rust declares it as a bare `PRIMARY KEY` with no FK at all; Swift adds the FK (same single-owner rationale as above). |
| `contentHash` | TEXT NOT NULL | FNV-1a hex of the joined transcript text (Slice 5's `fnv1a_hex`, indexer.rs:23-30) |
| `chunkCount` | INTEGER NOT NULL | |
| `embeddingModel` | TEXT nullable | |
| `embeddedCount` | INTEGER NOT NULL DEFAULT 0 | |
| `indexedAt` | **TEXT NOT NULL** | RFC3339 string |

```swift
try db.create(table: "recallIndexState") { t in
    t.primaryKey("meetingId", .text)
        .references("meeting", onDelete: .cascade)
    t.column("contentHash", .text).notNull()
    t.column("chunkCount", .integer).notNull()
    t.column("embeddingModel", .text)
    t.column("embeddedCount", .integer).notNull().defaults(to: 0)
    t.column("indexedAt", .text).notNull()
}
```

### 4.3 `recallFts` — FTS5 virtual table (← `recall_fts`, migration `:39-44`)

Standalone (non-external-content) by design, mirroring the Rust comment verbatim ("for robustness", migration `:37-38`). No FK — SQLite does not support declared foreign keys on a virtual table, and Rust has none either (`chunk_id`/`meeting_id` are plain `UNINDEXED` columns that map back without a join).

```swift
try db.create(virtualTable: "recallFts", using: FTS5()) { t in
    t.tokenizer = .porter(wrapping: .unicode61())   // → tokenize = 'porter unicode61'
    t.column("chunkText")
    t.column("chunkId").notIndexed()
    t.column("meetingId").notIndexed()
}
```

This is GRDB's documented FTS5 builder API (`db.create(virtualTable:using: FTS5())`, GRDB's `Documentation/FullTextSearch.md`; verified via the GRDB repo's own doc, not guessed). `.tokenizer = .porter(wrapping: .unicode61())` produces the `tokenize = 'porter unicode61'` clause matching the Rust migration string exactly (GRDB's `FTS5TokenizerDescriptor.porter(wrapping:)` composes the porter stemmer over a chosen base tokenizer).

**No GRDB `FetchableRecord`/`PersistableRecord` for `recallFts`.** GRDB's own documentation does not specify record-based INSERT for a standalone (non-external-content) FTS5 table — the documented pattern is either raw SQL population or `synchronize(withTable:)` for external-content tables (not our case, since Rust's is deliberately standalone). `RecallIndexRepository` therefore issues raw SQL directly against `recallFts` inside the same write transaction as `recallChunk`:

```swift
// inside the same dbWriter.write { db in ... } closure as the recallChunk delete/insert:
try db.execute(sql: "DELETE FROM recallFts WHERE meetingId = ?", arguments: [meetingId.rawValue])
for batch in chunks.chunked(into: 200) {
    for chunk in batch {
        try db.execute(
            sql: "INSERT INTO recallFts (chunkText, chunkId, meetingId) VALUES (?, ?, ?)",
            arguments: [chunk.chunkText, chunk.id.rawValue, meetingId.rawValue]
        )
    }
}
```

**Resolved risk — the flagged GRDB `bm25()`-ordering question (`arikit-recall.md` §4/§9.8).** GRDB's query-interface `Column.rank`/`.matching(pattern)` sugar is documented for the common case, but its exact weighting/ascending-vs-descending default is not worth relying on for parity with the Rust `bm25(recall_fts) AS score … ORDER BY score ASC` shape (recall_index.rs:164-167), which the search layer (Slice 4) depends on bit-for-bit for its RRF ranking. **Decision: use raw SQL via `Row.fetchAll(db, sql:, arguments:)`, not the query-interface builder**, so the query text is a direct, auditable mirror of the Rust SQL:

```swift
public func ftsSearch(matchQuery: String, limit: Int) async throws -> [RecallFTSHit] {
    try await dbWriter.read { db in
        try Row.fetchAll(
            db,
            sql: """
                SELECT chunkId, meetingId, bm25(recallFts) AS score
                FROM recallFts WHERE recallFts MATCH ?
                ORDER BY score ASC LIMIT ?
                """,
            arguments: [matchQuery, limit]
        ).map {
            RecallFTSHit(
                chunkId: RecallChunkID($0["chunkId"]),
                meetingId: MeetingID($0["meetingId"]),
                score: $0["score"]
            )
        }
    }
}
```
This is confirmed supportable — GRDB's FTS5 documentation explicitly shows both the query-interface and the equivalent raw-SQL `ORDER BY rank`/`bm25()` form; picking raw SQL here is a deliberate choice for exact parity, not a fallback born of uncertainty. `ORDER BY score ASC` matches Rust's own ascending convention (SQLite's `bm25()` is more-negative-is-better).

### 4.4 `askConversation` (← `ask_conversations`, migration `:49-58`) — schema only in Slice 2

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `meetingId` | TEXT nullable | NULL = global chat. **FK→`meeting` ON DELETE SET NULL** (human-approved 2026-07-18). Rust has no FK here, just a plain index `idx_ask_conversations_meeting` (migration `:58`). SET NULL, not CASCADE — if a meeting row is ever hard-deleted, the conversation degrades to a global chat rather than vanishing. |
| `title` | TEXT nullable | |
| `createdAt` | TEXT NOT NULL | RFC3339 |
| `updatedAt` | TEXT NOT NULL | RFC3339, indexed |

```swift
try db.create(table: "askConversation") { t in
    t.primaryKey("id", .text)
    t.column("meetingId", .text)
        .indexed()
        .references("meeting", onDelete: .setNull)
    t.column("title", .text)
    t.column("createdAt", .text).notNull()
    t.column("updatedAt", .text).notNull().indexed()
}
```

### 4.5 `askMessage` (← `ask_messages`, migration `:60-71`) — schema only in Slice 2

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PK | |
| `conversationId` | TEXT NOT NULL | FK→`askConversation` ON DELETE CASCADE, indexed (human-approved 2026-07-18; matches Rust intent — Rust had no declared FK, just `idx_ask_messages_conversation`) |
| `role` | TEXT NOT NULL | |
| `content` | TEXT NOT NULL | |
| `sourcesJson` | TEXT nullable | JSON array of app-supplied `RecallSource` — **never trusted from the model** (conversations.rs:58) |
| `createdAt` | TEXT NOT NULL | RFC3339 |

```swift
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
```

### 4.6 Timestamp format — resolved

The master plan flagged `createdAt`/`indexedAt` as TEXT-vs-DATETIME an open decision (`arikit-recall.md` §9.6); the human's directive resolves it: **TEXT (RFC3339), not GRDB `.datetime`.** Concretely this means the GRDB record properties for `createdAt`/`indexedAt`/`updatedAt` on these five tables are typed **`String`**, not `Date` — the same choice already made for `Transcript.timestamp` (`arikit-store.md` §4.2: "kept `String` per Models decision") — rather than relying on GRDB's built-in `Date` codec, whose default on-disk text format (`"yyyy-MM-dd HH:mm:ss.SSS"`) is *not* RFC3339 and would silently diverge from what Rust writes even though both are "TEXT". Callers (the future `Indexer`, Slice 5) pass RFC3339 formatting explicitly at the call site — this repository does no date math, matching the Rust repository's own `&str` parameters (recall_index.rs:31, `now_rfc3339: &str`).

### 4.7 GRDB records (internal)

```swift
// RecallChunkRecord.swift
struct RecallChunkRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recallChunk"
    var id: String
    var meetingId: String
    var chunkIndex: Int
    var chunkText: String
    var startTime: Double?
    var endTime: Double?
    var timestampLabel: String?
    var embedding: Data?
    var embeddingModel: String?
    var dim: Int?
    var tokenEstimate: Int?
    var createdAt: String
}

// RecallIndexStateRecord.swift
struct RecallIndexStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "recallIndexState"
    var meetingId: String
    var contentHash: String
    var chunkCount: Int
    var embeddingModel: String?
    var embeddedCount: Int
    var indexedAt: String
}
```
Each carries an `init(_:)`/`asModel()` pair translating to/from `RecallChunk`/`RecallIndexState`, matching every other record in the tree (`SpeakerSegmentRecord.swift:28-54`).

### 4.8 Sync-aware constraints (principle 4) applied here

- **`recallChunk`/`recallIndexState`/`recallFts` are DERIVED and LOCAL-ONLY.** Excluded from any future CloudKit `CKRecord` mapping (Phase 5.5); a device rebuilds its own index from transcripts. **No soft-delete tombstones on these three** — `deleteMeeting`/`replaceMeetingChunks` issue real hard `DELETE`s, matching Rust (recall_index.rs:104,35-42). This is a **documented, deliberate deviation** from the Store's "tombstones everywhere" rule (`arikit-store.md` §4 design rules) — justified because these rows are regenerable, not user data, and tombstones would actively fight idempotent rebuild (a stale tombstoned chunk would never get cleaned up by a content-hash-based re-index).
- **`askConversation`/`askMessage` are small user-authored text**, left sync-*shaped* (UUID PKs, plain columns, no tombstone columns added in Slice 2 either — deferred to whichever slice actually builds `AskConversationStore` and decides retention/sync policy) but **not** committed to sync here; whether they ride CloudKit at Phase 5.5 remains open (`arikit-recall.md` §9.7).
- **UUID PKs** — already true for every table here (`RecallChunkID`/`askConversation.id`/`askMessage.id` are UUID-shaped strings, matching indexer.rs:109's `Uuid::new_v4()`).

### 4.9 Out of scope for Slice 2

- **`recallEmbedder` setting** (`arikit-recall.md` §9.1, §4's own note) — a Settings-layer concern. Slice 2 builds no settings table and no `currentBackend()` reader; that lands with Slice 3's embedder work.
- **Legacy recall-index import** — deliberately **not** attempted. The five tables here are all rebuildable/derivable (index) or new user-facing surface not yet wired to any UI (Ask conversations); importing the legacy rows was already explicitly deferred by the Store importer (`arikit-store.md` §5.2's table, "deferred to the Recall port") and this plan keeps that deferral — first run rebuilds the index from transcripts (cheaper and non-lossy vs. importing a stale index shape).

## 5. Sequencing (each step independently testable)

1. **Domain values** (`RecallChunk`, `RecallChunkInput`, `RecallIndexState`, `RecallIndexSummary`, `RecallFTSHit`, `RecallEmbeddingRow`, `RecallChunkID`) — `Recall/Index/RecallChunk.swift`. Zero DB dependency; compiles standalone. Add to `SendableInventoryTests` (Slice 1's pattern, `arikit-recall.md` §6 test 9) as a follow-on assertion.
2. **Migration append** — the five `CREATE TABLE`/`CREATE VIRTUAL TABLE` blocks added to `v1_baseline` in `SchemaMigrator.swift`, in the table order given in §4. `RecallIndexSchemaFidelityTests` written first (below), red until the migration lands.
3. **Records** (`RecallChunkRecord`, `RecallIndexStateRecord`) + their `init(_:)`/`asModel()` translators.
4. **`RecallIndexRepository`** — implement all eight methods against the schema, in the order: `replaceMeetingChunks` → `deleteMeeting` → `indexState` → `countChunks` → `indexSummary` → `chunks(byIds:)` → `allEmbeddings` → `ftsSearch` (leave the FTS5 raw-SQL method last since it is the one genuinely novel GRDB pattern in this slice).
5. **`AppDatabase.recallIndex` accessor** — one-line addition.
6. **`RecallIndexRoundTripTests`** — the full CRUD/idempotency/lockstep suite (§6).

## 6. Acceptance tests (Swift Testing, written first)

Under `AriKit/Tests/AriKitTests/Recall/Index/`, `import Testing` / `@Suite` / `@Test` / `#expect`, matching the house style already used in `AriKit/Tests/AriKitTests/Recall/GlobalSourcesTests.swift:7-10`.

### `RecallIndexSchemaFidelityTests`
1. For each of the five tables, introspect via GRDB (`db.columns(in:)`) and assert the column set/type/nullability matches §4 exactly (mirrors the Store's own `SchemaFidelityTests` pattern, `arikit-store.md` §7 test 1).
2. Assert `recallChunk.meetingId` and `recallIndexState.meetingId` carry a `meeting`-referencing foreign key with `ON DELETE CASCADE` (via `db.foreignKeys(on:)`) — this is the Swift-added delta vs. Rust's plain index, and must be checked explicitly since it's new behavior, not just copied DDL.
3. Assert `recallFts` exists as an FTS5 virtual table (e.g. `SELECT sql FROM sqlite_master WHERE name = 'recallFts'` contains `USING fts5` and `porter`).
4. Assert `askMessage.conversationId` carries a CASCADE FK to `askConversation`, and `askConversation.meetingId` carries a SET NULL FK to `meeting`.

### `RecallIndexRoundTripTests`
Built on `AppDatabase.makeInMemory()` (existing test helper, `AppDatabase.swift:43-50`), seeding a real `Meeting` via `db.meetings.upsert(_:)` first (so the FK is satisfiable):
1. **Replace + read back.** `replaceMeetingChunks` with 3 chunks (one with a packed embedding via `Recall.packF32`, one lexical-only with `embedding: nil`, one more of either) → `chunks(byIds:)` returns all three with every field round-tripping, including `Recall.unpackF32(embedding) == originalVector`.
2. **`countChunks()`** reflects the total across meetings.
3. **`indexState(meetingId:)`** returns `contentHash`/`chunkCount`/`embeddedCount` matching what was written; a second `replaceMeetingChunks` call with a *different* `contentHash`/chunk set fully replaces the prior state (idempotent-replace, not accumulate) — read back and assert the old chunk ids are gone.
4. **FTS5 lockstep.** After (1)/(3), `ftsSearch(matchQuery:)` with a term unique to one chunk's text returns exactly that chunk's id, ordered before an equally-matching-but-lower-relevance chunk — and after replacing the meeting's chunks, the old chunk's text is no longer findable via `ftsSearch` (proves the `DELETE FROM recallFts WHERE meetingId = ?` ran in the same transaction as the `recallChunk` delete).
5. **`indexSummary()`** aggregates correctly across ≥2 meetings (indexed-meeting count, total chunk count, embedded-chunk count only counting non-nil-embedding rows).
6. **`allEmbeddings()`** returns only the embedded chunk(s), with correct `dim`, excluding the lexical-only one.
7. **`deleteMeeting(_:)`** removes rows from all three tables for that meeting; `indexState` returns `nil` afterward; `ftsSearch` no longer finds that meeting's text; `countChunks()` drops accordingly.
8. **FK cascade (the Swift-added delta).** Hard-`DELETE` the parent `meeting` row directly via the test's `@testable import AriKit` access to `AppDatabase.dbWriter` → assert `recallChunk`/`recallIndexState` rows for that meeting are gone via cascade, without any explicit `deleteMeeting` call.
9. **`askConversation`/`askMessage` schema smoke test** (not a round trip — no repository yet): a raw `INSERT` pair succeeds, deleting the parent `askConversation` row cascades to `askMessage`, and a referenced `meeting` row's hard-delete sets `askConversation.meetingId` to `NULL` rather than failing or cascading — confirms the schema is ready for Slice 6 without building its repository yet.

## 7. Invariants preserved

- **No fabricated vectors.** `RecallIndexRepository` never invents an `embedding` — `nil` in, `nil` stored, `nil` back out; a lexical-only chunk stays honestly lexical-only until a later `replaceMeetingChunks` call supplies real bytes (No-Fake-State, `arikit-recall.md` §7).
- **Sources never trusted from the model.** `askMessage.sourcesJson` is schema-ready to hold only app-supplied `RecallSource` JSON — Slice 2 builds no write path to it yet, so there is nothing to violate this invariant with; flagged for Slice 6 to honor when it lands the repository.
- **One process owns the database (principle 3).** `RecallIndexRepository` uses the same injected `any DatabaseWriter` as every other Store repository — no second connection, no second migrator.
- **Single-DB-owner FTS5 lockstep.** The one Slice-2-specific invariant: `recallChunk` and `recallFts` can never be observed diverged, enforced by the shared write transaction (§3), not by convention or a background reconciliation job.

## 8. Risks & sequencing

- **The FTS5 raw-SQL choice (§4.3) is the one genuinely new GRDB pattern in this slice** — verify at implementation time with a real `swift test` run (not just doc-reading) that `db.create(virtualTable:using: FTS5())` with `.tokenizer = .porter(wrapping: .unicode61())` actually compiles and produces working MATCH/bm25 queries against the linked SQLite (Apple's system SQLite ships FTS5 enabled; GRDB.swift's default build links against it). Low risk but worth a quick smoke test before trusting the full acceptance suite.
- **The added FKs beyond Rust's schema** (`recallChunk.meetingId`, `recallIndexState.meetingId` → CASCADE; `askConversation.meetingId` → SET NULL; `askMessage.conversationId` → CASCADE) are a deliberate single-owner upgrade, not a bug — but they mean a hard `DELETE` of a `meeting` row now has cascading side effects that never existed in the Rust schema. Since the Store's convention is soft-delete (tombstones) for `meeting`, this rarely fires in practice; still worth flagging so a future "purge tombstoned rows" maintenance job (if one is ever built) understands it will cascade-delete the recall index for real.
- **WIP-limit / sequencing** — this is the only active slice of the only active AriKit work stream (Recall Slice 2, depending on the completed Store). Slices 3+ do not open until this slice's repository and tests are green, per `arikit-recall.md` §5/§8's own ordering.
- **Schema drift vs. the frozen Rust source** — Low (frozen); re-check `add_recall_index.sql` only if a Rust bugfix migration ever lands there during the transition window.

## 9. Decisions (all resolved 2026-07-18)

1. **`askConversation.meetingId` → `ON DELETE SET NULL` FK.** ✅ Approved — a hard-deleted meeting degrades its conversations to global chats rather than losing them.
2. **`askMessage.conversationId` → `ON DELETE CASCADE` FK.** ✅ Approved — a message with no conversation is meaningless.
3. **Tombstone columns on `askConversation`/`askMessage`.** ✅ Deferred to Slice 6 (the slice that builds `AskConversationStore` and owns retention/sync policy), matching the Store's per-table precedent (tombstone columns added only when the owning slice needs them).
