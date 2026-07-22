# AriKit `Engine/` — Summary + LLM provider layer port (plan)

## 0. Status & scope guard

Phase **3.4** ("Summary") of `plans/swift-migration-plan.md:175`: *"llama-helper (llama.cpp) → MLX via `mlx-swift-lm` / FoundationModels (short contexts only); keep cloud providers (URLSession) and the Claude CLI provider (`Process`). Retire the `llama-helper` sidecar when MLX passes S1. Port the SummaryContext assembly, templates, citations verification (`citations.rs`), and persons extraction/reconciliation + series detection engines."*

**Honest framing — this IS a port of frozen features (F3/F6 + the summary spine of F2/F7/F9), not net-new capability.** Principle 8 (`swift-migration-plan.md:45`) forbids *new* capability on the Rust side and mandates ports land on the target Swift side. Summary, providers, templates, persons/series all shipped on Rust and are frozen; Phase 3.4 re-implements them in Swift behind dual-run gates (principles 2/6). "Net-new" here means net-new *on the Swift side* — the same sense Models/Store/Recall were. S1 is **CLOSED → GO** (`swift-migration-plan.md:98,297`): MLX Qwen3.5-4B-4bit is the on-device summary default and `llama-helper` retires at this step. No new spike is opened; this port must *reproduce* the S1 bake-off result.

**WIP-limit / phase check (principle 8).** This is one migration phase (3.4), and it is the **long pole that unblocks recall Slice 8** (`arikit-recall.md §5 Slice 8`, `swift-migration-plan.md:16`). It does not open a second product feature. It coordinates with the (complete) Store and (Slices 1–7 complete) Recall streams — the only cross-stream seam is that the provider protocol must land before recall's Orchestrator slice, and the SummaryService/persons slices need two small additive Store extensions (§4).

**Scope guard.** Implementation touches only `AriKit/Sources/AriKit/Engine/**`, a new `AriKit/Sources/AriKitEngineMLX/**` target (§8), `AriKit/Tests/**`, `AriKit/Package.swift`, this doc, and — as explicit, additive hand-offs — `AriKit/Sources/AriKit/Store/**` (two new repository methods, §4) and `AriKit/Sources/AriKit/Recall/Orchestrator/**` (Slice 8, its own arikit-recall plan owns it; this plan only supplies the `LLMClient` seam). No Rust file, no `Cargo.toml`, no `frontend/**` is edited. Where Swift and Rust disagree, the plan documents the delta; it never edits Rust to reconcile.

**Cross-references:** `plans/swift-migration-plan.md` (Phase 3 step 4; principles 2/3/6/8; S1 result + bake-off table; Decisions), `plans/leverage-apple-models.md` (the apple-helper FoundationModels design this absorbs in-process), `docs/plans/arikit-recall.md` (§2.3/§5 Slice 8 — the `RecallEngine`/streaming/agentic interface this unblocks; §7 invariants), `docs/plans/arikit-store.md` (§2.2 repository pattern, `SummaryRepository`, the missing `meeting_participants` gap).

## 1. Goal & seam

Replace the frozen Rust `ari_engine::summary` + provider clients (`anthropic`/`openai`/`groq`/`ollama`/`openrouter` + `claude_cli` + `apple`) + `persons` + `meeting_series` engines with Swift under `AriKit/Sources/AriKit/Engine/`, replacing today's 9-line scaffold (`Engine/Engine.swift:9`, `public enum Engine {}`).

It attaches to two of the five seams (`architecture.md`): seam #4 **summary prompt assembly** (the `generate_summary` dispatch + SummaryContext) and seam #5 **provider layer** (multi-provider LLM). The central abstraction being ported is `generate_summary` (`ari-engine/src/summary/llm_client.rs:119`) — a single dispatch over an `LLMProvider` enum (`llm_client.rs:66`). This port turns that enum-dispatch into a **protocol** (`LLMClient`), one conformer per backend, so Swift's `any LLMClient` replaces the Rust `match provider`. Everything lands on the **target (Swift) side** of the seam (principle 8).

The proximate purpose: **unblock recall Slice 8** (`arikit-recall.md §5`, `swift-migration-plan.md:16` — "recall is not yet answerable" until this lands). The minimum recall needs is `LLMClient` + one working provider + a single-shot `generate` entrypoint (§5).

## 2. Module & surface

### 2.1 File layout under `Engine/`

```
Engine/
├─ Engine.swift                       (repurpose scaffold → module doc + `enum Engine` namespace)
│
├─ Providers/                         ── SLICES A–E (the LLMProvider port)
│  ├─ LLMClient.swift                 protocol LLMClient + LLMRequest + LLMError + ProviderKind  (SLICE A, pure)
│  ├─ ProviderConfig.swift            resolved config value (kind, model, apiKey, endpoint, params) (SLICE A, pure)
│  ├─ ProviderFactory.swift           make(config:) -> any LLMClient; loopback gate; MLX injection point (SLICE A/B)
│  ├─ StubLLMClient.swift             #if DEBUG test double (deterministic; canned deltas) (SLICE A, pure)
│  ├─ OpenAICompatibleClient.swift    OpenAI/Groq/OpenRouter/Ollama/CustomOpenAI over URLSession + SSE (SLICE B)
│  ├─ AnthropicClient.swift           Claude messages API + SSE (SLICE B)
│  ├─ ClaudeCLIClient.swift           #if os(macOS) Process spawn (SLICE C)
│  └─ FoundationModelsClient.swift    in-process LanguageModelSession, short-ctx floor (SLICE D)
│                                      (MLXClient lives in the separate AriKitEngineMLX target — §8, SLICE E)
├─ Summary/                           ── SLICES F–G
│  ├─ Template.swift                  Template + TemplateSection + validate/markdown  (SLICE F, pure)
│  ├─ TemplateRegistry.swift          all 7 bundled defaults (daily_standup, standard_meeting, one_on_one, project_sync, retrospective, sales_marketing_client_call, team_meeting) + custom loader (SLICE F)
│  ├─ TemplateSelector.swift          F6 auto-suggest (LLM-backed, fallback standard_meeting) (SLICE G)
│  ├─ Chunking.swift                  chunkText, roughTokenCount, cleanLLMMarkdownOutput, extractMeetingName (SLICE F, pure)
│  ├─ SummaryCitations.swift          apply_citations (verify/snap/drop/back-fill) — DISTINCT from recall citations (SLICE F, pure)
│  ├─ LanguageResolution.swift        languageName(fromCode:), final-language action matrix (SLICE F, pure)
│  ├─ SummaryGenerator.swift          generateMeetingSummary (single-pass vs map-reduce) (SLICE F)
│  └─ SummaryService.swift            orchestration: config resolve, token threshold, cache, provenance write (SLICE G)
├─ Persons/                           ── SLICE H (LLM-backed, rides the provider layer)
│  ├─ PersonExtraction.swift          extractFacts(forMeeting:) → StoreProfileFact writes
│  └─ PersonReconciliation.swift      reconcileFacts(forMeeting:) add/keep/supersede/remove + caps
└─ Series/                            ── SLICE I
   ├─ SeriesDetection.swift           calendar-recurrence-keyed series grouping (pure-ish)
   ├─ SeriesLedger.swift              reduce-fold ledger update (LLM-backed) + rebuild
   └─ SeriesLedgerCitations.swift     @mref qualify/validate (deterministic, pure)
```

`SummaryContext` assembly (owner + attendee + call-type block) belongs to the **`Context/`** module per target architecture (`swift-migration-plan.md:57`, `Context/Context.swift:9`). Its two building blocks already exist Swift-side — `Recall.PeopleContext.peopleContextBlock` (`PeopleContext.swift`) and the F3 owner block — so Phase 3.4 reuses them rather than re-porting; the thin `Context.assemble(...)` that composes owner + attendees + template selection is a **coordination point flagged for Phase 4 unification** (§9), not built here. This plan builds the provider + summary spine that Context will feed.

### 2.2 Public Swift surface — Slice A (the provider protocol; pure, portable today)

The single central abstraction. `generate_summary`'s 12-argument free function (`llm_client.rs:119`) collapses into: a `Sendable` request value + a `Sendable` protocol whose conformer already holds its own config.

```swift
/// One LLM backend. `generate` is the single-shot port of `generate_summary`; `stream` is the
/// port of `generate_summary_stream` (llm_stream.rs). Sendable so it crosses actor boundaries
/// freely (the SummaryService, the recall Orchestrator, a background task all hold `any LLMClient`).
public protocol LLMClient: Sendable {
    var kind: ProviderKind { get }
    /// ← generate_summary. Returns the full completion. Cooperative cancellation via Task.
    func generate(_ request: LLMRequest) async throws -> String
    /// ← generate_summary_stream. Yields incremental text deltas, then finishes.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

public extension LLMClient {
    /// Graceful non-streaming fallback (← llm_stream.rs:69-97 for ClaudeCLI/FoundationModels):
    /// run the full generate, emit once. Conformers that CAN stream override this.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let full = try await generate(request)
                    if !full.isEmpty { continuation.yield(full) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct LLMRequest: Sendable {
    public var system: String
    public var user: String
    public var maxTokens: Int?      // ← max_tokens
    public var temperature: Double? // ← temperature (f32)
    public var topP: Double?        // ← top_p
}

public enum ProviderKind: String, Sendable, CaseIterable {
    case openAI, claude, groq, ollama, openRouter, customOpenAI, claudeCLI, appleFoundation, mlx
    // ← LLMProvider (llm_client.rs:66) minus BuiltInAI (llama-helper — RETIRED, replaced by mlx).
    /// Case-insensitive parse (← LLMProvider::from_str, llm_client.rs:84), incl. legacy
    /// "builtin-ai"/"local-llama" now mapping to `.mlx` (the llama-helper successor).
    public static func from(_ s: String) -> ProviderKind?
}

/// Resolved, per-backend config (← the SettingsRepository reads scattered through service.rs).
public struct ProviderConfig: Sendable {
    public var kind: ProviderKind
    public var model: String
    public var apiKey: String            // "" for keyless (Ollama/MLX/ClaudeCLI/Apple)
    public var ollamaEndpoint: String?
    public var customOpenAIEndpoint: String?
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
}

public enum LLMError: Error, Sendable {
    case notConfigured(String)          // missing api key / endpoint / model
    case loopbackViolation              // Ollama endpoint not on this device (§7)
    case requestFailed(String)          // HTTP/transport/parse
    case cancelled                      // ← "Summary generation was cancelled"
    case providerUnavailable(String)    // MLX/FoundationModels not on this device (No-Fake-State)
}
```

**`ProviderFactory.make(config:) throws -> any LLMClient`** replaces the Rust `match provider` block. It (1) validates config, (2) applies the loopback gate for `.ollama` (§7), (3) constructs the conformer. **MLX injection:** because `MLXClient` lives in a separate product that depends on `AriKit` (not vice versa, §8), the factory carries an optional injected constructor `mlxClientProvider: (@Sendable (ProviderConfig) -> any LLMClient)?` that the app (or `AriKitEngineMLX`) registers at launch; unset → `.mlx` throws `.providerUnavailable`. This keeps core `AriKit` compilable and headless-testable without the Metal toolchain.

### 2.3 Per-backend conformers (Rust source → Swift)

| Rust | Swift conformer | Transport | Notes |
|---|---|---|---|
| `LLMProvider::{OpenAI,Groq,OpenRouter,Ollama,CustomOpenAI}` (`llm_client.rs:181-210`) | `OpenAICompatibleClient` | `URLSession` + `URLSession.bytes` SSE | One shape; `baseURL` per kind. Ollama → `{endpoint}/v1/chat/completions`, default `http://localhost:11434`. `messages: [system,user]`. Only CustomOpenAI applies `max_tokens/temperature/top_p` (`llm_client.rs:260`, `llm_stream.rs:171`). |
| `LLMProvider::Claude` (`llm_client.rs:211-226`) | `AnthropicClient` | URLSession + Anthropic SSE | Distinct body: `system` top-level, `messages:[user]`, `max_tokens:2048`, headers `x-api-key`/`anthropic-version: 2023-06-01`. Delta = `content_block_delta.delta.text` (`llm_stream.rs:260`). |
| `LLMProvider::ClaudeCLI` (`claude_cli.rs`) | `ClaudeCLIClient` `#if os(macOS)` | `Process` | `resolve_claude_binary` via login shell + well-known paths (`claude_cli.rs:40`); args `-p <user> --system-prompt <system> --output-format text [--model X]`; neutral cwd (`temp_dir`); 300s timeout; kill-on-terminate. **No streaming** (default-extension fallback). iOS: kind absent from the factory. |
| `LLMProvider::AppleFoundation` (`apple/helper.rs:173`, `leverage-apple-models.md`) | `FoundationModelsClient` (in-process) | `FoundationModels.LanguageModelSession` | **Absorbs the apple-helper sidecar** (`swift-migration-plan.md:255`, "Absorbed in-process"): `system→instructions`, `user→prompt`. Short-context floor only (4k window, `service.rs:464` → threshold 3500). Port `strip_placeholder_timestamps` (`apple/text_cleanup.rs`) on output (No-Fake-State). **No streaming** (fallback). Availability probe gates it honestly. |
| `LLMProvider::BuiltInAI` (llama-helper, `summary_engine/sidecar.rs`) | `MLXClient` (in `AriKitEngineMLX`) | `mlx-swift-lm` `ChatSession` | **The replacement — llama-helper RETIRES** (`swift-migration-plan.md:98,297`). `ChatSession(container, instructions: system, generateParameters:, additionalContext: ["enable_thinking": false])` then `respond(to:user)` / `streamResponse(to:)` (verified `ChatSession` streaming API — see Sources). Qwen3.x gotcha: `enable_thinking:false` (S1 carry-forward). |

Streaming coverage mirrors `llm_stream.rs:6-14` exactly: OpenAI-compatible + Anthropic + MLX are true token streaming; ClaudeCLI + FoundationModels use the graceful single-yield fallback.

### 2.4 Summary surface (Slices F–G)

- `Template` / `TemplateSection` — 1:1 of `templates/types.rs` (`name`, `description`, `sections:[{title,instruction,format,itemFormat?,exampleItemFormat?}]`), `validate()`, `toMarkdownStructure()`, `toSectionInstructions()`.
- `TemplateRegistry` — all seven shipped defaults inlined as Swift string constants (`daily_standup`, `standard_meeting` from `defaults.rs`; plus `one_on_one`, `project_sync`, `retrospective`, `sales_marketing_client_call`, `team_meeting`, which Rust shipped only in the bundled-templates directory, `loader.rs`) + a custom-dir loader. Path resolution stays app-target's job (never hardcode paths).
- `Chunking` — `roughTokenCount` (chars × 0.35, `processor.rs:179`), `chunkText(_:chunkSizeTokens:overlapTokens:)` (char-based, sentence/word-boundary break, `processor.rs:194`), `cleanLLMMarkdownOutput` (strip `<think>` + code fences, `processor.rs:265`), `extractMeetingName` (`processor.rs:294`).
- `SummaryCitations.applyCitations(_ summaryMarkdown:_ sourceTranscript:) -> (String, CitationStats)` — **the distinct port** (see §2.5).
- `SummaryGenerator.generateMeetingSummary(...)` — the conditional single-pass vs map-reduce (`processor.rs:327`): single-pass for cloud/short; map-reduce (chunk → per-chunk summarize → combine → final report) for MLX/Ollama/FoundationModels over threshold. Language normalize/translate passes (`processor.rs:553`). Calls `applyCitations` on the English pass (`processor.rs:534`), panic-guarded (Swift: a non-throwing pure function + a `do/catch`-free guarantee — never fails the summary).
- `SummaryService.processTranscript(...)` — the orchestration (`service.rs:323`): resolve provider/api-key/endpoint/token-threshold, template load, the English-translation cache (`extractCachedEnglishMarkdown`), generate, then persist via `AppDatabase.summaries.upsert` + record provenance (provider/model/template). Cancellation via a `TaskCancellationCoordinator` actor (§3) replacing the Rust `CANCELLATION_REGISTRY`.

### 2.5 The citations distinction — MUST NOT be conflated (a real catch)

There are **two** `citations.rs` in the Rust tree, and only one is ported:
- `recall/citations.rs` (`verify_source_citations`/`parse_timestamp_label`/`filter_ref_timestamps`) — **ALREADY ported** in Recall Slice 1 (`Recall/Citations/Citations.swift`). Reuse it; the orchestrator (Slice 8) already does.
- `summary/citations.rs` (`apply_citations` — verify/snap/drop `@ref` tokens against the real transcript, plus conservative table/bullet **back-fill** with lexical scoring, `SNAP_TOLERANCE_SECS=8`, `BACKFILL_MIN_SCORE=0.5`, `MIN_TOKEN_OVERLAP=3`) — **NOT ported; this plan ports it** (Slice F). It is invoked by the summary pipeline (`processor.rs:535`), not recall. Its `#[cfg(test)]` suite (`citations.rs:406+`, exact/near-miss/drop/back-fill cases over `FIXTURE_TRANSCRIPT`) ports 1:1.

## 3. Concurrency model (Swift 6 strict)

- **Providers are `Sendable` value types / small final classes** holding only immutable config + a shared `URLSession`. `generate` is `async throws`; `stream` returns `AsyncThrowingStream`. All work is off the main actor by construction — the caller (SummaryService / recall Orchestrator) is never `@MainActor`. This is the hot-path guarantee: **STT/audio capture never touch this layer**; summary/persons/series/recall all run post-hoc, off any real-time loop.
- **Cancellation → structured concurrency.** The Rust `CancellationToken` + module-static `CANCELLATION_REGISTRY` (`service.rs:29`) become cooperative `Task.checkCancellation()` in the generation loop + an `actor TaskCancellationCoordinator { meetingId → Task }` for the per-meeting `cancelSummary(meetingId)` command. No `@unchecked Sendable`, no global mutable statics (a strict-concurrency win, same pattern as recall's `ReindexCoordinator`, `arikit-recall.md §3`).
- **Streaming.** `stream` yields on an `AsyncThrowingStream` continuation from a child `Task`; `onTermination` cancels it. The recall Orchestrator (Slice 8) wraps this into `RecallStreamEvent` (`.delta`/`.done`), computing the terminal citation-reconciled answer + separately-built sources on `.done` (`arikit-recall.md §2.3`).
- **URLSession SSE** via `URLSession.bytes(for:)` + `for try await line in bytes.lines`, buffering `data:` lines, parsing JSON, extracting the delta (byte-buffering for split multibyte chars is unnecessary — `bytes.lines` decodes UTF-8 correctly; a documented simplification over the Rust manual byte-buffer, `llm_stream.rs:217`).
- **MLX** (`AriKitEngineMLX`): model load + inference run on MLX's own scheduling; `ChatSession` is used from an `async` context off the main actor. The container is loaded once and cached (an `actor ModelHost` keyed by repo id) — never reloaded per request (S1: warm load ~2.6s, `swift-migration-plan.md:98`).
- **`ClaudeCLIClient`** spawns `Process` on a background task; `#if os(macOS)` only.
- **No `@unchecked Sendable` / `nonisolated(unsafe)`** anywhere in the plan.

## 4. Persistence

The provider layer itself is **stateless** — no schema. The summary/persons/series slices **write through the existing Store repositories only** (principle 3, one owner = `AppDatabase`; the Swift mirror of "repositories-only"):

- **Summary** → `AppDatabase.summaries.upsert(_:)` + `MeetingRepository` provenance columns (`SummaryRepository.swift`, `Summary.swift` — `provider`/`model`/`templateId`). The Rust `summary_processes.result` JSON cache (the English-translation cache, `service.rs:511`) has **no Swift table** — decision §9(2): keep the cache as the `Summary.bodyMarkdown` + a small sidecar field, or drop the translation-cache optimization (it only saves a re-run when switching target language). Recommendation: **drop the JSON-blob cache**; persist the English body + `provider/model/templateId`, recompute translations on demand (simpler; the cache was a Rust-era `summary_processes` artifact the fresh `summary` table doesn't need).
- **Persons** → `AppDatabase.persons` + `profileFacts` (`ProfileFactRepository.upsert`/`recordSource`). **⚠️ Store gap (a real dependency):** the Rust extraction/reconciliation engines read `PersonRepository::list_participants(meeting_id)` from a `meeting_participants` link table (`persons/extraction.rs:67`, `reconciliation.rs`) that **the AriKit Store does not have** (confirmed via `PeopleContext.swift` header — only `owner()/all()/find()` exist, and Recall Slice 7 substituted calendar-attendee matching). Slice H must **add the `meetingParticipant` link table + repository method to the Store** (an additive Store hand-off, §5 Slice H) — this is the biggest new-Store-surface item in the plan.
- **Series** → `AppDatabase.series` (`SeriesRepository` — the 3-table `series`/`seriesLedger`/`seriesMember` shape, `arikit-store.md §4.7`). Ledger upsert + member list already have Store support.

Single-DB-owner reasserted: every write goes through `AppDatabase`'s single writer; no second connection, no raw SQLite handle in Engine code.

## 5. Dependency-ordered slice plan

Each slice is independently testable and lands Swift-side only. **The recall-Slice-8-unblock path is called out explicitly.**

**SLICE A — Provider protocol (START NOW; no dependencies).** `LLMClient`, `LLMRequest`, `ProviderKind` (+ `from(_:)`), `ProviderConfig`, `LLMError`, `ProviderFactory` skeleton (with MLX-injection hook + loopback gate), `StubLLMClient` (`#if DEBUG`, deterministic canned response + deltas). Pure; zero network, zero Store, zero MLX. **Headless `swift test`-able.** → **This alone unblocks recall Slice 8's *compile*** (the Orchestrator can hold `any LLMClient` and be tested against `StubLLMClient`).

**SLICE B — HTTP providers (`OpenAICompatibleClient` + `AnthropicClient`).** `generate` + `stream` (SSE) over URLSession, request-body/SSE-delta parity with `llm_client.rs`/`llm_stream.rs`. Headless-testable via a `URLProtocol` stub (no real network). → **Slice A + B = the minimal recall-Slice-8-unblock**: cloud + Ollama providers give recall a real single-shot + streaming answer path (`arikit-recall.md §5 Slice 8`). Recall can go green end-to-end (against Ollama-loopback or a cloud key) **without MLX, FoundationModels, or the summary pipeline**.

**SLICE C — `ClaudeCLIClient`** (`#if os(macOS)`, `Process`). Testable with an injected launcher / fake `claude` script.

**SLICE D — `FoundationModelsClient`** (in-process `LanguageModelSession`). Absorbs apple-helper summarize + `strip_placeholder_timestamps`. Needs a device with Apple Intelligence; protocol-level tests use the availability-gated path + a fake; real generation is a device-only check. Short-context floor.

**SLICE E — `MLXClient` in `AriKitEngineMLX`** (§8). `ChatSession` load+generate+stream; `enable_thinking:false` for Qwen3.x. **Retires `llama-helper`.** Real-inference tests only under `xcodebuild` + Metal Toolchain; **dual-run against the S1 harness** (§6). This is the highest-risk slice (§8) and is scheduled after A–D so recall + summary are already green on other providers.

**SLICE F — Summary pipeline (pure + provider-driven).** `Template`/`TemplateSection` + registry, `Chunking`, `LanguageResolution`, `SummaryCitations.applyCitations` (the distinct port, §2.5), `SummaryGenerator.generateMeetingSummary`. Ports every `#[cfg(test)]` in `types.rs`/`processor.rs`/`summary/citations.rs` 1:1. Uses `StubLLMClient` for the generation calls in tests — headless.

**SLICE G — `SummaryService` orchestration + `TemplateSelector` (F6).** Config resolution, per-provider token threshold (`service.rs:424-471`), translation-cache decision (§4/§9), Store write + provenance, `TaskCancellationCoordinator`. Needs Store + a Settings reader (§9(1) — the same deferred Settings layer recall flagged).

**SLICE H — Persons extraction + reconciliation.** LLM-backed (rides the provider layer), degrade-gracefully (`created:0` no-ops, never panic, `extraction.rs:53`). **Requires the additive `meetingParticipant` Store table** (§4) + `resolve_person` name/email matching. Reconciliation enforces `MAX_ACTIVE_FACTS_PER_PERSON=12`/`MAX_PENDING=10`/`STALE_AFTER_DAYS=28` (`reconciliation.rs:45`). No-Fake-State: every add/supersede carries `sourceSegmentRef` evidence.

**SLICE I — Series detection + ledger.** `SeriesDetection` (calendar-recurrence-keyed grouping, `detection.rs:22` — needs EventKit-synced `calendarEvent` rows, so it rides Phase-2's calendar). `SeriesLedger` reduce-fold (LLM-backed, `ledger.rs:41`) + `SeriesLedgerCitations` `@mref` qualify/validate (deterministic, pure, `ledger_citations.rs`). Best-effort; never wipes a ledger (No-Fake-State).

**Ordering:** A → B (*recall Slice 8 unblocks here*) → F (summary pure spine) → G (summary service) → C/D/E (remaining providers; E retires llama-helper) → H (persons, + Store table) → I (series). C/D/E can interleave with F/G since they're independent conformers.

## 6. Acceptance tests per slice (written first; dual-run per principle 2)

Under `AriKit/Tests/AriKitTests/Engine/`, Swift Testing (`import Testing`).

**Slice A:** `ProviderKindParseTests` (← `from_str`, `llm_client.rs:84` incl. legacy `builtin-ai`→`.mlx`); `ProviderFactoryTests` (loopback gate rejects non-loopback Ollama → `.loopbackViolation`; `.mlx` with no injected provider → `.providerUnavailable`); `SendableInventoryTests` (every public type `Sendable`); `StubLLMClientTests` (deterministic generate + stream).

**Slice B (dual-run — request-shape parity is the gate):** `OpenAIRequestShapeTests` + `AnthropicRequestShapeTests` — a `URLProtocol` stub captures the outgoing body and asserts byte-shape parity with the Rust builders (OpenAI: `messages:[system,user]`, only CustomOpenAI carries params; Claude: top-level `system`, `messages:[user]`, `max_tokens:2048`, correct headers). `SSEDeltaExtractionTests` — feed canned SSE and assert the accumulated text matches `extract_delta` behavior for both `content_block_delta` and `choices[].delta.content` (← `llm_stream.rs:259`), incl. `[DONE]`/comment/blank-line skipping. `OllamaEndpointTests` (default host + custom).

**Slice C:** `ClaudeCLIArgsTests` (arg vector parity with `claude_cli.rs:130`; `default`/empty model → no `--model`); fake-binary integration test (stdout → answer; nonzero exit → error).

**Slice D:** `FoundationModelsAvailabilityTests` (unavailable → honest `.providerUnavailable`, never fabricated text); `PlaceholderTimestampStripTests` (← `text_cleanup.rs` cases). Real generation: device-gated smoke test.

**Slice E (the S1 dual-run gate):** `MLXClientSmokeTests` under `xcodebuild` — load Qwen3.5-4B-4bit, generate on a fixture prompt, assert non-empty + `enable_thinking:false` (no `<think>` leak). **The gate:** re-run the committed S1 prompt-harness (`tools/prompt-harness/`, 9 meetings) through `MLXClient` and assert **meet-or-beat the Qwen GGUF baseline** on the S1 axes (citation validity ≥96.1%, owner attribution ≥96.4%, name grounding ≥91.3% — `swift-migration-plan.md:104`). S1 already passed as a spike (`spikes/mlx-swift-s1/`); this proves the *product* path reproduces it. **Spike gate = S1 (CLOSED-GO).** If MLX regresses here, `.mlx` stays unavailable and the on-device default falls back to FoundationModels/cloud until fixed — recall + summary are already green on other providers, so nothing else blocks.

**Slice F (ports frozen Rust cases 1:1):** `TemplateTests` (← `types.rs` validate/markdown); `ChunkingTests` (← `processor.rs` — `roughTokenCount`, single-chunk-under-size, multi-chunk-with-overlap, boundary break, empty, `cleanLLMMarkdownOutput` fences/think-tags, `extractMeetingName`); `LanguageResolutionTests` (← `processor.rs` matrix — en/en→ReturnEnglish, en/ja→NormalizeEnglish, fr/ja→Translate, cache-reuse matrix `resolve_cached_english`); `SummaryCitationsTests` (← all `summary/citations.rs` tests — exact-verified, near-miss-snapped, out-of-range-dropped, table/bullet back-fill over `FIXTURE_TRANSCRIPT`); `SummaryGeneratorTests` (with `StubLLMClient`: single-pass vs map-reduce branch selection by provider+threshold; final-report prompt shape; citation pass applied).

**Slice G:** `SummaryServiceTests` (stub provider → Store round-trip: body + provenance persisted; auto-title rename gate `is_automatic_meeting_title`, `service.rs:58`; cancellation mid-run → `.cancelled`, no partial write).

**Slice H:** `PersonExtractionTests` + `PersonReconciliationTests` (stub provider returning canned JSON: add/keep/supersede/remove; degrade cases → `created:0` no-op; active-fact cap backstop; every add carries evidence). Store: `MeetingParticipantSchemaTests`.

**Slice I:** `SeriesDetectionTests` (recurrence-keyed grouping, idempotent); `SeriesLedgerTests` (stub reduce; no-series/no-summary → no-op, never wipes); `SeriesLedgerCitationsTests` (← `ledger_citations.rs` qualify/validate; out-of-range `@mref` degraded to plain text — No-Fake-State).

## 7. Invariants preserved (principle 6)

- **Loopback-only local path.** `ProviderFactory` calls `Recall.isLoopbackOllamaEndpoint` (reusing the ported `LoopbackPolicy.swift`) for `.ollama` and throws `.loopbackViolation` otherwise. **The summary-vs-recall asymmetry, stated precisely:** the *summary* path allows any provider incl. cloud (`service.rs` has no cloud gate); the *recall* path (`shell.rs:297-306`) allows the *same set incl. cloud* — its **only** extra hard gate is the loopback restriction when the provider is Ollama. So the gate is identical in both; recall does not forbid cloud. The provider layer honors the loopback gate uniformly; the recall Orchestrator applies it before building the client (as Rust does, `shell.rs:302`). No local-only path can point at a non-loopback Ollama.
- **Never invents citations.** Two layers: `SummaryCitations.applyCitations` never emits a `@ref` not traceable to a real `[MM:SS]` line (drops/omits when unsure, `citations.rs:19`); the recall `verifySourceCitations` (already ported) drops out-of-range `[S<n>]` and computes sources separately from the answer. Both are pure and panic-free — a citation bug can never fail generation (`processor.rs:534`).
- **No-Fake-State.** FoundationModels/MLX unavailability → honest `.providerUnavailable`, never fabricated output (`apple/helper.rs:14`); persons extraction degrades to `created:0` not invented facts; series ledger never wipes/fabricates (`ledger.rs:12`); placeholder-timestamp strip on the on-device path.
- **Bounded context.** Persons/reconciliation bound transcript to 48k chars (`extraction.rs:28`); ledger word-cap 500 by instruction (`ledger.rs:31`); agentic loop (recall Slice 8) bounds ≤8 iterations / 24 sources / 8k transcript chars (`agent.rs:31`).
- **Consent-before-record** — not an Engine-summary concern (capture); noted for completeness.

## 8. MLX dependency + build/test strategy (THE LOAD-BEARING RISK)

This is the highest-risk item and is designed for head-on.

**Where MLX lives — a SEPARATE SPM target + product `AriKitEngineMLX`** (depends on `AriKit`, not vice versa). MLX must be usable by iOS too (tiered strategy, `swift-migration-plan.md:78`), so it stays in the shared package — but **not in the core `AriKit` target**, for three reasons grounded in `spikes/mlx-swift-s1/Package.resolved`:
1. **Metal build requirement.** S1 carry-forward gotcha (`swift-migration-plan.md:98`): a bare `swift build` produces a binary with **no `.metallib`** ("Failed to load default metallib" at runtime); the ship build **must** use `xcodebuild` with the **Metal Toolchain** component, and the `@main` entry file **must not** be named `main.swift`. If MLX were in the core `AriKit` target, **the entire package's `swift test` would inherit that constraint** — breaking the headless, agent-driven `swift_package_test` path that Store/Recall/Models rely on today.
2. **Transitive weight.** `mlx-swift-lm 3.31.4` pulls ~15 transitive deps (`mlx-swift 0.31.6`, `swift-huggingface`, `swift-transformers`, `swift-jinja`, `swift-nio`, `swift-crypto`, `swift-asn1`, `swift-syntax`, `yyjson`, `EventSource`, …). Loading all of that into every `AriKit` build is pure cost for the 90% of the package that never touches MLX.
3. **Protocol isolation is clean.** `MLXClient` only needs to conform to `LLMClient` (a `public protocol` in `AriKit`). A downstream product conforming to an upstream protocol is idiomatic SPM.

**Concretely in `Package.swift`:** add a second library product + target:
```
.library(name: "AriKitEngineMLX", targets: ["AriKitEngineMLX"]),
...
.target(name: "AriKitEngineMLX",
        dependencies: ["AriKit",
                       .product(name: "MLXLLM", package: "mlx-swift-lm"),
                       .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                       .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                       .product(name: "Tokenizers", package: "swift-transformers")],
        swiftSettings: [.swiftLanguageMode(.v6)])
```
plus `.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4")` (+ swift-transformers/swift-huggingface per the spike). The **core `AriKit` target gains no MLX dependency**, so `swift test AriKit` stays green headlessly.

**How MLX-dependent code gets built and tested:**
- **Core `AriKit` (`swift build`/`swift test`, agent-driven, no Metal):** protocol + all non-MLX providers + summary pipeline + persons/series + recall Orchestrator, tested against `StubLLMClient` and the OpenAI/Anthropic URLProtocol stubs. This is where 100% of the *logic* gets its coverage. **Recall Slice 8 is fully testable here without MLX.**
- **`AriKitEngineMLX` (`xcodebuild test`, macOS target, Metal Toolchain provisioned):** the `MLXClientSmokeTests` + the S1 dual-run (§6). Runs only in the xcodebuild lane (the `/swift-test`'s `xcodebuild test` half, `swift-conventions.md`), never in the bare-SPM lane.
- **App target** links both products and registers `MLXClient` into `ProviderFactory` via the injection hook (§2.2) at launch.

**Consequence for downstream implementers:** they can build/test everything except real MLX inference headlessly; only the S1-gate MLX test needs the xcodebuild+Metal lane. This is stated so no one is blocked waiting on a Metal build to test the provider protocol or the summary spine.

**Open MLX confirmations (flag early):** (a) `ChatSession.streamResponse(to:)` returns an `AsyncThrowingStream<String, Error>` (confirmed via Swift Package Index docs — see Sources) — verify the exact element type at Slice E; (b) whether `mlx-swift-lm 3.31.4` compiles clean under **Swift 6 language mode** (the spike used tools-version 6.1 but did not pin `.v6` strict on the MLX target) — if it emits Sendable warnings we cannot fix (third-party), the `AriKitEngineMLX` target may need `.swiftLanguageMode(.v5)` as a documented exception (isolated to that target, never the core).

## 9. Open decisions for the human

1. **Settings-layer storage** (shared with recall §9(1)). `SummaryService`/`ProviderFactory`/persons/series all need to read the configured provider + model + api-key + Ollama endpoint. `arikit-store.md §9` deferred a Settings layer; recall deferred it too. **This plan needs it resolved** — a `Settings` table + repository vs `UserDefaults` + Keychain (api keys). Recommendation: a small `Settings`/`Secrets` reader interface injected into the factory, backed by Keychain for keys + a settings table for the rest; do not let Engine invent one silently.
2. **Drop the translation-cache JSON blob?** (§4). Rust cached the English summary in `summary_processes.result` to skip pass-1 when re-translating. The fresh `summary` table has no such blob. Recommendation: **drop it** (recompute on demand). Confirm nobody depends on instant language re-switch.
3. **`meetingParticipant` link table** (§4, Slice H). Persons extraction/reconciliation need the participant roster the Store lacks. Confirm adding the additive `meetingParticipant` table + repository to the Store now (vs. substituting calendar-attendee matching as Recall Slice 7 did). Recommendation: add the real link table — persons facts are load-bearing F2 and the calendar substitute is lossy.
4. **`SummaryContext` module ownership** (§2.1). The owner+attendee+call-type assembler is target-arch'd into `Context/`, and its pieces exist Swift-side (`PeopleContext`, F3 owner block). Confirm it's built at **Phase 4 unification** (the F2/F3/F4/F6 convergence, `product.md`) rather than folded into 3.4 — this plan builds only the provider + summary spine it feeds. WIP-limit says one feature; recommend deferring `Context.assemble` to keep 3.4 scoped to the provider/summary port.
5. **MLX Swift-6 mode + streaming element type** (§8 open confirmations) — verify at Slice E; may force a per-target `.v5` exception for `AriKitEngineMLX` only.
6. **Streaming API shape for recall Slice 8** — `AsyncThrowingStream<RecallStreamEvent>` (recommended, `arikit-recall.md §9(4)`); this plan's `LLMClient.stream` returns `AsyncThrowingStream<String, Error>`, which the Orchestrator maps. Confirm the SwiftUI transport is happy with `AsyncSequence` (vs a delegate).

## 10. Risks & sequencing

- **MLX build/test (the long pole)** — mitigated by the separate-product isolation (§8): everything else is headless-green without it, and MLX misses fall back to FoundationModels/cloud (S1 already GO, so this is confirmation not discovery).
- **Recall Slice 8 dependency** — resolved by front-loading Slices A+B; recall unblocks the moment cloud/Ollama providers exist, independent of MLX/summary/persons.
- **Store gaps** — the `meetingParticipant` table (Slice H) and the Settings reader (Slice G) are additive Store hand-offs that must be agreed before those slices open (§9).
- **Citations conflation** — explicitly guarded (§2.5): `summary/citations.rs apply_citations` is a *new* port, not the already-done recall citations.
- **Schema/behavior drift vs. frozen Rust** — low (frozen); re-check if a summary/persons bugfix lands Rust-side during transition.
- **If the S1 gate somehow regresses in the product path** — `.mlx` stays behind the provider protocol as unavailable; the Rust `llama-helper` is *not* resurrected (native-first, `swift-migration-plan.md:140`) — the fallback is FoundationModels (short) / cloud, and MLX is fixed in place. Nothing else in Phase 3.4 blocks on it.

Ordered, each independently testable: **A** (protocol+stub) → **B** (*recall Slice 8 unblocks*) → **F** (summary pure spine) → **G** (summary service) → **C/D/E** (providers; **E retires llama-helper**) → **H** (persons, +Store table) → **I** (series). MLX (E) is gated behind the xcodebuild+Metal lane and the S1 dual-run; everything else is `swift test`-headless.
