# Ask Meetings: Tools & Cards — Indexing Fix, Structured Tool-Calling, Inline Entity Cards

## 0. Status

Plan only. No code written. Targets `AriKit` (Recall + Engine modules) and the `Ari` app UI. Single migration phase (Swift-native track, no Rust/React changes — plan principle 8 satisfied: this is net-new Swift capability on the target side of the recall seam, not a re-implementation of a frozen Rust feature — the Rust `recall/agent.rs` Claude-only agentic loop is explicitly NOT what this plan ports; see §5).

WIP note: this is one feature (Ask Meetings quality) touching three concerns (indexing, tool-calling, UI cards) that are causally linked — the cards need tool-calling, tool-calling needs richer indexed content to be worth doing. It is sequenced as three independently-testable, independently-shippable slices (§7) so it can be landed incrementally rather than as one big-bang change, but it is a single plan/feature, not three.

## 1. Goal & seam

**Goal:** three linked improvements to Ask Meetings' answer quality and richness, entirely within the already-live Swift Recall stack:

1. **Fix two confirmed indexing bugs** so the hybrid-search index (`RecallIndexRepository`/`HybridSearch`) actually reflects what's in the Store: (a) indexing currently only runs from a manual Settings button, never automatically after a meeting is recorded/imported/summarized, so freshly-recorded meetings are invisible to Ask until someone remembers to click "Rebuild index"; (b) indexing chunks only raw transcript text, never the generated summary, so facts the summarizer correctly resolved (e.g., a person's name inferred from context) are unsearchable even though they're sitting in `summary.bodyMarkdown`.
2. **Add a small, fixed set of structured "tools"** — deterministic Swift lookups against `MeetingRepository`/`PersonRepository`/`SeriesRepository` — that can answer entity-shaped questions ("did I meet with Sarah about the Q3 budget?", "when's the last time I met with the design team?") more reliably than pure chunk-similarity RAG, without requiring every configured LLM provider to support agentic tool-use.
3. **A typed inline card wire contract + SwiftUI views** so a resolved meeting/person/series renders as a real card in the Ask chat, not just a citation popover — reusing the existing `RecallSource`/`AskSourceCard` pattern rather than replacing it.

**Seam:** this is the Recall subsystem (`AriKit/Sources/AriKit/Recall/`), already fully Swift-native (`AriKit/Sources/AriKit/Recall/Orchestrator/RecallEngine.swift:1-335`). It is Phase 1-equivalent work (F7, queryable meeting store) continuing on the target side — no Rust involvement, no seam-crossing needed. `RecallEngine.answerMeetingsLocally`/`answerMeetingsLocallyStream` is the sole integration point (§5).

**Not a re-implementation of a frozen Rust feature.** The Rust incumbent (`ari-engine/src/recall/agent.rs`, referenced but explicitly NOT ported at `RecallEngine.swift:11-17,137-141`) has a **Claude-only** agentic tool-use loop that only ever ran for global-scope asks with a real Anthropic API key configured, and it is explicitly deferred/out of scope by the existing Swift port's own header comment. This plan does not resurrect that Rust design — it proposes a **provider-agnostic** structured-lookup layer that works the same way regardless of which of the 9 `ProviderKind`s (`LLMClient.swift:76-141`) is configured, which is a materially different (and broader) design than the frozen Rust agent. This is genuinely net-new Swift capability, not a port — confirmed: no `ToolDefinition`/`tool_use`/tool-calling concept exists anywhere in the current Swift or Rust provider layers except that one dormant, Claude-only, never-ported Rust file.

## 2. What's actually broken today (verified against source + live DB this session)

### 2.1 Bug A — indexing never runs automatically

`Indexer.indexMeeting(_:)` (`AriKit/Sources/AriKit/Recall/Indexer/Indexer.swift:41-49`) is a safe, non-throwing, idempotent, fire-and-forget-able operation — but nothing calls it. The only caller in the entire tree is `SettingsViewModel.rebuildIndex()` (`AriKit/Sources/AriViewModels/SettingsViewModel.swift:470-479`), which is wired to a manual "Rebuild index" button (`Ari/UI/Settings/SettingsIntelligenceSection.swift`). Neither:
- `RecordingSession`'s post-stop transcript batch upsert (`AriKit/Sources/AriViewModels/Recording/RecordingSession.swift:305-311`, `try await database.transcripts.upsert(segments)`), nor
- `SummaryService`'s summary-save (`AriKit/Sources/AriKit/Engine/Summary/SummaryService.swift:245`, `try await db.summaries.upsert(summary)`), nor
- `MeetingImportSession`'s import path

...calls `Indexer.indexMeeting` afterward. **Confirmed against the live `ari.sqlite`**: a meeting recorded today (251 transcript rows + a generated summary) has zero `recallChunk` rows and no `recallIndexState` entry — invisible to `HybridSearch.globalSearch` (`AriKit/Sources/AriKit/Recall/Search/HybridSearch.swift:42-44`) except via its legacy-keyword `LIKE` fallback (which only fires when `recallIndex.countChunks() == 0` — line 72-73 — so as soon as ANY meeting is indexed, the fallback stops running globally and this meeting drops out of Ask entirely).

### 2.2 Bug B — indexing never chunks the summary

`Indexer.indexMeetingInner` (`Indexer.swift:52-141`) builds `joined` from `transcripts.forMeeting(meetingId)` only (`Indexer.swift:53-58`) and calls `Recall.chunkTranscripts(transcriptRows)` (`Chunker.swift:47`), which iterates `[Transcript]` exclusively. `Chunker.buildChunk` (`Chunker.swift:85-107`) has no summary-text code path at all. **Confirmed**: a person's name the summarizer correctly resolved from context appears in a meeting's `summary.bodyMarkdown` but never verbatim in the raw transcript text — that fact is structurally unsearchable by `HybridSearch`'s FTS5/vector arms no matter how good ranking gets, because it was never chunked into `recallChunk` in the first place. (Note: `TranscriptSearchResult.summary` IS already attached alongside a matched transcript chunk at prompt-assembly time — `RecallEngine.meetingTranscriptSearchResults`, `RecallEngine.swift:307-316`, and `HybridSearch`'s per-meeting summary lookup, `HybridSearch.swift:169-177` — so the LLM does see the summary text for meetings that already surfaced by transcript match. The bug is specifically that a summary-only fact **cannot be the reason a meeting surfaces at all**, because nothing indexes summary text as searchable chunks.)

## 3. Slice A — indexing fixes

### 3.1 Auto-index after summary generation — single trigger point (fixes Bug A)

**Decided (2026-07-23):** index exactly once per meeting lifecycle, triggered by summary generation, not by transcript save. Indexing after every transcript write (live incremental saves, retranscription, import) would re-embed the same meeting repeatedly before it's ever askable in a useful way — a meeting's transcript is rarely final until its summary is generated, so gating the trigger on "summary exists" collapses what would otherwise be up to 3 separate index runs (transcript save, retranscription, summary save) into 1.

Add one hook: a `RecallIndexTrigger` (a `Sendable` value type over an injected `Indexer`, mirroring the existing `Indexer`/`HybridSearch` "value type over injected handles" convention) with two operations — index-after-summary and purge-on-delete (§3.1.1):

```swift
public struct RecallIndexTrigger: Sendable {
    private let indexer: Indexer
    private let recallIndex: RecallIndexRepository
    public init(indexer: Indexer, recallIndex: RecallIndexRepository) {
        self.indexer = indexer; self.recallIndex = recallIndex
    }

    /// Fire-and-forget: spawns a detached Task calling `indexer.indexMeeting(meetingId)`.
    /// Never throws, never blocks the caller — the summary save's own success/failure is
    /// already committed before this is invoked.
    public func indexAfterSummary(_ meetingId: MeetingID) {
        Task.detached(priority: .utility) { [indexer] in
            await indexer.indexMeeting(meetingId)
        }
    }

    /// Fire-and-forget purge: removes any indexed chunks for a deleted meeting.
    public func purgeOnDelete(_ meetingId: MeetingID) {
        Task.detached(priority: .utility) { [recallIndex] in
            try? await recallIndex.deleteMeeting(meetingId)
        }
    }
}
```

**Single call site for indexing:** `SummaryService.swift:245`, immediately after `db.summaries.upsert(summary)` succeeds — this is the ONLY trigger point (not `RecordingSession`'s transcript-save, not a separate import-time hook). A meeting with no summary yet (summarization skipped, still in progress, or failed) is simply not indexed yet — that's correct and intentional, matching "index once, when the content is actually settled." Re-generating/editing a summary re-triggers indexing (correct: summary text changed, and Bug B's fix means summary text is now part of what's indexed), but that is a deliberate user-initiated action, not a hot-path repeat-fire.

This is intentionally **not** a synchronous call inside `SummaryService` — summary generation is itself a hot path, and `Indexer.indexMeetingInner` does embedding inference (`Indexer.swift:88-105`), which must never block it (§4, concurrency). `Task.detached` + the existing `ReindexCoordinator` single-flight guard (`Indexer.swift:147-159`, reused as-is) keeps concurrent per-meeting indexes from piling up.

#### 3.1.1 Delete purges the index (decided 2026-07-23)

Reversing the earlier draft's "leave stale chunks, query-time filtering already prevents leakage" recommendation — **the human decided delete should actively purge the index**, not just rely on `HybridSearch`'s soft-delete query-time filter (`HybridSearch.swift:140-149`). Add a `purgeOnDelete` call at the meeting-deletion repository call site (`MeetingRepository`'s soft-delete method — confirm exact call site during implementation, likely `MeetingsListViewModel`/`MeetingDetailViewModel`'s delete action or the repository method itself). This mirrors `indexAfterSummary`'s fire-and-forget shape exactly. Net effect: a deleted meeting's chunks are removed from `recallChunk`/`recallIndexState` immediately, not just hidden at query time — smaller index, no risk of a future query-time filter regression silently leaking tombstoned content.

### 3.2 Index summary text too (fixes Bug B)

Extend `Indexer.indexMeetingInner` to build a **second chunk stream** from `summary.bodyMarkdown`, tagged distinctly from transcript chunks so retrieval/prompt-assembly can still tell "this came from the transcript at timestamp X" apart from "this came from the summary" (the existing `RecallSource.timestamp`/`matchContext` UI contract assumes a transcript-shaped excerpt with a real timestamp — a summary chunk has no meaningful timestamp).

**Schema change (additive, `v2` migration — `v1_baseline` is frozen, `SchemaMigrator.swift:9-17`):**
```sql
ALTER TABLE recallChunk ADD COLUMN sourceKind TEXT NOT NULL DEFAULT 'transcript';
```
`sourceKind ∈ {"transcript", "summary"}`. Every existing row backfills to `'transcript'` (correct — that's what it always was). `RecallChunk`/`RecallChunkInput` (`Index/RecallChunk.swift:15-98`) get a new `sourceKind: RecallChunkSourceKind` field (a small `enum String, Codable, Sendable`), threaded through `RecallIndexRepository.replaceMeetingChunks`/`chunks(byIds:)`/`ftsSearch`/`allEmbeddings`.

**Chunker change:** a new `Recall.chunkSummary(_ bodyMarkdown: String) -> [ChunkDraft]` (mirrors `chunkTranscripts`, `Chunker.swift:47-83`, but simpler — a summary is one document, not N ordered segments; still respects `targetChars`/overlap so a long summary doesn't become one giant unsearchable chunk). `ChunkDraft` gains the same `sourceKind` tag (or the caller stamps it when converting `ChunkDraft` → `RecallChunkInput`, keeping `Chunker.swift` summary-agnostic — prefer this: `Chunker` stays a pure text-chunking utility, `Indexer` owns the "this batch came from the summary" knowledge, matching the existing separation of concerns where `Indexer` already decides content-hash/embedding-model bookkeeping that `Chunker` doesn't know about).

**`indexMeetingInner` reshape:**
```swift
private func indexMeetingInner(_ meetingId: MeetingID) async throws {
    let transcriptRows = try await transcripts.forMeeting(meetingId)
    let summary = try await summaries.forMeeting(meetingId)   // NEW: Indexer needs SummaryRepository

    let transcriptDrafts = Recall.chunkTranscripts(transcriptRows)
    let summaryDrafts = summary.flatMap { Recall.chunkSummary($0.bodyMarkdown) } ?? []
    // contentHash must cover BOTH texts, so an unchanged transcript + a newly-generated summary
    // still triggers a re-index (today's hash is transcript-only — Bug B's root cause).
    let contentHash = Self.fnv1aHex(joinedTranscriptText + "\n---\n" + (summary?.bodyMarkdown ?? ""))
    ...
    // embed both draft sets together (one embedder.embed(texts) call across the combined array,
    // for embedding-model consistency + fewer round trips), then split back out by sourceKind
    // when building RecallChunkInput.
}
```
`Indexer`'s init gains a `summaries: SummaryRepository` dependency (additive constructor parameter — `SettingsViewModel.rebuildIndex()`'s call site, `SettingsViewModel.swift:474-479`, and the new `RecallIndexTrigger` call sites both need updating, but this is a mechanical, compiler-enforced change, not a design risk).

**`HybridSearch` change:** none required to the ranking logic itself — a summary chunk is just another row in `recallIndex.chunks`/`allEmbeddings`/`ftsSearch`. The only change is in **presentation**: when building `TranscriptSearchResult` from a chunk whose `sourceKind == .summary` (`HybridSearch.swift:182-193`), set `timestamp: "not available"` (matching the existing summary-only synthetic-row convention already used at `RecallEngine.swift:301`) instead of `chunk.timestampLabel ?? "not available"` — a summary chunk's `timestampLabel` will always be `nil` anyway (the chunker never sets one for summary text), so this is close to free, but worth being explicit about rather than accidentally emitting a stale/wrong timestamp.

## 4. Slice B — structured tools

### 4.1 The core architectural decision: tool-calling feasibility is NOT uniform across providers

**Scope decided (2026-07-23): Slice B targets only `.mlx` (primary, in-process Qwen — the default/expected provider) and `.claudeCLI` (secondary) for now.** The other 7 `ProviderKind`s (`LLMClient.swift:76-141`) are out of scope for this plan; do not build provider-specific tool-calling for `.claude`/`.openAI`/`.groq`/`.openRouter`/`.customOpenAI`/`.ollama`/`.appleFoundation` here. If a future push wants provider-native tool-calling for one of those, it gets its own plan doc.

Verified for the two in-scope providers:

| Provider | Native tool-calling? | Evidence |
|---|---|---|
| `.mlx` (in-process Qwen, via `AriKitEngineMLX`/`MLXClient`) — **primary** | **No tool-calling harness exists in this codebase.** `MLXClient.swift` calls `ChatSession.respond(to:)` — a plain text completion, no structured-tool concept in the `mlx-swift`/`MLXLLM` call shape used here. Building reliable tool-calling on a 4-bit local model via prompt-engineered JSON would be the riskiest, least-trustworthy path available (a 4B on-device model hallucinating a malformed tool call is a real failure mode, with no guided-generation guarantee to fall back on). | `MLXClient.swift:1-80` (read this session). |
| `.claudeCLI` | Subprocess to the local `claude` CLI — whatever tool-use behavior the CLI itself exposes is opaque and out of this app's control; not something to design a request/response contract around. | Out of scope to instrument. |

**Decision:** since NEITHER in-scope provider has a trustworthy native tool-calling surface, there is no uniform "LLM decides which tool to call" option available at all for this plan's actual scope — which resolves what would otherwise be an open question. Instead:

**Tool execution is deterministic Swift code, never delegated to the model.** A lightweight **intent classifier** decides *whether* a question has an entity-lookup shape and *which* fixed tool to run; the tool itself is a plain repository query, not something any LLM "calls." This sidesteps the reliability gap almost entirely — the hard part (does the model reliably emit correct structured tool-call JSON) is replaced with a much easier, cheaper, and fully provider-agnostic problem (does a lightweight classifier recognize "did I meet with X about Y" as an entity-lookup shape).

Two classifier tiers, escalating only when needed:

1. **Heuristic classifier (v1, always available, zero model cost):** a pure Swift pattern-matcher (`RecallIntentClassifier`, testable with zero LLM dependency) recognizing a small number of question shapes via keyword/structure matching — "last meeting with `<name>`", "meetings with `<name>`", "meetings in the `<series>` series", "did I meet with `<name>`" — and extracting the candidate name/series-title substring. This is intentionally narrow: a **false negative** (fails to recognize an entity-shaped question) safely falls through to the existing hybrid-RAG path unchanged — no regression. A **false positive** (misclassifies an open-ended question as entity-lookup) is guarded by requiring the extracted name/title to **resolve to exactly one real, non-deleted `Person`/`Series`/`Meeting` row** before a tool result is ever used (§4.3) — an unresolved or ambiguous (multiple matches) extraction is *also* a safe fall-through, never a fabricated card (No-Fake-State).
2. **FoundationModels-backed classifier (optional enhancement, gated, `.appleFoundation` only):** when the configured provider is `.appleFoundation`, use its `Generable`-guaranteed structured output to classify intent + extract entities more robustly than regex (handles paraphrasing the heuristic can't). This is an **enhancement layered on top of, not a replacement for**, tier 1 — the heuristic stays as the always-available floor for every other provider. Treat this as a stretch goal behind its own spike gate (§7, Slice B.2), not part of the v1 acceptance bar.

This directly answers the user's framing: rather than assuming full agentic tool-use "just works" on-device, the plan uses a **two-pass approach** — pass 1 (classify + deterministically resolve an entity via repositories), pass 2 (the existing single-shot/streaming LLM call, now optionally augmented with the resolved entity's real facts folded into the prompt, mirroring how `PeopleContext.peopleContextBlock` already injects real, non-fabricated context today, `PeopleContext.swift:79-107`). The LLM's role is unchanged: synthesize an answer from real data handed to it. It never picks which tool to call and never invents a query.

### 4.2 The fixed tool set

Each tool is a pure, `Sendable`, repository-backed function — no protocol needed beyond a shared result shape, matching the existing `HybridSearch`/`Indexer`/`PeopleContext` "value type over injected repository handles" convention:

```swift
public struct RecallTools: Sendable {
    private let meetings: MeetingRepository
    private let persons: PersonRepository
    private let series: SeriesRepository

    public init(meetings: MeetingRepository, persons: PersonRepository, series: SeriesRepository) {
        self.meetings = meetings; self.persons = persons; self.series = series
    }

    /// Resolve a person by display-name substring (case-insensitive). Returns nil for zero or
    /// >1 matches — ambiguity is never silently guessed (No-Fake-State).
    public func findPerson(nameContaining query: String) async throws -> Person?

    /// Resolve a meeting by title substring, optionally narrowed by a date hint.
    public func findMeeting(titleContaining query: String) async throws -> Meeting?

    /// Every non-deleted meeting a given person attended, newest first (via the F2 calendar-email
    /// attendee match — the SAME real, non-fabricated signal `PeopleContext` already uses,
    /// `PeopleContext.swift:139-142` — NOT a fabricated "speaker" signal; see §4.4 caveat).
    public func meetings(withPerson personId: PersonID) async throws -> [Meeting]

    /// The most recent N meetings in a series (← `SeriesRepository`'s membership + `all()`).
    public func meetings(inSeries seriesId: SeriesID, limit: Int) async throws -> [Meeting]

    /// Resolve a series by title substring.
    public func findSeries(titleContaining query: String) async throws -> Series?
}
```

`Meeting`/`Person`/`Series` value types already exist in `AriKit.Models` — no new domain types needed here, only the query methods. This module is genuinely additive: no existing repository method changes shape.

### 4.3 Wiring into `RecallEngine`

Add a new pre-step in `RecallEngine.prepare` (`RecallEngine.swift:155-272`), inserted **before** the existing `hybridSearch.globalSearch`/`globalSearchScoped` call (line 213-224), gated so it only ever runs for the **global scope** (meeting-scoped and series-scoped asks already have an unambiguous subject — a tool-based "which meeting/person" lookup is meaningless there):

```swift
// NEW, global-scope only:
if meetingId == nil, seriesId == nil,
   let intent = RecallIntentClassifier.classify(question),
   let resolved = try await resolveEntity(intent, tools: recallTools) {
    // Deterministic path: build a RecallCardPayload from the REAL resolved row (§5), fold a terse
    // real-fact summary of it into the prompt (mirrors PeopleContext's pattern), and set it aside
    // to attach to the RecallResponse once the LLM's answer comes back. Retrieval + prompt
    // assembly CONTINUE as before (hybrid RAG is not skipped) — the card is an ADDITIVE
    // enrichment of the same response, not a replacement path. This keeps the change low-risk:
    // if entity resolution is wrong or absent, the response is byte-identical to today's.
}
```

**Decision, stated explicitly:** hybrid chunk RAG is **never replaced** by tool-calling — it stays the sole mechanism for open-ended "what did we discuss" content questions, and it always runs regardless of whether a tool resolved an entity. Tool-calling is a **strictly additive enrichment**: it can attach a `card` to the response and fold a couple of real extra facts into the prompt (e.g. "Resolved: the person you're asking about is Sarah Ammon, PM, last met 2026-07-10" — a `PeopleContext`-shaped terse block), but the citation/sources/answer-generation pipeline is unchanged. This is the safest integration shape: it cannot regress today's behavior, and every failure mode (classifier miss, ambiguous match, zero rows) degrades to exactly today's behavior.

### 4.4 A caveat this plan must be explicit about (mirrors `PeopleContext`'s own documented gap)

`meetings(withPerson:)` can only resolve "which meetings did this person attend" via the **same calendar-email-attendee matching `PeopleContext` already uses** (`PeopleContext.swift:11-24,139-142`) — there is **no diarization-speaker-labeling signal available at this layer yet** (Phase 3.5, not yet ported). This tool therefore answers "was this person invited to/on the calendar event for this meeting," not "did this person's voice appear in this recording" — a real and important distinction for in-person meetings with no calendar event, or calendar events where an invitee didn't show. The card/prompt copy must say "meetings involving `<name>` (via calendar)" or similar honest framing, never implying diarization-verified presence it can't back up (No-Fake-State).

## 5. Slice C — inline entity cards

### 5.1 Wire contract (additive, back-compatible)

```swift
// RecallWireTypes.swift addition
public enum RecallCardPayload: Codable, Hashable, Sendable {
    case meeting(MeetingCardPayload)
    case person(PersonCardPayload)
    case series(SeriesCardPayload)
}

public struct MeetingCardPayload: Codable, Hashable, Sendable {
    public var meetingId: String
    public var title: String
    public var meetingDate: String?   // RFC3339, same convention as RecallSource.meetingDate
    public var hasSummary: Bool       // real, not fabricated — drives whether the card shows a summary snippet
}

public struct PersonCardPayload: Codable, Hashable, Sendable {
    public var personId: String
    public var displayName: String
    public var role: String?
    public var organization: String?
    public var lastMeetingDate: String?   // from meetings(withPerson:).first, real or nil
    public var meetingCount: Int          // real count from the same query, never estimated
}

public struct SeriesCardPayload: Codable, Hashable, Sendable {
    public var seriesId: String
    public var title: String
    public var meetingCount: Int
    public var lastMeetingDate: String?
}
```

`RecallResponse` (`RecallWireTypes.swift:68-76`) gains one new field:
```swift
public struct RecallResponse: Codable, Hashable, Sendable {
    public var answer: String
    public var sources: [RecallSource]
    public var card: RecallCardPayload?   // NEW, additive, defaults to nil via decodeIfPresent
}
```
Decoding must use `decodeIfPresent` (mirroring `RecallSource`'s own `speakers` default-on-missing-key pattern, `RecallWireTypes.swift:62-64`) so this is forward/backward compatible with any already-persisted `AskMessage.sources`-shaped data (which doesn't carry a card today — that's fine, it decodes to `nil`).

**Persistence:** `AskMessageRecord` (`AskMessageRecord.swift:13-22`) gains an additive nullable `cardJson: String?` column via a new migration (`v3` or combined into the same migration as §3.2's `recallChunk.sourceKind`, implementer's call, both additive `ALTER TABLE`s), mirroring `sourcesJson`'s exact encode/decode/nil-on-absence pattern (`AskMessageRecord.swift:30-35,43-45`). `AskMessage` (`AskConversation.swift:52-75`) gains `public var card: RecallCardPayload? = nil`.

### 5.2 SwiftUI views

Three new small views, siblings of `AskSourceCard.swift`, reusing its exact visual conventions (Marginalia tokens, `MarginaliaSpacing`/`MarginaliaRadius`, `.marginaliaTextStyle`) and `CardRow.swift`'s title/metadata/chevron shape for the row body:

- `AskMeetingCard.swift` — title, friendly date (reuse `AskSourceCard.friendlyDate`'s exact parsing helper — worth factoring out to a shared `RecallDateFormatting` file rather than duplicating, since both need it), an "Open meeting →" button.
- `AskPersonCard.swift` — display name, role/organization line, "N meetings, last met `<date>`" (using the REAL `meetingCount`/`lastMeetingDate` — never "several meetings" vague language), an "Open person →" button.
- `AskSeriesCard.swift` — title, "N meetings, last on `<date>`", an "Open series →" button.

`AskConsoleView.assistantRow` (`AskConsoleView.swift:90-109`) gets a new case: when `item.kind` carries a non-nil card (extend `AskTranscriptItemKind.assistant` to also carry `card: RecallCardPayload?`, mirroring how it already carries `sources`), render the matching card **above** the answer text (the card is the direct, structured answer; the prose is supporting color) inside the same bordered container.

**Tap-through navigation** mirrors `AskSourceCard`'s existing `onOpenMeeting: (String) -> Void` callback (`AskSourceCard.swift:14,48-49`), threaded from `AskConsoleView` (`AskConsoleView.swift:14`) up through whatever hosts it (`AskPageView`/`AskOverlayHost`, not read this session — confirm exact call sites during implementation, but the pattern is already established for `onOpenMeeting`). Add two sibling closures, `onOpenPerson: (String) -> Void` and `onOpenSeries: (String) -> Void`, following the identical wiring shape — this is mechanical, not a design risk, since the existing meeting-open callback already threads through the same view hierarchy.

### 5.3 No-Fake-State discipline for cards

A card renders **only** when `RecallCardPayload` is non-nil, which only happens when Slice B's entity resolution found exactly one real row via a repository query — never a partial match, never a "best guess," never a fabricated count or date. If `meetingCount`/`lastMeetingDate` can't be computed (e.g. a DB error mid-query), the tool call fails and the whole card-attach step is skipped (falls through to the existing sources-only response) — it never renders a card with a placeholder "—" or "unknown" in place of a real field, matching the "empty/loading/error states must be honest" rule (`.claude/rules/design-system.md`).

## 6. Concurrency model

All three new/extended types follow the established convention exactly (`HybridSearch`, `Indexer`, `PeopleContext` are all `Sendable` structs over injected repository handles — no actors, no locks, safe from any isolation domain):

- `RecallIndexTrigger` — `Sendable` struct; `indexAfterSave` spawns `Task.detached(priority: .utility)`, never blocks the caller (the recording/summary hot paths §3.1 must never wait on embedding inference).
- `RecallTools` — `Sendable` struct over `MeetingRepository`/`PersonRepository`/`SeriesRepository` (all already `Sendable`, `AppDatabase`-backed `dbWriter: any DatabaseWriter` — GRDB's own async-safe read/write).
- `RecallIntentClassifier` — a pure, synchronous, `Sendable` enum-namespace of static functions (no I/O, no async) — trivially thread-safe, trivially testable.
- `RecallCardPayload`/`MeetingCardPayload`/`PersonCardPayload`/`SeriesCardPayload` — plain `Codable, Hashable, Sendable` value types, identical shape to every existing recall wire type.
- No new actors. No `@unchecked Sendable`. Nothing here touches the audio/STT hot path — Slice A's `indexAfterSave` explicitly runs OFF that path (detached, utility priority, after the write already committed).
- `RecallEngine.prepare`'s new entity-resolution pre-step (§4.3) is `async throws` like the rest of `prepare` — no new isolation domain introduced, it's just more repository calls inside the same function.

## 7. Persistence

Two additive migrations on top of the frozen `v1_baseline` (`SchemaMigrator.swift:9-17` — editing `v1_baseline` is prohibited; this is non-negotiable per the 2026-07-22 incident):

```sql
-- v2_recall_chunk_source_kind
ALTER TABLE recallChunk ADD COLUMN sourceKind TEXT NOT NULL DEFAULT 'transcript';

-- v3_ask_message_card
ALTER TABLE askMessage ADD COLUMN cardJson TEXT;
```

Both are nullable/defaulted, additive-only, satisfying `robust-migration-and-backup.md` §5 Layer 1's constraints. **Single DB owner reaffirmed:** all access goes through `RecallIndexRepository`/`AskConversationStore`/`MeetingRepository`/`PersonRepository`/`SeriesRepository` — no raw SQLite handles introduced anywhere in this plan. No new tables (deliberately — `sourceKind` and `cardJson` both fit as columns on existing tables rather than inventing new join tables, keeping the migration surface minimal).

## 8. Acceptance tests (Swift Testing, written first)

### Slice A — indexing
- `RecallIndexTriggerTests.indexAfterSummaryEventuallyIndexesTheMeeting` — regression test for Bug A: save a summary via a fake `SummaryService`-shaped flow (or directly call `RecallIndexTrigger.indexAfterSummary`), then poll (bounded retries) `recallIndex.countChunks()` > 0 for that meeting.
- `RecallIndexTriggerTests.transcriptSaveAloneDoesNotTriggerIndexing` — regression test for the "index once" decision: saving a transcript with no summary yet must NOT produce any `recallChunk` rows — guards against a future accidental re-wiring of the trigger onto the transcript-save hot path.
- `RecallIndexTriggerTests.purgeOnDeleteRemovesIndexedChunks` — regression test for the delete-purge decision (§3.1.1): indexing a meeting then calling `purgeOnDelete` leaves `recallIndex.countChunks()` at 0 for that meeting's chunks.
- `IndexerSummaryChunkingTests.summaryOnlyFactBecomesSearchable` — regression test for Bug B: a meeting with a transcript that does NOT mention a name, but a summary that does, is indexed; assert `HybridSearch.globalSearch("that name")` returns a `TranscriptSearchResult` for that meeting with `sourceKind == .summary` provenance (or equivalent assertion via the chunk's stored kind before it's flattened into `TranscriptSearchResult`).
- `IndexerSummaryChunkingTests.contentHashCoversBothTranscriptAndSummary` — an unchanged transcript with a newly-added/edited summary re-triggers indexing (content hash changes), extending the existing `IndexerTests` idempotency suite (`IndexerTests.swift:13-40`) rather than duplicating its fixture style.
- `IndexerTests` (existing suite) — extend, don't replace: add cases for the new `summaries: SummaryRepository` constructor parameter and the split embed-then-recombine-by-`sourceKind` logic, using the same `CountingEmbedder`/`ThrowingEmbedder` fixture pattern already in the file (`IndexerTests.swift:20-40`).

### Slice B — tools
- `RecallIntentClassifierTests` — pure, no DB: table-driven cases for each recognized shape ("last meeting with X", "meetings with X", "meetings in the X series", "did I meet with X") plus explicit **negative** cases (open-ended questions like "what did we decide about pricing" must NOT classify as entity-lookup — this is the regression guard against false positives degrading normal Ask).
- `RecallToolsTests` — against `AppDatabase.makeInMemory()`: `findPerson` returns nil for zero/multiple matches, a single row for an unambiguous match; `meetings(withPerson:)` returns only calendar-attendee-matched meetings (mirrors `PeopleContextTests`' existing email-match fixtures) and is empty (not fabricated) for a person with no calendar-linked meetings; `meetings(inSeries:limit:)` respects the limit and ordering.
- `RecallEngineToolIntegrationTests` (extends `RecallEngineTests.swift`) — a global-scope ask matching a recognized entity shape, with real data available, produces a `RecallResponse.card != nil` AND the same `sources`/citation-reconciliation guarantees as today (never regresses the existing invariant suite). A meeting/series-scoped ask with the identical question text does NOT attempt entity resolution (scope-gated, §4.3). An ambiguous name (two people matching) or an unresolved name (zero matches) produces `card == nil` and falls through to byte-identical existing behavior — this is the single most important regression test in the whole plan, since it's the proof that Slice B cannot make Ask worse.

### Slice C — cards
- `RecallCardPayloadCodableTests` — round-trip encode/decode for each case; a `RecallResponse` JSON blob with no `card` key decodes `card == nil` (back-compat with anything already persisted).
- `AskMessageRecordCardTests` (extends the `AskMessageRecord`/`AskConversationStore` test suites) — `cardJson` round-trips through `AskConversationStore.appendMessage`/`load`, and a `nil` card never round-trips as a fabricated empty-object placeholder.
- SwiftUI: `AskMeetingCardTests`/`AskPersonCardTests`/`AskSeriesCardTests` — snapshot or structural tests (matching however the existing `Ari/UI` test convention verifies view content, e.g. `AskSourceCardTests` if one exists — confirm during implementation) asserting the card never renders a placeholder for a missing count/date, only omits that line.

No dual-run/eval-set gate applies here (this is not a port of an existing Rust behavior with an incumbent baseline to beat — see §1's "not a re-implementation" note) — the acceptance bar is the test suite above, all green, plus a manual runtime check in the signed app (per `.claude/context/build-and-run.md`, "Testing native permissions" is N/A here, but `FoundationModelsClient`'s real on-device path per `FoundationModelsClientTests.swift`'s convention of "device-gated smoke test only" applies if Slice B.2 (the optional FoundationModels-backed classifier) is attempted).

## 9. Invariants preserved

- **Never invents citations** — untouched. `sources`/citation reconciliation (`RecallEngine.reconcile`, `RecallEngine.swift:327-334`) is not touched by any part of this plan; the new `card` field is a wholly separate, additively-decoded field with its own No-Fake-State discipline (§5.3).
- **Bounded context** — the new entity-resolution pre-step (§4.3) adds at most one short, terse real-fact block to the prompt (mirroring `PeopleContext.peopleContextBlock`'s existing bounded-block pattern, `RecallBounds.maxFactChars`/`maxNoteChars`-style caps should be reused or a new small cap added, e.g. `RecallBounds.maxCardContextChars`) — never unbounded.
- **Loopback-only** — untouched; the new tools never construct or configure an `LLMClient`, they only query repositories. The loopback gate in `RecallEngine.prepare` (`RecallEngine.swift:183-188`) still runs exactly where it does today.
- **No-Fake-State** — the central discipline of both Slice B (§4.1's ambiguous-match-never-guessed rule) and Slice C (§5.3's card-only-for-a-real-resolved-row rule); stated as the load-bearing regression test in §8.
- **One DB owner** — no new repositories bypass GRDB; `RecallTools` is built entirely from the three existing repositories, no raw SQL added anywhere in this plan beyond the two additive `ALTER TABLE` migrations (§7), which go through the existing `SchemaMigrator` the same way every prior migration has.
- **Consent-before-record** — not implicated; this plan touches only post-recording retrieval/indexing.

## 10. Risks & sequencing

Three independently-testable slices, in this order (each is shippable alone; B depends on A being landed first only in the sense that better indexing makes B's tool-resolved entities more likely to have useful attached context, not a hard code dependency):

1. **Slice A (indexing fixes)** — lowest risk, highest immediate value (every existing Ask user benefits immediately, no UI change). Ship first. Risk: the new `summaries: SummaryRepository` constructor parameter on `Indexer` is a breaking signature change for its one existing caller (`SettingsViewModel.rebuildIndex()`) — mechanical, compiler-caught, not a design risk.
2. **Slice B.1 (heuristic classifier + fixed tools, additive `card` on `RecallResponse`)** — medium risk, contained by the "falls through to identical behavior on any ambiguity" design (§4.3). Ship without any UI change yet (the `card` field exists on the wire but nothing renders it) to validate the classifier/resolution logic in isolation before touching UI.
3. **Slice C (SwiftUI cards)** — lowest technical risk (pure UI, reuses established patterns), but is where a design decision needs human sign-off: exact visual weight/placement of a card relative to the prose answer (proposed: above the text, inside the same bordered container — §5.2 — but this is a designer's call, not an architect's).
4. **Slice B.2 (FoundationModels-backed classifier enhancement)** — explicitly a stretch goal behind its own spike gate; only attempt if B.1's heuristic classifier proves too narrow in practice (e.g. real usage shows a lot of near-miss phrasing the regex can't catch). Do not build this speculatively.

**What stays out of scope / a future Rust-sidecar concern:** none — this entire plan is 100% Swift-side, no engine-protocol/sidecar involvement at all, since the whole Recall stack is already fully ported.

## 11. Decisions closed (2026-07-23) and what remains open

**Closed:**
1. **Slice A trigger point** — index once, triggered only by summary generation (not transcript save, not a separate import hook) — §3.1.
2. **Slice A delete-time purge** — delete actively purges the index (`purgeOnDelete`), not just query-time filtering — §3.1.1.
3. **Slice B provider scope** — `.mlx` (primary) and `.claudeCLI` only; the other 7 providers are out of scope for this plan — §4.1. Since neither in-scope provider has trustworthy native tool-calling, the deterministic-classifier design (§4.1) is the only viable approach, not just the recommended one.

**Still open:**
1. **Card visual placement** (§5.2, Slice C) — above vs. below the prose answer, and whether it should also appear as a distinct chat-log item (like `.thinking`) rather than nested inside the assistant bubble. This needs a designer/product call, not an architecture call.
2. **Slice B.2's FoundationModels-backed classifier** — out of scope per the narrowed provider list (§4.1); not applicable unless `.appleFoundation` is added to scope later.

---

Sources: [Foundation Models On-Device LLM: The Tool Protocol](https://blakecrosley.com/blog/foundation-models-on-device-llm), [Swift Foundation Models: Tools with Context](https://medium.com/@itsuki.enjoy/swift-foundation-models-a-little-better-tools-with-context-ff24f456f115)
