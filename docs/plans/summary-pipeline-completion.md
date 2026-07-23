# Summary Pipeline Completion — three post/around-summary gaps

**Status:** plan-only (swift-architect). **Phase:** Swift migration, Phase 4 (unification / context assembly). **Not** a re-plan of summary generation (fixed in `0d0642b`/`7e4de3a`).

These three stages shipped in the frozen Rust app (F2 reconciliation, F6 calendar-aware template select, F9 series ledger) and were dropped/never-ported in the Swift migration. The engines for two of them already exist and are unit-tested in `AriKit`; the third (ledger synthesis) is store-only and needs a new engine. All three attach to one choke point: `SummaryRunner.generate` / `suggestTemplateID` and the post-summary tail of `MeetingProcessingCoordinator.proceedToTemplateAndSummary`.

## Frozen-app ground truth (what we are matching)

- Interactive + background summary both fed the template classifier a calendar/context string and, **after a successful summary**, fired two fire-and-forget, non-blocking calls: reconcile facts, then the per-meeting ledger reduce.
  - `frontend/src/lib/summary/summaryOrchestrator.ts:137-141` (suggestTemplate with context), `:179` (`triggerFactExtraction`), `:182` (`series_update_ledger`).
  - `frontend/src/hooks/meeting-details/useSummaryGeneration.ts:300-306`, `:383-386` (same two, interactive path).
  - `frontend/src/lib/summary/summaryCore.ts:79-89` — `triggerFactExtraction` = fire-and-forget `person_reconcile_facts_for_meeting`.
- **Reconcile is the post-summary trigger**, superseding plain extraction: `ari-engine/src/persons/reconciliation.rs:80` (`reconcile_facts_for_meeting`), never returns `Err`, honest-empty with no participants (`reconciliation.rs:77-90`).
- **Ledger reduce** folds the just-finished **summary markdown** (not facts): `ari-engine/src/meeting_series/ledger.rs:41` (`rebuild_ledger_for_meeting`), reduce prompt `ledger.rs:345-415`, `@mref` qualify/validate `ledger_citations.rs:54,76`. Fired per-meeting via `series_update_ledger` (`meeting_series/commands.rs:288`).
- **Template calendar context**: `ari-engine/src/summary/template_selector.rs:53,66` injects `- Calendar event context: <ctx>`. The Rust/React app actually passed the **whole person-context prefix** as that arg (`useSummaryGeneration.ts:633`, `summaryOrchestrator.ts:140`) — see Gap 1 open decision.

**Important ordering finding:** in the frozen app reconcile and ledger were fired **concurrently** (two independent fire-and-forget calls), and the ledger reduce reads only the **persisted summary markdown**, never the reconciled facts. So **Gap 2 and Gap 3 are mutually independent**; both depend only on the summary being persisted (which `generateSummaryOperation` guarantees before the hook runs). The task's "ledger may want fresh facts" is *not* the Rust contract — state the dependency as: ledger depends on the persisted `Summary` only.

---

## Gap 1 — feed a terse calendar context into template auto-select

**Goal:** when no template is pre-selected, give the classifier the linked event's title (+ optional type/description snippet) so call-type (1:1, training, etc.) is signalled beyond the transcript excerpt.

**Hook location(s):**
- `AriKit/Sources/AriViewModels/SummaryRunner.swift:90` — `calendarContext: nil` is the only unwired arg; `TemplateSelector.suggestTemplate` already accepts and injects it (`TemplateSelector.swift:49,114-117`).
- `SummaryRunner.suggestTemplateID(text:speakerCount:)` (`SummaryRunner.swift:74`) needs the `meetingId` in scope to build the string. It is called once, from `SummaryRunner.generate` (`:121`), which has `meetingId`.

**Module & surface (all inside `AriViewModels`, no new type required):**
- Change `suggestTemplateID` signature to `suggestTemplateID(meetingId:text:speakerCount:) async -> String` (still never throws).
- Add a small private helper `SummaryRunner.calendarContextString(for:) async -> String?` that reads `database.calendarEvents.forMeeting(meetingId)` (`CalendarEventRepository.swift:44`), takes `.first`, and builds a **bounded** one-liner: `event.title` + (optional) a truncated `event.notes` snippet. Reuse `SummaryContextAssembler.truncateChars`/`trimmedNonEmpty` (`SummaryContextAssembler.swift:226,240`) for the bound (cap the description at ~200 chars). Returns `nil` when no event links (honest — classifier just sees no calendar signal, exactly as today).
- Thread it: `generate` computes the string once and passes it down; `suggestTemplateID` forwards to `TemplateSelector.suggestTemplate(..., calendarContext:)`.

**Concurrency:** `SummaryRunner` is a `Sendable` struct off the main actor; the helper is a plain `async` repository read. No new isolation, no hot-path involvement (runs only at summary time).

**Persistence:** read-only, through `CalendarEventRepository` (repositories-only, single-DB-owner intact). No schema change.

**Provider/LLM dependency:** none new — reuses the already-resolved classifier client in `suggestTemplateID`.

**Acceptance tests (Swift Testing, `AriViewModelsTests`):**
1. `calendarContextString` returns `nil` when no event is linked; returns a bounded `title …` string when one is; description is truncated at the cap.
2. `suggestTemplateID` forwards a non-nil context into `TemplateSelector` (inject a spy `LLMClient`; assert the user prompt contains `Calendar event context:` — mirrors `template_selector.rs:359` `prompt_includes_speaker_count_and_calendar_context_when_present`).
3. Degradation preserved: with no summary model configured, still returns `TemplateSelector.defaultTemplateID` (existing behavior, `SummaryRunner.swift:75-77`).

**Invariants:** No-Fake-State (context omitted, never fabricated, when no event); classifier never blocks summary (`TemplateSelector` degrade contract preserved).

**LOCKED decision (Gap 1):** terse calendar-only string (title + short description). Rationale: cleaner signal, avoids duplicating the full F3 block (which `generate` already injects into the summary prompt via `SummaryContextAssembler`).

---

## Gap 2 — wire post-summary fact reconciliation

**Goal:** after a summary succeeds, reconcile each linked participant's facts (add/keep/supersede/remove against their current set), best-effort, never failing the summary.

**Hook location(s):**
- `AriKit/Sources/AriViewModels/MeetingProcessingCoordinator.swift:307` — immediately after `phase = .completed` in `proceedToTemplateAndSummary`, before/around the existing `notifySummaryGeneratedOperation` call (`:311`). It must run **only on the success path** (after `generateSummaryOperation` returns without throwing), and must **not** gate reaching `.completed`.
- New injected closure on the coordinator, mirroring the existing optional-operation pattern (`notifySummaryGeneratedOperation`, `:81,98-101`).

**Module & surface:**
- Engine already exists: `PersonReconciliation.reconcileFacts(forMeeting:)` (`AriKit/Sources/AriKit/Engine/Persons/PersonReconciliation.swift:64`) — `Sendable` struct, repositories-only, never throws for the degrade cases (returns `ReconciliationResult`). No new engine.
- Add coordinator typealias + stored optional op:
  `public typealias ReconcileFactsOperation = @Sendable (_ meetingId: MeetingID) async -> Void` and `private let reconcileFactsOperation: ReconcileFactsOperation?`, defaulted `nil` (tests / no-op safe). Init param appended like `notifySummaryGenerated`.
- Call it inside a **detached, non-awaited** best-effort wrapper after `.completed` so a slow LLM reconcile never delays the UI terminal state — matches the frozen fire-and-forget shape and the decision-3 "diarization failure is non-blocking" pattern already in this file (`:263-269`). Log via `os.Logger(subsystem: "com.arivo.ari.AriViewModels", category: "summary.reconcile")` (the pattern added today, `SummaryRunner.swift:27`). Swallow every error into the log; the closure returns `Void` so `ReconciliationResult.message` is only logged, never surfaced as failure.

**Wiring in `AppEnvironment`:** in `bootstrap()` where the coordinator is built (`Ari/App/AppEnvironment.swift:243-277`), add:
```
reconcileFacts: { mid in
    let result = try? await PersonReconciliation(
        db: db, settings: settingsReader, secrets: summarySecrets, clientFactory: clientFactory
    ).reconcileFacts(forMeeting: mid)
    // log result?.message
}
```
Capture only Sendable locals (`db`, `settingsReader`, `summarySecrets`, `clientFactory`) — never `self`, per the existing `:238-242` discipline.

**Concurrency:** `PersonReconciliation` is `Sendable`, runs entirely off `@MainActor`. The coordinator kicks it as an unstructured `Task` after reaching `.completed` (so completion never awaits it). Strict-concurrency clean: closure captures are all `Sendable` value types/actors; no `@unchecked`/`nonisolated(unsafe)`.

**Provider/LLM dependency:** the **summary model** — `settings.summaryModelConfig()` + `ProviderConfigResolution.resolve(...)` + the MLX-aware `clientFactory` (`PersonReconciliation.swift:79-93,148-153`), identical resolution to `SummaryService`/`SummaryRunner`. **LOCKED:** same summary-model config (no separate setting).

**Persistence:** all writes go through `db.profileFacts` (`upsert`/`recordSource`/`markSupersedes`/`trimActiveToCap`/…) — repositories-only, one DB owner. No schema change (F2 tables already ported).

**Acceptance tests (Swift Testing):**
- Engine-level suites likely already exist for `PersonReconciliation`; this gap adds **coordinator-integration** tests in `AriViewModelsTests`:
  1. After a successful `generateSummary`, `reconcileFactsOperation` is invoked exactly once with the active meeting id.
  2. A **throwing/hanging** reconcile op does **not** change the terminal phase — coordinator still reaches `.completed` and still fires `notifySummaryGenerated` (best-effort/non-blocking bar).
  3. Reconcile is **not** invoked when the summary path is skipped (`summaryAutomatic == false` → `.completed` via the early return `:286-291`).
  4. On cancel/failure paths (`.idle`/`.failed`) reconcile is **not** invoked.
- Invariant suites (dual-run bar vs frozen Rust `reconciliation.rs` tests): fact provenance carried on every add/supersede; supersession is deferred (old fact stays active); a `fact_id` not owned by the resolved person is refused; honest-empty with no participants.

**Invariants:** No-Fake-State (evidence-bearing ops only, `PersonReconciliation.swift:193-198`); consent/enroll gate unaffected (adds land `.pending`); never fails the summary.

---

## Gap 3 — port + wire series-ledger writeback

**Goal:** after a summary succeeds for a meeting in a series, fold that summary into the running ledger via one bounded LLM reduce, with `@mref` cross-meeting citations, best-effort, No-Fake-State. Read side already renders it (`SeriesDetailView`); only the writer is missing.

**New module (net-new Swift engine, in `AriKit/Sources/AriKit/Engine/MeetingSeries/`):**
- `LedgerCitations` — pure, no I/O, direct port of `ledger_citations.rs`:
  - `static func qualifyRefs(_ markdown: String, memberIndex: Int) -> String` (← `qualify_refs`, `:54`) — rewrite `@ref(TS)` and legacy `[TS]` → `@mref(m<N>@TS)`.
  - `static func validateQualifiedRefs(_ markdown: String, memberCount: Int) -> String` (← `validate_qualified_refs`, `:76`) — drop out-of-range `@mref` to plain time text.
  - Port the three regexes (`TS_BODY`, `@ref`, `[..]`, `@mref`) verbatim (`ledger_citations.rs:32-46`). Swift `NSRegularExpression` or `Regex` literals; `Sendable` `enum`.
- `SeriesLedgerSynthesizer: Sendable` (← `ledger.rs`):
  - `public func updateLedger(forMeeting meetingId: MeetingID) async -> LedgerUpdateResult` — never throws; honest-empty when not in a series / no finished summary / empty reduce (`ledger.rs:47-70,120-127`).
  - Steps: resolve series via `db.series.seriesIds(forMeeting:)` (`SeriesRepository.swift:206`) → member index + count via `db.series.meetingIds(inSeries:)` (`:192`) → load `db.summaries.forMeeting(meetingId)?.bodyMarkdown` (`SummaryRepository.swift:28`) → `qualifyRefs` on it → load current ledger via `db.series.find(seriesId)?.ledgerMarkdown` → meeting title/date via `db.meetings.find` → `reduceLedger` (one LLM call) → `validateQualifiedRefs` → persist via `db.series.updateLedger(...)` (`SeriesRepository.swift:124`).
  - Port the reduce prompt (four fixed sections, merge-not-append, 500-word cap, "preserve `@mref` verbatim", `_None yet._`) from `ledger.rs:345-415`.
  - Same provider resolution as reconcile (summary model via `ProviderConfigResolution` + `clientFactory`), matching `run_reduce` (`ledger.rs:420-495`).
  - Public `LedgerUpdateResult { updated: Bool, message: String }` for logging/tests.

**Hook location(s):** same tail as Gap 2 — `MeetingProcessingCoordinator.proceedToTemplateAndSummary` after `.completed` (`:307`). Add a second optional op `UpdateSeriesLedgerOperation = @Sendable (MeetingID) async -> Void`, fired **independently** of reconcile (both fire-and-forget). Wire in `AppEnvironment.bootstrap()` alongside reconcile, capturing only Sendable locals.

**Concurrency:** `SeriesLedgerSynthesizer` is `Sendable`, off main actor; fired as its own detached `Task` after `.completed`. Independent of Gap 2's reconcile task (no ordering constraint — see ground-truth finding). Strict-concurrency clean.

**Persistence:** reads `series`/`seriesMember`/`summary`/`meeting` and writes exactly one `seriesLedger` row via `SeriesRepository.updateLedger` — repositories-only, one DB owner, no schema change (`seriesLedger` already exists). No-Fake-State at the store boundary preserved (`updateLedger` writes markdown only when synthesis produced real content; on empty reduce we **skip the write**, never blank a prior ledger — `ledger.rs:120-127`).

**Provider/LLM dependency:** summary model, resolved exactly as Gap 2. **LOCKED:** same single summary-model config (no separate ledger model setting).

**⚠️ Load-bearing member-index invariant (LOCKED decision):** the `@mref` `m<N>` index must resolve against the SAME ordered member list the read side renders. Read side: `SeriesDetailViewModel.memberMeetings` = `database.series.meetingIds(inSeries:)` order (**membership `createdAt`**, `SeriesRepository.swift:196`), and it **drops** members whose `meetings.find` returns nil (`SeriesDetailViewModel.swift:35-42`) — which would shift indices. Rust instead used `list_members` in **occurrence_time** order and consumed an index slot even for skipped members (`ledger.rs:191-196`). These orderings can disagree. **DECISION:** extract one shared **"ordered resolvable members"** helper on `SeriesRepository` used by BOTH the synthesizer and `SeriesDetailViewModel`, so `m<N>` always resolves to the same meeting both sides see. The index-parity acceptance test pins this.

**Acceptance tests (Swift Testing):**
- `LedgerCitationsTests` — port all of `ledger_citations.rs` tests verbatim (`:95-164`): qualify single/multiple/legacy-bracket, passthrough, no-match on plain numbers/dates, validate keeps-in-range / drops-out-of-range / drops-zero-index / passthrough / roundtrip. Ported never-invents-citations invariant suite.
- `SeriesLedgerSynthesizerTests`:
  1. Meeting not in a series → `updated == false`, ledger untouched.
  2. In series, no finished summary → `updated == false`, existing ledger not blanked.
  3. Reduce returns empty → prior ledger preserved (No-Fake-State).
  4. Happy path with a spy `LLMClient`: `@ref` in the source summary is qualified to the meeting's correct `m<N>` before the reduce prompt; an out-of-range `@mref` in the model output is degraded on write.
  5. **Index parity test:** synthesized `m<N>` resolves to the same meeting `SeriesDetailViewModel.memberMeetings[N-1]` returns (guards the ordering invariant).
- Coordinator-integration (in `AriViewModelsTests`): ledger op invoked once after a successful summary; a throwing/hanging ledger op leaves phase at `.completed`; not invoked when auto-summary is off or on cancel/failure.

**Invariants:** `@mref` never-invents-citations (validate pass), No-Fake-State (never blank an existing ledger), never fails the summary, bounded ledger (word cap by instruction), one DB owner.

---

## Recommended implementation slicing

Three slices. Merge-conflict surface is concentrated in two files that Gaps 2 & 3 both edit: `MeetingProcessingCoordinator.swift` (new typealiases + init params + the post-`.completed` tail) and `AppEnvironment.swift` (the coordinator wiring block, `:243-277`).

- **Slice A — Gap 1 (independent, ship first).** Touches only `SummaryRunner.swift` + `TemplateSelector` call + `AriViewModelsTests`. No coordinator/AppEnvironment edits. Zero conflict with B/C. **One implementer, parallel.**

- **Slice B — Gap 3 engine port (parallelizable, no shared-file edits).** Build `LedgerCitations` + `SeriesLedgerSynthesizer` + their tests entirely as **new files** under `AriKit/.../MeetingSeries/`, PLUS the shared "ordered resolvable members" helper on `SeriesRepository` (and repoint `SeriesDetailViewModel` to it). No edits to the coordinator or AppEnvironment in this slice — deliver the engine + green tests standalone. **Second implementer, parallel with A.**

- **Slice C — coordinator + AppEnvironment wiring for Gaps 2 & 3 (sequential, single owner).** Because both post-summary ops land in the same two files, do the wiring as **one PR** that adds both `reconcileFactsOperation` and `updateSeriesLedgerOperation` typealiases/params, both post-`.completed` fire-and-forget kicks, and both `AppEnvironment` closures together. Depends on Slice B being merged (needs `SeriesLedgerSynthesizer`); Gap 2's engine is already present. **Single owner, after B.**

Sequencing: **A ∥ B** first (independent), then **C** once B lands. Do not split C across two implementers.

---

## Locked decisions

1. **Gap 1 context scope:** terse calendar-only string (title + short description).
2. **Gap 3 member-index ordering:** shared "ordered resolvable members" helper on `SeriesRepository` used by both synthesizer and `SeriesDetailViewModel`.
3. **Model for reconcile + ledger:** the summary model (no new setting).
4. No spike gate applies — this is wiring + one straight port.
