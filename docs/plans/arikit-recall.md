# AriKit `Recall/` — hybrid-retrieval + safety-shell port (plan)

## 0. Status & scope guard

Phase **3.1** of `plans/swift-migration-plan.md` — the recall half of "Store first" (`swift-migration-plan.md:156`, `:245`): *"port the hybrid-retrieval recall engine + its safety-shell tests (loopback-only, bounded context, no invented citations — dual-run per principle 2)."* This plan is the Swift mirror of the Rust `recall/` subsystem, which physically lives in the carved crate at `ari-engine/src/recall/` (re-exported by the frozen host at `frontend/src-tauri/src/recall/mod.rs:10`).

**Honest framing — this IS a port of a frozen Rust feature (F7), not net-new capability.** Principle 8 forbids *new* capability on the Rust side and mandates that ports land on the target Swift side (`swift-migration-plan.md:36`). Recall (F7) shipped on Rust and is frozen; Phase 3 explicitly calls for re-implementing it in Swift behind dual-run invariant gates (principle 2/6). So this is sanctioned porting work, held to "meet or beat the incumbent" — not a forbidden second Rust track. "Net-new" here means net-new *on the Swift side*, the same sense in which the Models and Store ports were net-new.

**WIP-limit conflict — must be sequenced against the Store stream.** Per principle 8 (`swift-migration-plan.md:36`) at most one migration phase / one feature is active. The AriKit **Store** port is the current active stream (`arikit-store.md §0`, importer in progress, `swift-migration-plan.md:327`). Recall's later slices (index tables, search, orchestrator) **depend on Store schema and repositories** and must not open before Store's slices settle. **The resolution built into this plan:** Slice 1 (the pure domain layer) touches **only** `Recall/**` and `AriKitTests/**` — zero Store schema, zero sidecar, zero LLM — exactly the "no runtime dependency, gates nothing" property that let Models land ahead of Store (`arikit-models.md:21`). Slice 1 is therefore safe to land in parallel *now*; everything from Slice 2 on is gated on Store and on the Engine provider layer and is explicitly deferred.

**Scope guard.** Implementation of this plan touches only `AriKit/Sources/AriKit/Recall/**`, `AriKit/Tests/AriKitTests/Recall/**`, this doc, and — for the index-table slice — additive coordination with `AriKit/Sources/AriKit/Store/**` (see §4, an explicit hand-off, not a fork). No Rust file, no `Cargo.toml`, no `frontend/**` is edited. Where the Swift shape and Rust disagree, the plan documents the delta; it never edits Rust to reconcile.

**Cross-references:** `plans/swift-migration-plan.md` (Phase 3 step 1; principles 2/3/6/8), `docs/plans/arikit-models.md` (value-type substrate; typed IDs, tolerant enums, Codable/date strategy), `docs/plans/arikit-store.md` (§9 explicitly deferred the recall tables "to the Recall port"; §2.2/§3 repository + `AppDatabase` patterns).

## 1. Goal & seam

Port `ari_engine::recall` — the "Ask Meetings" safety shell, hybrid retrieval (FTS5 BM25 ⊕ vector cosine, RRF-fused, recency-weighted), the transcript chunker, the vector/embedder plumbing, the recall index + its schema, and the conversation store — into `AriKit/Sources/AriKit/Recall/`, replacing today's 11-line scaffold (`Recall/Recall.swift:10`, `public enum Recall {}`).

It attaches to seam #2 (DB/repository layer, `architecture.md`) and the recall retrieval seam (`open-questions.md` Q5): in Rust the outer command `api_answer_meetings_locally_impl` (`shell.rs:272`) is a safety-hardened shell around a swappable retrieval call. This port preserves that exact shape — the shell and its bounds are pure and portable first; the retrieval, embedders, and LLM call behind it come later, each gated on the subsystem it needs. It lands entirely on the **target (Swift) side** of the store seam (principle 8, `swift-migration-plan.md:36`).

## 2. Module & surface

### 2.1 File layout under `Recall/`

```
Recall/
├─ Recall.swift                      (repurpose scaffold → module doc + `enum Recall` namespace)
│
├─ Shell/                            ── SLICE 1 (pure; zero Store/sidecar/LLM)
│  ├─ RecallBounds.swift             the const caps (§2.2)
│  ├─ RecallWireTypes.swift          RecallSource, RecallResponse, RecallTurn, TranscriptSearchResult
│  ├─ LoopbackPolicy.swift           isLoopbackOllamaEndpoint
│  ├─ QuestionScope.swift            isUnsupportedRecallQuestion
│  ├─ RecallPrompt.swift             systemPrompt(isMeetingScoped:)
│  └─ ContextBounding.swift          boundedMiddleExcerpt, buildMeeting/GlobalSources,
│                                     summaryMarkdown, buildHistory, buildContext
├─ Citations/                        ── SLICE 1 (pure)
│  └─ Citations.swift                verifySourceCitations, parseTimestampLabel, filterRefTimestamps
├─ Chunking/                         ── SLICE 1 (pure)
│  └─ Chunker.swift                  ChunkDraft, chunkTranscripts([Transcript])
├─ Embedding/
│  ├─ VectorMath.swift               packF32, unpackF32, cosine        (SLICE 1, pure)
│  ├─ EmbedBackend.swift             EmbedBackend enum + from(setting:)/id/modelTag (SLICE 1, pure)
│  ├─ RecallEmbedder.swift           protocol RecallEmbedder (SLICE 3 — needs sidecars/URLSession)
│  ├─ AppleNLEmbedder.swift          NaturalLanguage NLEmbedding, IN-PROCESS (SLICE 3)
│  ├─ OllamaEmbedder.swift           loopback URLSession (SLICE 3, needs provider layer)
│  └─ MLXNomicEmbedder.swift         MLX/GGUF nomic (SLICE 3+, blocked on summary/Engine port)
│
├─ Index/                            ── SLICE 2 (needs Store schema hand-off)
│  ├─ RecallChunk.swift              RecallChunk, RecallChunkInput, RecallIndexState (domain values)
│  └─ RecallIndexRepository.swift    the recall-index repository (Store-writer-backed; see §4)
├─ Search/                           ── SLICE 4 (needs Index + an embedder)
│  └─ HybridSearch.swift             globalSearch / globalSearchScoped, RRF fusion, recency
├─ Indexer/                          ── SLICE 5 (needs Index + an embedder)
│  ├─ Indexer.swift                  indexMeeting / reindexAll (idempotent build)
│  └─ ReindexCoordinator.swift       actor replacing the AtomicBool guard
│
├─ Conversations/                    ── SLICE 6 (needs Store schema; independent of LLM)
│  └─ AskConversationStore.swift     list/get/create/append + 7-day retention prune
├─ People/                           ── SLICE 7 (needs Store persons/calendar/diarization repos)
│  └─ PeopleContext.swift            attachPeople, peopleContextBlock
└─ Orchestrator/                     ── SLICE 8 (needs Engine provider layer)
   ├─ RecallEngine.swift             answerMeetingsLocally (single-shot)
   ├─ RecallStream.swift             streaming variant (AsyncThrowingStream of deltas)
   └─ RecallAgent.swift              Claude agentic tool-use loop (cloud only — LAST)
```

All public types `public`; index records that mirror Store rows stay `internal` to match the Store's record-privacy discipline (`arikit-store.md §2.1`).

### 2.2 Public Swift surface — Slice 1 (the pure domain layer, portable today)

Map of each Rust item to its Swift equivalent. All are `Sendable` free/`static` functions on the `Recall` namespace or on small value types — no `@Observable`, no actors needed here.

| Rust (`ari_engine::recall`) | Swift |
|---|---|
| `is_loopback_ollama_endpoint(Option<&str>) -> bool` (`shell.rs:21`) | `Recall.isLoopbackOllamaEndpoint(_ endpoint: String?) -> Bool` |
| `is_unsupported_recall_question(&str) -> bool` (`shell.rs:34`) | `Recall.isUnsupportedRecallQuestion(_ question: String) -> Bool` |
| `recall_system_prompt(bool) -> String` (`shell.rs:88`) | `Recall.systemPrompt(isMeetingScoped: Bool) -> String` |
| `bounded_middle_excerpt(&str, usize) -> String` (`shell.rs:105`) | `Recall.boundedMiddleExcerpt(_ text: String, max: Int) -> String` |
| `build_meeting_recall_sources(Vec<TranscriptSearchResult>)` (`shell.rs:120`) | `Recall.buildMeetingSources(_ matches: [TranscriptSearchResult]) -> [RecallSource]` |
| `build_global_recall_sources(...)` (`shell.rs:154`) | `Recall.buildGlobalSources(_ matches: [TranscriptSearchResult]) -> [RecallSource]` |
| `summary_markdown(&str) -> Option<String>` (`shell.rs:195`) | `Recall.summaryMarkdown(_ raw: String) -> String?` |
| `build_local_recall_history(Vec<LocalRecallTurn>) -> Result<String,String>` (`shell.rs:218`) | `Recall.buildHistory(_ turns: [RecallTurn]) throws -> String` |
| `build_local_recall_context(&[LocalRecallSource]) -> String` (`shell.rs:239`) | `Recall.buildContext(_ sources: [RecallSource]) -> String` |
| `verify_source_citations(&str, usize) -> String` (`citations.rs:8`) | `Recall.verifySourceCitations(_ answer: String, sourceCount: Int) -> String` |
| `parse_timestamp_label(&str) -> Option<u32>` (`citations.rs:45`) | `Recall.parseTimestampLabel(_ label: String) -> Int?` |
| `filter_ref_timestamps(&str, Option<u32>) -> String` (`citations.rs:78`) | `Recall.filterRefTimestamps(_ answer: String, maxSeconds: Int?) -> String` |
| `chunk_transcripts(&[Transcript]) -> Vec<ChunkDraft>` (`chunker.rs:50`) | `Recall.chunkTranscripts(_ segments: [Transcript]) -> [ChunkDraft]` |
| `pack_f32 / unpack_f32 / cosine` (`embedding.rs:84/92/101`) | `Recall.packF32(_:) -> Data` / `Recall.unpackF32(_:) -> [Float]` / `Recall.cosine(_:_:) -> Float` |
| `EmbedBackend` + `from_setting/id/model_tag` (`embedding.rs:36`) | `enum EmbedBackend: Sendable { case apple, nomicGguf, ollama }` + same three fns |

**Value types (Slice 1)** — the wire shapes, mirroring the Rust `serde` DTOs verbatim, camelCase-native:

- `RecallSource` (← `LocalRecallSource`, `shell.rs:57`): `meetingId, title, matchContext, timestamp: String; meetingDate, summary: String?; speakers: [String] = []`. The Rust type carries explicit `#[serde(rename = "matchContext"/"meetingDate")]` and `#[serde(default)] speakers` — so this camelCase Swift shape decodes the frontend wire directly, **unlike** the four snake_case database-origin Models types (`arikit-models.md §7.7`). Document this so the Store's snake→camel adapter is *not* applied here.
- `RecallResponse` (← `LocalRecallResponse`, `shell.rs:74`): `answer: String; sources: [RecallSource]`.
- `RecallTurn` (← `LocalRecallTurn`, `shell.rs:80`): `role, content: String`.
- `TranscriptSearchResult` (← `models.rs:12`): `id, title, matchContext, timestamp: String; meetingDate, summary: String?`. The retrieval boundary type — the shell consumes it, the search layer produces it, so it lives in Slice 1 as the seam contract. `id` is the meeting id (repeated across a meeting's chunks); the shell dedups + caps.
- `ChunkDraft` (← `chunker.rs:13`): `chunkIndex: Int; text: String; startTime, endTime: Double?; timestampLabel: String?; tokenEstimate: Int`.

Use the ported typed IDs where a value is a real entity id (`MeetingID` etc., `arikit-models.md §7.4`); the recall wire DTOs keep bare `String` for `meetingId`/`id` to match the Rust serde surface exactly (they cross the frontend boundary), with typed IDs used at the repository/orchestrator boundary.

**Constants (`RecallBounds`, ← `shell.rs:98-103` + `search.rs:24-34`):** `maxContextChars = 48_000`, `maxSources = 64`, `maxSourceChars = 8_000`, `maxGlobalMeetings = 8`, `maxHistoryTurns = 8`, `maxHistoryChars = 8_000`; question cap `maxQuestionChars = 1_000` (`shell.rs:283`); search-side `ftsCandidates = 48`, `vectorCandidates = 48`, `rrfK = 60.0`, `maxHits = 60`, `recencyHalfLifeDays = 45.0`, `recencyFloor = 0.35`.

### 2.3 Later-slice surface (signatures only; deferred)

- `protocol RecallEmbedder: Sendable { func embed(_ texts: [String]) async throws -> [[Float]] }` — the pluggable backend the indexer/search call. Best-effort semantics preserved: `throws` → caller degrades to lexical-only (mirrors `embedding.rs:119`, `indexer.rs:83`). A `func modelTag: String` identifies the vector space so a backend change forces a clean re-embed (`embedding.rs:63`).
- `RecallIndexRepository` (§4): `replaceMeetingChunks(meetingId:chunks:contentHash:embeddingModel:now:)`, `deleteMeeting(_:)`, `indexState(meetingId:)`, `countChunks()`, `indexSummary()`, `ftsSearch(matchQuery:limit:)`, `allEmbeddings()`, `chunks(byIds:)` — a direct map of `recall_index.rs`.
- `HybridSearch`: `func globalSearch(_ question: String) async throws -> [TranscriptSearchResult]` and `func globalSearchScoped(_ question: String, allowedMeetingIds: Set<MeetingID>) async throws -> [TranscriptSearchResult]`.
- `Indexer`: `func indexMeeting(_ id: MeetingID) async` (logs, never throws — fire-and-forget parity) and `func reindexAll(force: Bool) async throws -> Int`.
- `RecallEngine.answerMeetingsLocally(question:meetingId:seriesId:history:) async throws -> RecallResponse` — the ported `api_answer_meetings_locally_impl` (`shell.rs:272`).
- Streaming: `func answerMeetingsLocallyStream(...) -> AsyncThrowingStream<RecallStreamEvent, Error>`, `enum RecallStreamEvent: Sendable { case delta(String); case done(RecallResponse) }` — replaces the Rust `EventSink` emit of `ask-stream-delta`/`ask-stream-done` (`stream.rs:11-14`) with a native `AsyncSequence`.
- `AskConversationStore`: `list(meetingId:)`, `get(_:)`, `create(meetingId:title:)`, `appendMessage(conversationId:role:content:sources:)`, with a 7-day retention prune on read (`conversations.rs:16,87`).

## 3. Concurrency model

- **Slice 1 is pure and isolation-free.** Every function is a pure transform over `Sendable` value types; no shared state, no I/O. Safe to call from the audio hot path, STT, or the DB owner without contention — same posture as `Models/` (`arikit-models.md §3`). No actors, no `@unchecked Sendable`, no `nonisolated(unsafe)`.
- **Embedders are `async` I/O behind a `Sendable` protocol.** `RecallEmbedder` conformers do sidecar / URLSession / in-process-ANE work off the main actor; the protocol requirement is `async throws`. Apple `NLEmbedding` is CPU/ANE work — invoked inside the async call, never on the main actor from a view. **No blocking of any hot path:** embedding happens only during index build and query, never in capture/STT.
- **The indexer's `AtomicBool` reindex guard → a Swift `actor ReindexCoordinator`.** Rust uses a module-level `static REINDEX_RUNNING: AtomicBool` with `try_begin_reindex`/`end_reindex` (`indexer.rs:21,138-149`) to prevent overlapping full backfills (startup + first-query auto-trigger + explicit reindex can race). The Swift-6-clean equivalent is an `actor` holding a `Bool` with `func tryBegin() -> Bool` / `func end()`; `reindexAll` calls `tryBegin()`, returns `0` if already running, and `defer { await end() }`. This removes the global mutable static entirely (a strict-concurrency win) while preserving exact single-flight semantics. Per-meeting `indexMeeting` stays unguarded and cheap (matching `indexer.rs:32`).
- **Detached indexing.** Rust fires `index_meeting` as `spawn` fire-and-forget after a save. Swift: a detached `Task { await recall.indexMeeting(id) }` owned by the app/Engine layer; `indexMeeting` logs its own errors and never throws (parity with `indexer.rs:33`). The DB write goes through the single `AppDatabase` writer (principle 3) — no second connection.
- **Orchestrator** is a `Sendable` struct (or small actor) holding repository handles + a `RecallEmbedder` + an LLM client; its methods are `async`, never assume `@MainActor`. Streaming yields on an `AsyncThrowingStream` continuation from a child task; the terminal `.done` event carries the citation-reconciled answer + the separately-computed sources.

## 4. Persistence — the recall index schema (this plan owns it)

`arikit-store.md §9` explicitly deferred the recall tables to "the Recall port" — this plan designs them. Source of truth: the Rust migration `frontend/src-tauri/migrations/20260715130000_add_recall_index.sql` + `recall_index.rs`.

**Single-DB-owner (principle 3).** These tables live in the **same** AriKit SQLite file the Store owns; `AppDatabase` remains the sole writer. `RecallIndexRepository` is a Store-pattern repository — a `Sendable` struct over the injected `any DatabaseWriter` (`arikit-store.md §2.2`, `TranscriptRepository.swift:8`). **Placement is an open decision (§9):** (a) repository + records physically in `Store/` (purest single-owner, grows the Store surface), or (b) in `Recall/Index/` constructed from the Store's `AppDatabase` writer (keeps recall cohesive). Recommendation: **(b)** — recall-specific tables are a recall concern, and the `dbWriter`-injection pattern lets a repository live anywhere while honoring one-owner.

**Migration.** `arikit-store.md §6/§10` notes `v1_baseline` is *still unshipped and extended in place*. So the recall tables are added **either** by extending `v1_baseline` (if Store hasn't shipped when this lands) **or** as a new `v2_recall_index` migration (once it has). This ordering is a coordination point with the Store stream (§8). Parent-before-child FK order applies (`SchemaMigrator.swift:16`): `meeting` already exists, so recall tables slot after it. `PRAGMA foreign_keys = ON` is already set in `prepareDatabase` (`AppDatabase.swift:34`).

### Tables (camelCase GRDB columns, matching `arikit-store.md §4`)

**`recallChunk`** (← `recall_chunks`, migration `:7`): `id`(TEXT PK, `RecallChunkID`), `meetingId`(TEXT NOT NULL, **FK→meeting ON DELETE CASCADE, indexed** — Rust has only a plain index (`migration:24`); the Swift schema adds the FK since one owner can enforce integrity), `chunkIndex`(INT NOT NULL), `chunkText`(TEXT NOT NULL), `startTime`/`endTime`(REAL nullable), `timestampLabel`(TEXT nullable), `embedding`(BLOB nullable — packed little-endian f32; the `Data` pattern already used for `speaker.centroid` / `speakerSegment.embedding`, `SpeakerSegmentRecord.swift:24`), `embeddingModel`(TEXT nullable), `dim`(INT nullable), `tokenEstimate`(INT nullable), `createdAt`(TEXT — Rust stores RFC3339 text, `recall_index.rs:64`; keep TEXT for parity or promote to DATETIME, §9).

**`recallIndexState`** (← `recall_index_state`, migration `:27`): `meetingId`(TEXT PK, FK→meeting CASCADE), `contentHash`(TEXT NOT NULL — FNV-1a hex of joined transcript, `indexer.rs:23`), `chunkCount`(INT NOT NULL), `embeddingModel`(TEXT nullable), `embeddedCount`(INT NOT NULL DEFAULT 0), `indexedAt`(TEXT NOT NULL).

**`recallFts`** — FTS5 virtual table (← `recall_fts`, migration `:39`): `USING fts5(chunkText, chunkId UNINDEXED, meetingId UNINDEXED, tokenize='porter unicode61')`. GRDB creates FTS5 virtual tables via `db.create(virtualTable:using: FTS5())` and supports BM25 ranking; the repository keeps it in lockstep with `recallChunk` on every write inside one transaction (mirrors `recall_index.rs:33-99`). **Standalone (non-external-content) by design** (Rust migration `:37`, for robustness). ⚠️ **Verify at implementation:** GRDB's exact FTS5 `bm25()`-ordering API; use raw SQL in the read closure for `SELECT chunkId, meetingId, bm25(recallFts) AS score … ORDER BY score ASC LIMIT ?` (`recall_index.rs:164`) if the query builder doesn't expose bm25 directly.

**`askConversation`** (← `ask_conversations`, migration `:49`): `id`(TEXT PK), `meetingId`(TEXT nullable — NULL = global chat), `title`(TEXT nullable), `createdAt`/`updatedAt`(TEXT NOT NULL), indexes on `updatedAt` and `meetingId`.

**`askMessage`** (← `ask_messages`, migration `:60`): `id`(TEXT PK), `conversationId`(TEXT NOT NULL, FK→askConversation CASCADE, indexed), `role`(TEXT NOT NULL), `content`(TEXT NOT NULL), `sourcesJson`(TEXT nullable — JSON array of app-supplied `RecallSource`, **never trusted from the model**, `conversations.rs:58`), `createdAt`(TEXT NOT NULL).

**`recallEmbedder` setting** (← migration `20260715140000_add_recall_embedder.sql`): the embedder selector (`apple`/`nomic-gguf`/`ollama`, NULL→apple). This belongs to a Settings layer that `arikit-store.md §9` also deferred. Recall only needs a reader `func currentBackend() async -> EmbedBackend` (`embedding.rs:72`); the storage is a Settings-layer decision, not recall's (§9).

### Sync-aware constraints (principle 4) — how they apply to recall

- **UUID PKs — already true** (`recallChunk.id` and `askConversation.id`/`askMessage.id` are UUIDs, `indexer.rs:109`).
- **The recall index is DERIVED and LOCAL-ONLY.** `recallChunk`/`recallFts`/`recallIndexState` are rebuildable from transcripts and hold large vectors — mark them **excluded from the future CloudKit `CKRecord` mapping** (Phase 5.5); a device rebuilds its own index. **No soft-delete tombstones on these three** — they use hard `DELETE`+rebuild by design (`recall_index.rs:104`), and tombstones would fight idempotent rebuild. This is a **deliberate, documented deviation** from the Store's "tombstones everywhere" rule, justified because these rows are regenerable, not user data.
- **`askConversation`/`askMessage` are small user-authored text** — left sync-*shaped* (UUID PKs, defaulted columns) but not committed to sync; whether they ride CloudKit at 5.5 is a later decision (§9).

## 5. Dependency-ordered slice plan

Each slice is independently testable and lands on the Swift side only. **Slice 1 is the "start now" slice** — the pure domain layer, portable and fully tested today with zero Store schema and zero sidecar/LLM, mirroring how Models landed ahead of Store.

**SLICE 1 — Pure domain layer (START NOW; no dependencies).** Shell pure fns (`LoopbackPolicy`, `QuestionScope`, `RecallPrompt`, `ContextBounding`, `RecallBounds`) + wire value types (`RecallSource`/`RecallResponse`/`RecallTurn`/`TranscriptSearchResult`) + `Citations` + `Chunker` (`ChunkDraft`) + `VectorMath` (pack/unpack/cosine) + `EmbedBackend` enum. Depends only on `AriKit.Models.Transcript` (already ported, `Transcript.swift`). **Zero Store, zero sidecar, zero LLM.** Ports every Rust `#[cfg(test)]` case verbatim (§6). This is the load-bearing safety shell — highest value, lowest risk.

**SLICE 2 — Index schema + `RecallIndexRepository`. ✅ COMPLETE (2026-07-18, `d2251f0`).** The five tables (§4) appended to `v1_baseline` + internal records + the `RecallIndexRepository` (8 methods, map of `recall_index.rs`) + `RecallChunk`/`RecallIndexState`/`RecallChunkInput`/`RecallIndexSummary`/`RecallFTSHit`/`RecallEmbeddingRow` domain values. FTS5 lockstep in one write transaction; raw-SQL `bm25 ASC` for parity. As-built record + resolved §9 decisions: `docs/plans/arikit-recall-slice2.md`. Next: Slice 3 (Apple `NLEmbedder`).

**SLICE 3 — Embedders behind `RecallEmbedder`.** `AppleNLEmbedder` first — **in the Swift world this is in-process `NLEmbedding` (NaturalLanguage framework), NOT a sidecar** — a genuine simplification over Rust's apple-helper sidecar (`embed_apple.rs`). `OllamaEmbedder` (loopback URLSession) needs the ported provider layer. `MLXNomicEmbedder` (nomic GGUF) is **blocked on the summary/Engine port** (Phase 3.4) — Rust runs it through a dedicated llama-helper sidecar (`embed_runtime.rs`); Swift will drive MLX, which doesn't exist until the summary engine lands. **Ship Apple-only in Slice 3; the other two are gated.**

**SLICE 4 — Hybrid search (RRF).** `globalSearch`/`globalSearchScoped`: FTS5 BM25 arm ⊕ vector cosine arm, RRF fusion (`rrfK=60`, `add_rrf` = `1/(k+rank+1)`, `search.rs:67`), recency half-life weighting (45d, floor 0.35, `search.rs:187-202`), keyword-`LIKE` fallback when nothing is indexed (`search.rs:121`; scoped path returns empty rather than leak, `search.rs:118`). Depends on Slice 2 (index) + Slice 3 (an embedder for the semantic arm; degrades to lexical-only without one). Map of `search.rs`. Needs a keyword-`LIKE` fallback added to the Store's `TranscriptRepository`.

**SLICE 5 — Indexer.** `indexMeeting`/`reindexAll` + `ReindexCoordinator` actor + FNV-1a content hash + idempotency check (skip only when unchanged AND fully embedded with the current model, `indexer.rs:63`) + lexical-only degradation. Depends on Slice 2 + Slice 3. Map of `indexer.rs`.

**SLICE 6 — Ask conversation store.** `AskConversationStore` (list/get/create/append + 7-day retention prune on read). Depends on Slice 2's `askConversation`/`askMessage` tables. **Independent of the LLM** — persistence only. Map of `conversations.rs`.

**SLICE 7 — People context.** `attachPeople`/`peopleContextBlock`. Depends on the Store's **persons + calendar + diarization-labeling** repositories (`context.rs:13-17`, `:47`) — persons/facts + calendar are Store slices 5/6; diarization is Phase 3.5 (not yet ported). **Partially blocked:** the owner/attendee block can land when persons+calendar repos exist; the diarization-derived speaker names wait for Phase 3.5. Bounds: `maxPeoplePerMeeting = 8`, `maxFactChars = 160`, `maxNoteChars = 300` (`context.rs:19-21`).

**SLICE 8 — Orchestrator (single-shot → streaming → agentic).** `RecallEngine.answerMeetingsLocally` ties DB + embedder + LLM + the shell together (`shell.rs:272`). **Blocked on the Engine provider layer** (`generate_summary`, `summary/llm_client`), Phase 3.4 — cloud (URLSession) + Ollama + MLX + Claude CLI (`Process`). Streaming (`stream.rs`) reuses the same gates via an `AsyncThrowingStream`. The **Claude agentic tool-use loop** (`agent.rs`, cloud-only, 5 tools, ≤8 iterations, `MAX_SOURCES=24`, `MAX_TRANSCRIPT_CHARS=8_000`) is **last** and depends on the Anthropic client — port it only after single-shot is green. Series-scope (F9) + the series-ledger prompt injection (`shell.rs:355`) ride here too, needing the Store's series repository. Precedence is **meeting > series > global** (`shell.rs:351`).

## 6. Acceptance tests per slice (Swift Testing, written first)

Under `AriKit/Tests/AriKitTests/Recall/`, `import Testing` / `@Test` / `@Suite` / `#expect` (`swift-conventions.md`). **Dual-run (principle 2):** for Slice 1 the invariant suite is a **verbatim intent-port** of the Rust `#[cfg(test)]` cases — they already run green against the incumbent (`shell.rs:474-643`, `citations.rs:114-164`, `chunker.rs:89-137`, `embedding.rs:165-199`); the Swift candidate must reproduce them exactly. These are deterministic pure functions, so "meet or beat" = bit-for-bit behavioral parity.

**Slice 1 (ports the frozen Rust cases 1:1):**
1. `LoopbackPolicyTests` — ← `recall_allows_only_loopback_ollama_endpoints` (`shell.rs:483`): `nil`, `http://localhost:11434`, `http://127.0.0.1:11434`, `http://[::1]:11434` allowed; `https://ollama.example.com`, `http://localhost.example.com:11434`, `"not a url"` denied.
2. `QuestionScopeTests` — ← `recall_refuses_product_scope_outside_saved_meetings` (`shell.rs:498`): "Search the internet", "Check my email inbox" refused; "What decision did we make?" and the calendar-topic question allowed.
3. `HistoryBoundingTests` — ← `meeting_chat_history_is_bounded_and_rejects_untrusted_roles` (`shell.rs:516`): last-8-turns window (drops "turn 0", keeps "turn 2".."turn 9"); `maxHistoryChars` cap on a huge turn; a `system` role throws.
4. `ContextBoundingTests` — ← `meeting_recall_context_keeps_the_start_and_conclusion` (`shell.rs:543`) + `recall_context_includes_real_date_summary_and_transcript_once_per_meeting` (`shell.rs:568`): head/tail excerpt keeps the opening + action items and respects `maxSourceChars+3`; `summaryMarkdown` parses `{"markdown":…}`, legacy plain text, and JSON-object forms; context prints the real date, "Saved summary:" once per meeting, and the transcript excerpt.
5. `GlobalSourcesTests` — ← `global_recall_returns_one_source_per_meeting_with_bounded_excerpts` (`shell.rs:607`): dedup per meeting, merged first+second excerpts, first summary retained, `maxGlobalMeetings` cap.
6. `CitationsTests` — ← all of `citations.rs` tests (`:118-163`): `parseTimestampLabel` (`00:40`→40, `2:05`→125, `1:02:15`→3735, reject "not available"/`00:75`); `verifySourceCitations` keeps in-range, normalizes `[s2]`→`[S2]`, drops out-of-range `[S3]`, leaves `[SX]`/`[S]`/`[1, 2]`/`[see below]` untouched; `filterRefTimestamps` keeps in-range (+2s tol) as `@ref`, demotes out-of-range to bare text, strips ALL when `maxSeconds == nil`.
7. `ChunkerTests` — ← `chunker.rs` tests (`:109-136`): short input → one chunk with `start=0`, `end=11`, label `00:00`, both lines present; long input → multiple sequentially-indexed chunks; empty input → no chunks.
8. `VectorMathTests` — ← `embedding.rs` tests (`:169-198`): `EmbedBackend.from(setting:)` (nil/apple→apple, nomic-gguf, ollama, "weird"→apple); `pack`/`unpack` round-trip preserves values; `cosine` identical=1, orthogonal=0, mismatched-len & empty=0.
9. `SendableInventoryTests` — every public recall type conforms to `Sendable` (compile-time `requireSendable<T: Sendable>` invocation), mirroring `arikit-models.md` test 7.

**Later slices:**
- Slice 2: `RecallIndexSchemaFidelityTests` (GRDB introspection of columns/types/FTS5 virtual table) + `RecallIndexRoundTripTests` (replace/read/`countChunks`/`indexSummary`; idempotent `indexState`; FTS5 lockstep with chunks).
- Slice 4: `HybridSearchTests` on a fixture corpus — a **dual-run parity** test: seed identical chunks + a deterministic stub embedder, assert the Swift RRF ranking matches the Rust ranking on the same inputs (the "meet or beat" gate for retrieval); plus keyword-fallback-when-empty and scoped-returns-empty-not-leak cases.
- Slice 5: `IndexerIdempotencyTests` (unchanged text + same model = no-op; lexical-only upgrades to embedded on a later run) + `ReindexCoordinatorTests` (second concurrent `reindexAll` returns 0).
- Slice 6: `AskRetentionTests` (rows older than 7 days pruned on read; sources round-trip as app-authored JSON).
- Slice 8: `RecallEngineTests` with a stub LLM asserting the full pipeline honors every bound, verifies citations, filters `@ref` by scope, and never trusts model citations; the loopback gate rejects a non-loopback Ollama endpoint end-to-end.

**Eval / spike gate.** Recall is not an S1–S4 spike, but it rests on the Store's **S4-local** confirmation that FTS5 + raw-SQL recall coexist with the GRDB schema (`swift-migration-plan.md:83,101`) — Slice 2's FTS5 table creation *is* that confirmation in practice. No separate spike; flag the FTS5-on-GRDB `bm25()` API check (§4) as the one thing to validate early.

## 7. Invariants preserved (principle 6)

- **Loopback-only local path** — `isLoopbackOllamaEndpoint` ported with identical URL-host semantics (`shell.rs:21`); the orchestrator gate rejects a non-loopback Ollama endpoint (`shell.rs:302`). Test 1 + Slice 8.
- **Bounded context** — all caps + `boundedMiddleExcerpt` head/tail behavior + per-source budget + `maxGlobalMeetings` + history bounds ported exactly (`shell.rs:98-268`). Tests 3–5.
- **Never invents citations** — `verifySourceCitations` drops out-of-range `[S<n>]` (`citations.rs:8`); **sources are computed separately from the answer text** and never parsed back from the model (the orchestrator builds `sources` from the DB, then verifies the answer against `sources.count`, `shell.rs:458`). `askMessage.sourcesJson` stores app-supplied sources, never model output (§4). Test 6 + Slice 8.
- **@ref timestamp verification** — meeting-scoped keeps in-range refs as play-badges (+2s tolerance); global strips all (`filterRefTimestamps`, `citations.rs:78`; orchestrator `shell.rs:461`). Test 6.
- **Refuse out-of-scope** — `isUnsupportedRecallQuestion` (email/inbox/internet/web search/browser/filesystem; calendar deliberately in-scope, `shell.rs:34`). Test 2.
- **No-Fake-State** — embedder failure degrades to lexical-only, **never fabricates zero vectors** (`embed_apple.rs`, `indexer.rs:83`); people/context blocks return `""` when there's nothing real (`context.rs:174`); the index is honest about `embeddedCount < chunkCount`.
- **Consent-before-record** — not a recall concern (capture/Engine); noted for completeness.

## 8. Risks & sequencing

- **WIP-limit / Store coordination (the main risk).** Slice 1 is safe in parallel with the active Store stream (touches only `Recall/**`). Slices 2+ need Store schema — **do not open them until Store's importer + core slices are green**, and coordinate the recall-index migration placement (extend `v1_baseline` while unshipped vs. a new `v2_recall_index`). Recommend landing Slice 1 now, then holding until Store reaches a natural pause.
- **Engine provider layer is the long pole.** The orchestrator/streaming/agentic slice (8) cannot complete until Phase 3.4 (summary/providers) lands — `generate_summary`, MLX, cloud URLSession, Claude CLI `Process`. Until then recall is "indexable + searchable + testable, not yet answerable." Expected, and matches the plan's phase order; the retrieval + safety shell are all provable first.
- **Embedder availability.** Apple `NLEmbedding` is in-process (no sidecar) — a real simplification that unblocks Slices 3/4 early. `nomic-gguf` is blocked on MLX (Phase 3.4); `ollama` needs the provider layer. Ship Apple-only first; the `RecallEmbedder` protocol keeps the others additive.
- **FTS5-on-GRDB.** Verify GRDB's FTS5 virtual-table + `bm25()` ordering API before Slice 2 finalizes (raw SQL is the fallback). Low risk — GRDB has first-class FTS5 support — but confirm the exact call.
- **Diarization dependency in People context (Slice 7).** `attachPeople` leans on diarization labeling (Phase 3.5). Land the owner/attendee half early; gate the speaker-name half.
- **Schema drift vs. the frozen Rust source** — low (frozen), but re-check §4 if a recall bugfix migration lands on the Rust side during the transition.

Ordered, each independently testable: **1** (pure shell/citations/chunker/vector-math) → **2** (index schema+repo) → **3** (Apple embedder) → **4** (hybrid search) → **5** (indexer) → **6** (Ask store) → **7** (people context, partial) → **8** (orchestrator → streaming → agentic). If a spike gate upstream (Engine providers) is missed, Slice 8 stays behind the engine protocol against the Rust sidecar while Slices 1–7 proceed Swift-native.

## 9. Open decisions for the human

1. **`recallEmbedder` setting storage** — recall needs `currentBackend()`; where does the setting persist (a Settings table, `UserDefaults`, Keychain-adjacent)? `arikit-store.md §9` deferred a Settings layer. Recall shouldn't invent one.
2. **sqlite-vec vs. cosine-over-BLOB.** Rust does **brute-force cosine over `all_embeddings` BLOBs** (`recall_index.rs:178`, "fine at single-user scale"). Keep that (portable now, zero new dep) or adopt **sqlite-vec** as a loadable extension? The migration plan names sqlite-vec as a possibility (`swift-migration-plan.md:158,281`) but Store built nothing. **Recommendation: keep cosine-over-BLOB for parity now; treat sqlite-vec as a later optimization** only past tens of thousands of chunks (the Rust comment's own threshold).
3. **Index-table placement** — `Store/` vs `Recall/Index/` for the recall repository + records (§4). Recommendation: `Recall/Index/` using the Store's injected writer.
4. **Streaming API shape** — `AsyncThrowingStream<RecallStreamEvent, Error>` (recommended, idiomatic) vs. a delegate/callback mirroring the Rust `EventSink`. The `AsyncSequence` is the native fit; the SwiftUI transport layer should confirm.
5. **Migration placement / timing** — extend the still-unshipped `v1_baseline` vs. a new `v2_recall_index` (coordinate with the Store stream; ties to §8).
6. **`createdAt`/`indexedAt` as TEXT vs DATETIME** on the index tables — Rust stores RFC3339 text; keep TEXT for parity or promote to GRDB `.datetime`? Minor. Recommendation: **do not import the legacy recall index at all** — it is derived; rebuild on first run is cheaper and avoids a lossy import.
7. **Do `askConversation`/`askMessage` rows sync at Phase 5.5?** Small user-authored chat text; left sync-shaped but uncommitted here.
8. **Verify GRDB's FTS5 `bm25()` ordering API** before Slice 2 (raw SQL is the fallback) — doubles as the Store's S4-local FTS5-coexistence confirmation.
