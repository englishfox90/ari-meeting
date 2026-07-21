# AriKit `Engine/` — Phase-3.4 extras: MLX (E), Persons (H), Series (I) (plan)

## 0. Status & scope guard

> **PROGRESS (2026-07-20): Track E + Track H LANDED, pushed to `main` `731a2d7`.** Track I (Series)
> remains deferred (Phase-2-blocked). Built as parallel Sonnet-implementer worktrees, Opus-reviewed
> + integrated; combined AriKit suite **506 tests / 76 suites** green, Swift 6 strict.
> - **E (MLX) — LANDED, mechanism-GO (NOT yet full numeric-GO).** `AriKitEngineMLX` product exists
>   (`MLXClient`, `ModelHost`, `MLXRegistration`; `MLXVLM` dropped; `.v5` isolated to this target
>   only). True streaming confirmed (`ChatSession.streamResponse(to:)` yields `String`). The live
>   gate passes on the product path — real Qwen3.5-4B-**MLX**-4bit inference, no `<think>` leak,
>   honest `providerUnavailable` — run via `xcrun xctest` on the xcodebuild-built bundle (bare
>   `swift test` has no metallib; the `.enabled(if:)` env gate does not propagate through
>   `xcodebuild test`, so run the built `.xctest` directly with `ARIKIT_MLX_LIVE_TESTS=1`). ⚠️ The
>   **real repo id is `mlx-community/Qwen3.5-4B-MLX-4bit`** (the `-MLX-` infix) — this doc's prose
>   label "Qwen3.5-4B-4bit" (§1, §1.6) does NOT resolve on HF. **Still open:** the full 3-axis
>   meet-or-beat scoring (citation/owner/name %, §1.6) is not ported to Swift — `MLXS1DualRunTests`
>   is a shape/smoke reproduction; the numeric gate is inherited from the S1 spike. A HIGH review
>   finding (ModelHost async-cache reentrancy → duplicate multi-GB downloads) was fixed by caching
>   the in-flight `Task`, not the value.
> - **H (Persons) — LANDED.** `Engine/Persons/{PersonExtraction,PersonReconciliation,PersonResolve,
>   LabeledTranscript}.swift`; Store hand-offs done (`meetingParticipant` table + repo methods,
>   `FactStatus.removed`, 7 additive `ProfileFactRepository` methods on the still-unshipped
>   `v1_baseline`); the §6-7 shared `ProviderConfigResolution` helper was lifted out of
>   `SummaryService` (behavior-preserving; `SummaryServiceTests` unchanged). Note: real-world value
>   is thin until a participant roster is populated (Phase-2 calendar or manual linking).
> - **I (Series) — NOT STARTED, deferred to post-Phase-2** (§3.1 blocker unchanged).

This plan **extends** `docs/plans/arikit-engine-providers.md` (the Phase-3.4 plan). It does not
re-derive §8 (MLX) or §5 Slices H/I — it consolidates them into three concrete, independently-
gated tracks and fills the gaps the providers plan flagged. Read the providers plan first; where
this doc and that one disagree, this doc is the newer refinement for these three slices only.

**What already landed (verified on disk 2026-07-20):** Slices A–G are committed —
`Engine/Providers/{LLMClient,ProviderConfig,ProviderFactory,StubLLMClient,OpenAICompatibleClient,
AnthropicClient,ClaudeCLIClient,FoundationModelsClient}.swift` and `Engine/Summary/{Template,
TemplateRegistry,TemplateSelector,Chunking,LanguageResolution,SummaryCitations,SummaryGenerator,
SummaryService,SummarySettings,StubSettings,TaskCancellationCoordinator}.swift`, plus (2026-07-20)
**Track E `Engine`-adjacent `AriKitEngineMLX/**`** and **Track H `Engine/Persons/**`** — see the
PROGRESS block above. `Engine/Series/` does **not** exist yet (Track I deferred).

**Honest framing (principle 8, `swift-migration-plan.md:45`).** All three are **ports of frozen
features**, not net-new capability:
- **E (MLX)** = the on-device summary *backend* for F3/F6, replacing the retired `llama-helper`
  (`swift-migration-plan.md:98,297`). The S1 spike is **CLOSED → GO**; this reproduces it in the
  product path — confirmation, not discovery.
- **H (Persons)** = F2 fact extraction + reconciliation (`ari-engine/src/persons/{extraction,
  reconciliation}.rs`).
- **I (Series)** = F9 series detection + ledger (`ari-engine/src/meeting_series/{detection,ledger,
  ledger_citations}.rs`).

Ports land on the **target (Swift) side** of seams #4 (summary prompt assembly) and #5 (provider
layer); no Rust is edited. This is still the single Phase-3.4 stream — it opens no second product
feature. **WIP limit: exactly one of E/H/I is implemented at a time** (§8 sequencing).

**Scope guard.** Implementation touches only `AriKit/Sources/AriKit/Engine/{Persons,Series}/**`,
a new `AriKit/Sources/AriKitEngineMLX/**` target, `AriKit/Tests/**`, `AriKit/Package.swift`, this
doc, and — as explicit additive hand-offs — `AriKit/Sources/AriKit/Store/**` (a new
`meetingParticipant` table + repository, and additive methods on `ProfileFactRepository` /
`SeriesRepository`, §5.2/§5.3). No Rust file, no `Cargo.toml`, no `frontend/**` is edited.

---

## 1. Track E — MLX on-device summary (`AriKitEngineMLX`)

### 1.1 Goal & seam
Provide the on-device summary default by making `.mlx` (the `ProviderKind` case already defined at
`LLMClient.swift:85`, with legacy `builtin-ai`/`local-llama` aliases folding into it at
`LLMClient.swift:100`) a real conformer. The `ProviderFactory` injection hook is **already stubbed
and waiting**: `ProviderFactory.MLXClientProvider` (`ProviderFactory.swift:29`) + the
`case .mlx` branch that throws `.providerUnavailable` when unset (`ProviderFactory.swift:86-92`).
`SummaryService` already treats `.mlx` as keyless (`SummaryService.swift:67-69`) and gives it the
`1748`-token dynamic-context fallback (`SummaryService.swift:238-242`). **This slice adds only the
downstream conformer + its target + the build/test lane** — no core-`AriKit` edit is required to
wire it beyond the app-launch registration.

### 1.2 Module & surface — a SEPARATE SPM product (`Package.swift`)
Per providers §8 (the three reasons: Metal-build requirement, ~15-dep transitive weight, clean
protocol isolation), `MLXClient` lives in a **new product/target `AriKitEngineMLX` that depends on
`AriKit`**, never the reverse. Core `AriKit` gains **no** MLX dependency, so `swift build`/`swift
test AriKit` stays headless and Metal-toolchain-free.

**Concrete dependency set — corrected against the real S1 spike** (`spikes/mlx-swift-s1/
Package.swift`, verified). Providers §8's snippet omitted `swift-huggingface`; the spike's working
`Entry.swift` imports `HuggingFace` + `MLXHuggingFace` and calls the `#hubDownloader()` /
`#huggingFaceTokenizerLoader()` macros + `loadModelContainer(...)` from them (`Entry.swift:16-20,
99-113`). The product set for a **text-only** client is:

```swift
// Package.swift additions
.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
.package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
.package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
...
.library(name: "AriKitEngineMLX", targets: ["AriKitEngineMLX"]),
...
.target(
    name: "AriKitEngineMLX",
    dependencies: [
        "AriKit",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ],
    swiftSettings: [ /* see §1.5 open confirmation — .v6 or a documented .v5 exception */ ]
)
```
`MLXVLM` (used in the spike for the VLM loader) is **dropped** — text-only summary never needs it.
`.macOS("26.0")` is inherited from the package platforms (the spike's `.v14` floor is a spike
artifact; the S1 build ran green on macOS 26.5, per the `macosx26.5` prebuilt module paths under
`spikes/mlx-swift-s1/.build/`).

### 1.3 `MLXClient` surface (in `AriKitEngineMLX`)
```
AriKitEngineMLX/
├─ MLXClient.swift     final class MLXClient: LLMClient  (kind == .mlx)
├─ ModelHost.swift     actor ModelHost — load-once model container cache, keyed by repo id
└─ MLXRegistration.swift  public enum AriKitEngineMLX { static func register(into:) }
```
- `MLXClient` conforms to `LLMClient` (`generate` + true-streaming `stream`, overriding the
  default single-yield extension at `LLMClient.swift:31`). `generate` builds a `ChatSession`
  exactly as the spike proved (`Entry.swift:120-132`):
  `ChatSession(container, instructions: request.system, generateParameters: GenerateParameters(
  maxTokens:temperature:topP:), additionalContext: ["enable_thinking": false])` then
  `try await session.respond(to: request.user)`. The **`enable_thinking: false`** Qwen3.x gotcha
  is a hard S1 carry-forward — omitting it leaks `<think>` blocks.
- `ModelHost` is an `actor` caching the loaded `ModelContainer` per repo id (S1 warm-load ~2.6 s,
  `swift-migration-plan.md:98`) — never reload per request. `generate`/`stream` run off the main
  actor by construction.
- `AriKitEngineMLX.register(into: &ProviderFactory...)` — the app calls this at launch to install
  the `MLXClientProvider` closure into the factory hook (`ProviderFactory.swift:29`). Unregistered
  → `.mlx` honestly throws `.providerUnavailable` (No-Fake-State; already the factory's behavior).

### 1.4 Build/test lane (the load-bearing operational point)
- **Core `AriKit`** (`swift test`, agent-driven, no Metal): unchanged — the whole provider protocol
  + summary pipeline + persons/series stay headlessly green against `StubLLMClient`.
- **`AriKitEngineMLX`** (`xcodebuild test`, Metal Toolchain provisioned): the only place real MLX
  inference is built/tested. A bare `swift build` yields no `.metallib` ("Failed to load default
  metallib" at runtime) and the `@main` file must not be named `main.swift`
  (`swift-migration-plan.md:98`) — both are why this is a separate target off the bare-SPM path.
- **⚠️ Not fully headless-autonomous.** The S1 gate (§1.6) needs a **real Apple-silicon machine +
  a model download** (Qwen3.5-4B-4bit from HF). An agent cannot close this gate in the sandbox; it
  is a human-run or provisioned-runner step. State this to the orchestrator up front.

### 1.5 Open confirmations resolved / carried (providers §8(a)(b))
- **(a) `ChatSession.streamResponse(to:)` element type — STILL OPEN.** The spike used only
  `respond(to:)` (`Entry.swift:132`); it never exercised streaming, so the element type is
  unverified from our own code. Verify against the linked `mlx-swift-lm` 3.31.4 source at Slice E
  start; if `streamResponse` does not yield `String`, `MLXClient.stream` maps it to
  `AsyncThrowingStream<String, Error>` (the protocol contract). Fallback if streaming is awkward:
  ship `generate`-only and inherit the default single-yield `stream` — recall Slice 8 already
  tolerates non-streaming providers.
- **(b) Swift-6 language mode — CARRIED as a decision (§7-open).** The spike compiled under
  tools-version 6.1 **without** `.swiftLanguageMode(.v6)` pinned on the target. If MLX's transitive
  graph emits `Sendable`/isolation warnings we cannot fix (third-party), pin the **`AriKitEngineMLX`
  target only** to `.swiftLanguageMode(.v5)` as a documented, isolated exception — core `AriKit`
  stays `.v6`. This is the sanctioned escape hatch in `swift-conventions.md` ("justify in a
  comment"); it never leaks to the core.

### 1.6 Acceptance tests (the S1 dual-run gate — principle 2)
Under `AriKitEngineMLX` tests, run only in the `xcodebuild` + Metal lane:
- `MLXClientSmokeTests` — load Qwen3.5-4B-4bit, `generate` on a fixture prompt; assert non-empty
  and **no `<think>` leak** (proves `enable_thinking:false` took effect).
- `MLXS1DualRunTests` — re-run the committed S1 harness (`tools/prompt-harness/`, 9 meetings)
  through `MLXClient` and assert **meet-or-beat** the Qwen GGUF baseline on the three S1 axes:
  citation validity **≥ 96.1%**, owner attribution **≥ 96.4%**, name grounding **≥ 91.3%**
  (`arikit-engine-providers.md §6 Slice E`; `swift-migration-plan.md:104`). S1 already passed as a
  spike; this proves the *product* path reproduces it.
- **Gate outcome:** if the product path regresses, `.mlx` stays `.providerUnavailable` and the
  on-device default falls back to FoundationModels (short) / cloud — `llama-helper` is **not**
  resurrected (`swift-migration-plan.md:140`). Recall + summary are already green on other
  providers, so nothing else blocks.

### 1.7 Invariants (providers §7)
No-Fake-State: an unavailable device throws `.providerUnavailable`, never fabricated text. The
model vector/weights are on-device; nothing leaves the machine (loopback-analog for local
inference). MLX is stateless w.r.t. the Store (no schema).

---

## 2. Track H — Persons extraction + reconciliation (`Engine/Persons/`)

### 2.1 Goal & seam
Port `ari-engine/src/persons/{extraction.rs, reconciliation.rs}` — F2 fact extraction and the
richer reconciliation loop that supersedes it. Both ride the **already-landed** `LLMClient` layer
(no new client, exactly as Rust "reuses the SAME LLM provider dispatch", `extraction.rs:26`,
`reconciliation.rs:37`). Attaches at seam #4/#2.

### 2.2 Module & surface
```
Engine/Persons/
├─ PersonExtraction.swift        extractFacts(forMeeting:) → created:Int (LLM-backed)
├─ PersonReconciliation.swift    reconcileFacts(forMeeting:) → ReconciliationResult
├─ PersonResolve.swift           resolvePerson(in:email:name:) (pure, ← resolve_person)
└─ LabeledTranscript.swift       buildLabeledTranscriptText(...) helper (see §2.5)
```
```swift
public struct ExtractionResult: Sendable, Equatable { public let created: Int; public let message: String }
public struct ReconciliationResult: Sendable, Equatable {
    public let added, superseded, kept, removed, capped: Int
    public let message: String
}
public struct PersonExtraction: Sendable {
    public init(db: AppDatabase, settings: any SettingsReading, secrets: any SecretsReading,
                clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient)
    public func extractFacts(forMeeting id: MeetingID) async throws -> ExtractionResult
}
public struct PersonReconciliation: Sendable {
    // same init shape; supersedes PersonExtraction as the post-summary trigger
    public func reconcileFacts(forMeeting id: MeetingID) async throws -> ReconciliationResult
    public func factsNeedingReview(for person: PersonID) async throws -> [ProfileFact]  // ← facts_needing_review
}
public enum PersonReconciliation.Limits {   // ← reconciliation.rs:45-54
    static let maxActiveFactsPerPerson = 12
    static let maxPendingFactsPerPerson = 10
    static let staleAfterDays = 28
}
```
Both reuse the **same** `SettingsReading`/`SecretsReading` seams `SummaryService` already uses
(`SummarySettings.swift`) — the provider/model/key/endpoint resolution is identical to
`extraction.rs:86-138` / `reconciliation.rs:111-163`, so it is refactored into a shared internal
`resolveProviderConfig(...)` (candidate: lift the existing `SummaryService` resolution into a small
internal helper both call — a reviewable de-dup, not new behavior).

### 2.3 Persistence — the `meetingParticipant` Store gap (providers §4, the biggest new surface)
Both engines open with `PersonRepository::list_participants(meeting_id)` (`extraction.rs:67`,
`reconciliation.rs:95`) reading a **participant link table the AriKit Store does not have** —
confirmed: `PersonRepository.swift` exposes only `all/find/owner/upsert/setOwner/softDelete/
observeAll` (no participant roster), and Recall Slice 7 substituted calendar-email matching
(`PeopleContext.swift`). Slice H must add, as an **additive Store hand-off**:

- **`meetingParticipant` table** (extend the unshipped `v1_baseline` per `arikit-store.md §6`
  Slice-1 findings — the baseline is still editable-in-place until first ship): columns
  `meetingId`(FK→meeting CASCADE, indexed), `personId`(FK→person CASCADE, indexed), composite PK
  `(meetingId, personId)`, `linkSource`(TEXT nullable), `createdAt`(DATETIME). Parent-before-child
  ordering already satisfied (`meeting`/`person` precede it).
- **`PersonRepository.participants(inMeeting:) async throws -> [Person]`** and
  `addParticipant(meetingId:personId:linkSource:)` / `removeParticipant(...)`.

`ProfileFactRepository` needs **additive methods** the reconciliation loop calls (none exist today
— the landed repo has only `all/find/activeFacts/withProvenance/supersedeChain/upsert/recordSource/
softDelete/observeAll`):
- `listActiveAndPending(for:)` ← `list_active_and_pending_for_person`
- `markSupersedes(newFactId:oldFactId:)` ← `mark_supersedes` (sets `supersededBy`; **deferred**
  supersession — old fact stays active until user confirm, `reconciliation.rs:355-359`)
- `touchConfirmed(_:)` ← reset staleness clock (`reconciliation.rs:371`)
- `markRemoved(_:)` ← status → removed (`reconciliation.rs:400`)
- `addSourceDedup(...)` ← `add_source_dedup` (idempotent re-run, `reconciliation.rs:381`)
- `trimActiveToCap(person:cap:)` / `trimPendingToCap(person:cap:)` ← the hard backstops
- `factsNeedingReview(person:staleDays:)` ← `facts_needing_review`

**⚠️ Enum delta to resolve (§7-open):** Rust `mark_removed` sets status string `"removed"`, but the
landed `FactStatus` enum (`ProfileFact.swift:68`) has `pending/active/superseded/rejected` +
tolerant `unknown(String)` — no `.removed`. Decide: add a `.removed` case (cleanest; the domain
type is ours) vs. reuse `.rejected`. Extraction/reconciliation always insert `status: "pending"`
(matches `.pending`); only removal hits this.

Single-DB-owner reasserted: every write goes through `AppDatabase` repositories; no raw handle.

### 2.4 Concurrency
Both engines are `Sendable` structs; all work is `async` off the main actor (post-summary, never
the audio/STT hot path). No shared mutable state, no `@unchecked Sendable`. Degrade-gracefully is
structural: every "nothing useful happened" path returns `created: 0` / all-zero
`ReconciliationResult` (never throws) — `throws` is reserved for genuine DB failures
(`extraction.rs:53-55`, `reconciliation.rs:77-79`).

### 2.5 Labeled-transcript helper
Both prefer a speaker-labeled transcript ("Sarah: …") so `resolvePerson` grounds on real names
(`extraction.rs:74-81`), falling back to concatenated text. Rust calls
`diarization::labeling::build_labeled_transcript_text`. The Swift Store has `transcript.speakerId`
(FK→speaker) and `speaker.label`/`personId` (`arikit-store.md §4.2-4.3`), so
`LabeledTranscript.buildLabeledTranscriptText(db:meetingId:)` joins transcript ⊕ speaker ⊕ person
to produce the labeled text; unlabeled fallback concatenates transcript rows (48k-char bound). This
is a small additive helper, not a diarization port.

### 2.6 Acceptance tests (port Rust `#[cfg(test)]` 1:1 + degrade cases)
Under `AriKitTests/Engine/Persons/`, Swift Testing, against `StubLLMClient` returning canned JSON:
- `PersonResolveTests` — email-then-name matching, case-insensitive, no-match → nil (← `resolve_person`).
- `PersonExtractionTests` — canned array → N pending facts each with `sourceSegmentRef` evidence;
  degrade: no participants / empty transcript / unconfigured provider / unparseable JSON / empty
  array → `created: 0` no-op (never throws); every created fact carries a `profileFactSource`
  origin row.
- `PersonReconciliationTests` — add/keep/supersede/remove decision loop; **No-Fake-State asserts**:
  an `add`/`supersede` missing `source_segment_ref` or `fact_text` is skipped, not guessed
  (`reconciliation.rs:274-281,317-324`); a `fact_id` not owned by the resolved person is refused
  (`reconciliation.rs:314,366,397`); deferred supersession leaves the old fact active; cap backstops
  prune past 12 active / 10 pending; unknown op skipped.
- Store: `MeetingParticipantSchemaTests` (introspection) + `MeetingParticipantRoundTripTests`.
- `strip_code_fences` port test (```json fences).

### 2.7 Invariants (providers §7)
No-Fake-State (facts carry evidence or are dropped; degrade → `created:0`, never invented facts);
bounded context (48k-char transcript bound, `extraction.rs:28`); loopback gate inherited from
`ProviderFactory` for `.ollama`; provenance/two-tier identity preserved (F2 — `person` vs
`profileFact` stay distinct, every source recorded).

---

## 3. Track I — Series detection + ledger (`Engine/Series/`)

### 3.1 Goal & seam — and the Phase-2 BLOCKER (state plainly)
Port `ari-engine/src/meeting_series/{detection.rs, ledger.rs, ledger_citations.rs}` — F9. Rides the
landed `LLMClient` (`ledger.rs:478`). Attaches at seam #4/#2.

**⚠️ BLOCKER — the primary detection path is gated on Phase 2.** `detect_series_for_event`
(`detection.rs:22`) keys series off EventKit fields — `event.meeting_id`, `event.has_recurrence`,
`event.series_key` (`calendarItemExternalIdentifier`), `event.occurrence_date`. The Swift Store's
`calendarEvent` table has all these columns (`CalendarEventRepository`, `arikit-store.md §4.8`),
**but the rows are only populated by EventKit sync, which does not move into the Swift shell until
Phase 2** (calendar). Until then there are no synced calendar events to detect against, so the
calendar-keyed path cannot be exercised end-to-end. **Slice I is therefore gated on Phase 2.**

*Nuance (do not build a partial feature):* the **heuristic** path `rescan_heuristic_series`
(`detection.rs:145`, title-normalization grouping) and the whole **ledger** subsystem
(`ledger.rs` + `ledger_citations.rs`) are structurally calendar-*independent* — they need only
series membership + summaries, both of which exist Swift-side. In principle they could land ahead
of Phase 2. **Recommendation: defer all of Slice I until after Phase 2 anyway**, to keep F9
coherent (its primary detection path must be exercisable) and to honor the one-slice WIP limit.
The one exception worth lifting early *if ever needed by another slice* is the pure
`ledger_citations` pass (§3.4) — it has no dependency on anything.

### 3.2 Module & surface
```
Engine/Series/
├─ SeriesDetection.swift       detectSeriesForEvent(...) + rescanHeuristicSeries() + normalizeSeriesTitle (pure)
├─ SeriesLedger.swift          rebuildLedger(forMeeting:) / rebuildLedger(forSeries:) / reduceLedger(...) (LLM-backed)
└─ SeriesLedgerCitations.swift qualifyRefs(_:memberIndex1Based:) + validateQualifiedRefs(_:memberCount:) (pure)
```

### 3.3 Detection (`SeriesDetection`)
- `normalizeSeriesTitle(_:)` — a **pure** port of `detection.rs:123` (lowercase, strip ISO/numeric/
  month-name dates, `#N`/`(N)`/`week N` markers, collapse whitespace, trim separators). The 7
  `NORMALIZE_PATTERNS` regexes (`detection.rs:92-112`) port to `NSRegularExpression`/`Regex` 1:1.
- `detectSeriesForEvent(event:)` — find-or-create series keyed by `seriesKey`, register the linked
  meeting as an `auto` member (conservative v1: only events that BOTH have a series key AND carry
  recurrence, `detection.rs:30-36`). Idempotent.
- `rescanHeuristicSeries()` — group unseriesed meetings by normalized title, create a series per
  2+ cluster.

**Store gaps (additive on `SeriesRepository`)** — the landed repo has `all/find/upsert/updateLedger/
softDelete/observeAll/meetingIds/addMember/removeMember`, but detection needs:
- `findSeries(byKey:)` ← `find_series_by_key`
- `seriesForMeeting(_:)` ← `series_for_meeting`
- `listUnseriesedMeetings()` ← `list_unseriesed_meetings` (heuristic path)
- **member ordering fix:** `meetingIds(inSeries:)` currently orders by `createdAt`
  (`SeriesRepository.swift:143-151`), but the ledger's `@mref` 1-based member index MUST match the
  chronological `list_members` order (`ledger.rs:76-85`, `ledger_citations.rs:14`). Add
  `members(inSeries:) -> [(meetingId, occurrenceTime)]` ordered by `occurrenceTime ASC` (Rust's
  ordering). Getting this wrong silently mis-attributes citations — flag as load-bearing.
`upsert(Series)` already covers insert-with-key/type/cadence/owner; `updateLedger(...)` already
covers the ledger upsert (`SeriesRepository.swift:75-103`). No new tables — the 3-table series
shape exists.

### 3.4 Ledger citations (`SeriesLedgerCitations`) — DISTINCT marker, port 1:1
Pure, no I/O, no LLM. Ports `ledger_citations.rs` exactly. The `@mref(mN@MM:SS)` marker is
deliberately **distinct** from the summary `@ref(MM:SS)` (already ported in `SummaryCitations`,
providers §2.5) and from recall `[S<n>]` citations — none touch each other.
- `qualifyRefs(_:memberIndex1Based:)` — rewrite `@ref(<TS>)` and legacy `[<TS>]` → `@mref(mN@<TS>)`
  before the reduce.
- `validateQualifiedRefs(_:memberCount:)` — after the reduce, drop any `@mref` whose N ∉
  `1...memberCount`, degrading it to plain time text (No-Fake-State — never a dead badge).
- The `TS_BODY` regex is `\d{1,4}:[0-5]\d(?::[0-5]\d)?` (`ledger_citations.rs:32`) — matches
  `SummaryCitations`'s ref-token shape so >59-min markers survive.

### 3.5 Ledger reduce (`SeriesLedger`) — LLM-backed, best-effort
- `rebuildLedger(forMeeting:)` ← `rebuild_ledger_for_meeting` (`ledger.rs:41`): resolve series →
  load finished summary markdown → qualify its refs with this meeting's 1-based member index →
  reduce-fold into current ledger via one bounded LLM call → validate `@mref` → `updateLedger`.
- `rebuildLedger(forSeries:)` ← `rebuild_ledger_for_series` (`ledger.rs:169`): fold every member's
  summary from an empty ledger (skipped members still consume an index — `ledger.rs:191-207`).
- `reduceLedger(...)` — the bounded reduce prompt (`ledger.rs:345`): EXACTLY four sections
  (`## Open action items / ## Decisions / ## Recurring themes / ## Per-person threads`), merge-not-
  append, `_None yet._` for empty, preserve `@mref` verbatim, `LEDGER_WORD_CAP = 500` by
  instruction (never hard-truncated — would corrupt markdown, `ledger.rs:30-31`).
- **Summary source:** Rust reads `summary_processes.result` JSON `markdown` field
  (`ledger.rs:315-339`). The Swift Store dropped that JSON blob (providers §4/§9(2)) — read
  `SummaryRepository.forMeeting(_:).bodyMarkdown` directly instead (a documented improvement:
  typed row, not a JSON parse; missing/empty → skip, never wipe).

### 3.6 Concurrency
All `Sendable` structs, `async`, off the main actor. `SeriesLedgerCitations` is pure/sync. Ledger
reduce is fire-and-forget best-effort (no cancellation token — `ledger.rs:419`); a failed reduce
logs and returns without touching the ledger.

### 3.7 Acceptance tests (port Rust `#[cfg(test)]` 1:1)
Under `AriKitTests/Engine/Series/`:
- `SeriesLedgerCitationsTests` — **all 10** `ledger_citations.rs` tests port verbatim (qualify
  single/multiple/legacy-bracket/passthrough/no-plain-numbers; validate in-range/out-of-range→plain/
  zero-index/passthrough/roundtrip).
- `NormalizeSeriesTitleTests` — **all 7** `detection.rs` tests (recurring dates normalize equal,
  strips ISO/numeric/instance markers, preserves `1:1`, distinct titles stay distinct).
- `SeriesDetectionTests` — find-or-create keyed by seriesKey, idempotent re-run creates nothing;
  heuristic 2+ cluster; member ordering is chronological (guards §3.3 the citation-index fix).
- `SeriesLedgerTests` (stub reduce) — no-series → `Ok(())` no-op; no/empty summary → don't wipe;
  empty reduce output → keep prior ledger (`ledger.rs:120-127`); four-section prompt shape;
  `@mref` validated post-reduce; rebuild-from-series folds in occurrence order.

### 3.8 Invariants (providers §7)
No-Fake-State: never wipes/fabricates a ledger (skip-not-blank on every missing input); out-of-range
`@mref` degraded to plain text. Bounded context (500-word ledger cap by instruction). Loopback gate
inherited via `ProviderFactory`.

---

## 4. Sequencing & WIP (honor: one implemented at a time)

| Track | Status | Blocker | Verification |
|---|---|---|---|
| **E — MLX** | **✅ LANDED (mechanism-GO)** 2026-07-20 | numeric 3-axis gate not yet Swift-ported (inherited from S1 spike) | live inference passed via `xcrun xctest` on xcodebuild bundle |
| **H — Persons** | **✅ LANDED** 2026-07-20 | real-world *value* needs participants populated (calendar = Phase 2, or manual linking) | headless `swift test` against stub — green |
| **I — Series** | **⏳ deferred** | **Phase 2** (EventKit-synced `calendarEvent` rows for the primary detection path) | headless once unblocked |

**Recommended order: E → H → (Phase 2) → I.**
- **E first**: completes the provider layer, retires `llama-helper`, and confirms the already-GO S1
  gate in the product path. Front-loaded because its verification has the most friction (real
  machine) — surface any regression early.
- **Pragmatic WIP swap:** if a Metal machine/runner isn't available to close E's S1 gate, pull **H**
  forward as the active stream instead (it is 100% headless), and close E's gate when hardware is
  available. Do not run E and H implementation concurrently (WIP = one).
- **I last**, after Phase 2 lands calendar sync into the shell.

---

## 5. Store hand-offs (must be agreed before the owning slice opens)

1. **`meetingParticipant` table + `PersonRepository` participant methods** (Slice H, §2.3) — the
   biggest new Store surface. Additive; extends the unshipped `v1_baseline`.
2. **`ProfileFactRepository` additive methods** (Slice H, §2.3) — 7 methods for the reconciliation
   loop; all additive, no schema change beyond the `FactStatus.removed` decision (§6).
3. **`SeriesRepository` additive read methods + member-ordering fix** (Slice I, §3.3) — no new
   tables; the `members(inSeries:)` occurrence-time ordering is load-bearing for `@mref`.

These stay `Store/**` edits owned by the store plan's discipline (repositories-only, single-owner);
this plan only specifies the surface each engine needs.

---

## 6. Open decisions for the human

1. **MLX Swift-6 mode (§1.5b).** Confirm whether `mlx-swift-lm 3.31.4` compiles clean under
   `.swiftLanguageMode(.v6)`; if not, approve an isolated `.v5` exception on the `AriKitEngineMLX`
   target only. (Verified at Slice E start on real hardware.)
2. **MLX streaming element type (§1.5a).** Confirm `ChatSession.streamResponse(to:)`'s type at Slice
   E; approve `generate`-only fallback if streaming is awkward.
3. **MLX S1 gate execution (§1.4).** The gate needs a real Apple-silicon machine + HF model
   download — not sandbox-headless. Decide who/what runs it (human, or a provisioned Metal runner).
4. **`FactStatus.removed` (§2.3).** Add a `.removed` case to the `FactStatus` domain enum vs. reuse
   `.rejected` for Rust's `mark_removed`. Recommendation: **add `.removed`** (the enum is ours; the
   status is semantically distinct from a user rejection).
5. **`meetingParticipant` roster source (§2.3).** Confirm adding the real link table now (vs.
   continuing Recall Slice 7's calendar-email substitute). Recommendation: **add the table** — F2
   facts are load-bearing and the calendar substitute is lossy; but note its *population* (auto-link
   from attendees) is a Phase-2 concern, so H's real output is thin until then (manual linking
   aside).
6. **Slice I timing (§3.1).** Confirm deferring all of Slice I to post-Phase-2 (recommended) rather
   than landing the calendar-independent heuristic+ledger pieces early. Recommendation: **defer** to
   keep F9 coherent and honor WIP.
7. **Shared provider-config resolution (§2.2).** Confirm lifting `SummaryService`'s provider/key/
   endpoint resolution into a shared internal helper that persons/series reuse (a reviewable de-dup,
   no behavior change).

---

## 7. Risks

- **E build/test friction** — mitigated by separate-product isolation (core stays headless-green)
  and the S1-GO fallback chain; the only real risk is hardware access for the gate.
- **Citation mis-attribution in I** — the `members(inSeries:)` ordering fix (§3.3) is load-bearing;
  an ordering bug silently points `@mref` badges at the wrong meeting. Guarded by
  `SeriesDetectionTests` member-ordering assertion.
- **Schema/behavior drift vs. frozen Rust** — low (frozen); re-check if a persons/series bugfix
  lands Rust-side during transition.
- **Persons value without participants** — H builds/tests fine but produces real facts only once a
  participant roster is populated (Phase 2 calendar or manual). Accepted; surfaced in §6(5).
