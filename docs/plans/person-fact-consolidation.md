# Plan: Person Fact Consolidation (one-time duplicate-fact cleanup)

## 1. Goal & seam

**Goal.** A narrow, on-demand capability that collapses a person's existing near-duplicate
`ProfileFact` rows (accumulated across many meetings, or from the legacy importer) into fewer,
better facts — without any new transcript. This is distinct from
`PersonReconciliation.reconcileFacts(forMeeting:)`
(`AriKit/Sources/AriKit/Engine/Persons/PersonReconciliation.swift:64`), which only ever reconciles
a person's facts *against a new meeting transcript* fired after a summary completes
(`AriKit/Sources/AriViewModels/MeetingProcessingCoordinator.swift:90-140,336-339`). There is no
transcript-free mode today, and the repository has no primitive that merges 3+ old facts into one
new fact (see §3 gap below) — this is genuinely new capability, not a re-implementation of
something the frozen Rust app already ships (`person.rs`'s reconciliation surface has the same
pairwise `mark_supersedes`/`markSupersedes` shape — confirmed via
`AriKit/Sources/AriKit/Store/Repositories/ProfileFactRepository.swift:158-167`).

**Seam.** This is Phase 3.4 Track H (F2 — person profiles), specifically the Store / repository
layer plus the Engine/Persons module, per `.claude/context/architecture.md` seam 2. It lands
entirely in `AriKit` (Swift target, the "target side" of the migration cut — plan principle 8) and
the existing `Ari` app UI layer. No Rust/Tauri code is touched.

**Not a duplicate of a frozen Rust feature.** The Rust incumbent's `reconciliation.rs` has no
transcript-free consolidation mode either (this Swift port already mirrors it 1:1, including the
same absence). This is net-new Swift-only capability that goes beyond the Rust baseline, consistent
with "net-new capability lands in Swift."

## 2. Module & surface

**Module:** `AriKit/Sources/AriKit/Engine/Persons/` (new file `PersonFactConsolidation.swift`,
sibling to `PersonReconciliation.swift` and `PersonExtraction.swift` — same package, same
conventions, reuses `ProviderConfigResolution`/`LLMClient`/`SettingsReading`/`SecretsReading`, no
new provider machinery).

```swift
public struct ConsolidationResult: Sendable, Equatable {
    public let merged: Int       // number of NEW pending facts created by a "merge" op
    public let factsRetired: Int // number of OLD facts pointed at by a merge (sum across ops)
    public let kept: Int         // "keep" ops applied (no-op, informational)
    public let message: String
}

public struct PersonFactConsolidation: Sendable {
    public init(
        db: AppDatabase,
        settings: any SettingsReading,
        secrets: any SecretsReading,
        clientFactory: @escaping @Sendable (ProviderConfig) throws -> any LLMClient = {
            try ProviderFactory.make(config: $0)
        }
    )

    /// One-time (but re-runnable) pass over `personId`'s current active+pending facts: no
    /// transcript, no new content — only reorganizes what's already stored. Same
    /// degrade-gracefully contract as `reconcileFacts`: never throws.
    public func consolidateFacts(for personId: PersonID) async throws -> ConsolidationResult
}
```

`ConsolidationResult` is a new lightweight type rather than reusing `ReconciliationResult` — the
op vocabulary genuinely differs (no `added`/`superseded`/`removed`-with-no-replacement; only
`merged`/`factsRetired`/`kept`), and reusing a same-shaped-but-different-meaning struct would be
more confusing than a small new type. Prefer a value type (it is one); no `@Observable` needed
here — this is domain logic, not view state.

## 3. Concurrency model

- `PersonFactConsolidation` is a plain `Sendable` struct exactly like `PersonReconciliation` and
  `PersonExtraction` — no actor isolation of its own; it's driven from `@MainActor` view-model code
  (the button handler, §6) via `Task { }`, same as `PersonDetailViewModel.confirmFact` does today
  (`PersonDetailViewModel.swift:143-146`).
- All DB access goes through `AppDatabase`'s repositories (`GRDB` `DatabaseWriter`, its own
  internal actor-safety) — no raw SQLite handles, no new actor.
- The LLM call (`client.generate(...)`) is the only genuinely slow step; it already runs off the
  UI thread as an `async` call from a `Task`, mirroring `reconcileFacts`. Nothing here touches the
  audio/STT hot path — this is a person-detail-screen action, never on any pipeline.
- `@unchecked Sendable`: none needed. `ConsolidationResult` and the request/op DTOs are plain value
  types.

## 4. Persistence

### 4.1 The real gap: `supersedesFactId` is single-valued

`ProfileFactRecord.supersedesFactId` (`Store/Records/ProfileFactRecord.swift:39`) is a single
nullable `TEXT` column, and `ProfileFactRepository.markSupersedes(newFactId:oldFactId:)`
(`ProfileFactRepository.swift:162-168`) simply overwrites it:

```swift
guard var record = try ProfileFactRecord.fetchOne(db, key: newFactId.rawValue) else { return }
record.supersedesFactId = oldFactId.rawValue
try record.update(db)
```

Calling this twice for the same `newFactId` with two different `oldFactId`s **loses the first
pointer** (last-write-wins) — a real, silent data-loss trap for exactly the "merge 3-4 old facts
into 1" case the user described. `confirmFact` (`ProfileFactRepository.swift:308-322`) then only
ever retires the single fact named by `supersedesFactId`. **This plan does not use
`markSupersedes` for merges of >1 old fact** — it closes the gap with a small additive schema
change instead of silently overwriting.

### 4.2 New table: `profileFactSupersession` (additive migration)

A many-old-facts-to-one-new-fact join table, added via the next available migration slot (current
head is `v5_vocabulary_term`, so this is `v6_profile_fact_supersession` — confirm the actual head
at implementation time; `v1_baseline` through `v5` stay frozen per
`Store/Migrations/SchemaMigrator.swift:9-17`):

```swift
migrator.registerMigration("v6_profile_fact_supersession") { db in
    try db.create(table: "profileFactSupersession") { t in
        t.column("newFactId", .text).notNull()
            .references("profileFact", onDelete: .cascade)
        t.column("oldFactId", .text).notNull()
            .references("profileFact", onDelete: .cascade)
        t.primaryKey(["newFactId", "oldFactId"])
    }
}
```

Additive only (`CREATE TABLE`), no edit to any frozen migration — per
`docs/plans/robust-migration-and-backup.md` §5 Layer 1 and the `sqlite-schema` skill's
additive-only pattern.

### 4.3 New repository methods on `ProfileFactRepository`

- `recordSupersession(newFactId: ProfileFactID, oldFactIds: [ProfileFactID]) async throws` — inserts
  one row per `oldFactId` into `profileFactSupersession`. Does **not** touch the existing
  single-column `supersedesFactId` path (that stays exactly as `reconcileFacts` uses it today — no
  regression to the pairwise-supersede tests in `PersonReconciliationTests.swift`).
- Extend `confirmFact(_:at:)` (`ProfileFactRepository.swift:308-322`): after the existing
  single-column retirement, **also** look up `profileFactSupersession` rows keyed by the confirmed
  fact's id and retire every named `oldFactId` the same way (`.superseded`,
  `supersededBy = confirmed id`). This is additive/backward-compatible: a fact created by
  `reconcileFacts`'s `supersede` op has no `profileFactSupersession` rows, so the new lookup is a
  no-op for it; a fact created by `consolidateFacts`'s `merge` op has N rows there and 0 in the
  single column, so the existing single-column branch is a no-op for it. Both paths coexist in one
  `confirmFact`.
- `rejectFact(_:)` needs NO change — rejecting a merge candidate should NOT retire the old facts
  (mirrors today's behavior: reject never retires anything, only confirm does).

### 4.4 Single-DB-owner

Unaffected — this is entirely within the existing `AppDatabase`/GRDB repository layer, no second
process, no raw handle.

## 5. Prompt design

Reuses `formatPersonBlock` (`PersonReconciliation.swift:344-357`) verbatim (it's already
`private static` on `PersonReconciliation` — either make it `internal static` and call it from the
new file, or duplicate the ~10-line formatter; **recommend widening its access to `internal`** to
avoid drift between the two prompts, since both need the identical id/kind/confidence/status/age
format the model has already proven reliable at parsing).

**Inputs shown to the model:** ONLY `db.profileFacts.listActiveAndPending(for: personId)` — no
transcript, no meeting content. If fewer than 2 facts exist, there is nothing to consolidate;
return an empty result without calling the LLM (mirrors `reconcileFacts`'s "no participants"
early-return shape).

**New op vocabulary** — deliberately narrower than reconciliation's, because this pass never
invents new information:

- `"merge"` — `fact_ids: [string]` (2 or more existing ids), `fact_text` (the single consolidated
  replacement text), `fact_kind`, `confidence`. Collapses 2+ existing facts into one new pending
  fact.
- `"keep"` — `fact_id: string` (single). The fact is distinct enough to leave alone. Applied as a
  no-op (informational only — `kept` counter), no DB write beyond counting, since there is no new
  evidence to record a reaffirmation against (unlike reconciliation's "keep", which dedup-records a
  transcript-sourced reaffirmation — there is no transcript here).

**No `"add"`** — this pass never fabricates a new fact from nothing; it only reorganizes facts
already in the store (No-Fake-State: consolidation must not become a backdoor extraction path).

**No `"remove"`** — deliberate decision: even an exact-duplicate pair (identical `fact_text`) is
modeled as a `"merge"` of those 2 ids into 1 new fact whose text is that same string. Rationale:
(a) keeps the op vocabulary to 2 cases instead of 3, (b) preserves the human-in-the-loop review —
an outright silent `remove` (as reconciliation's cap-backstop does) is appropriate for *automated
pruning*, but a consolidation the human explicitly triggered should route every disposition through
the same pending-then-confirm gate, so nothing before the human's future confirm click is
irreversible without their say-so, (c) it costs nothing extra: `mergeFacts([a, b]) -> "same text"`
already produces the correct end state (one active fact, once confirmed) via the existing
supersession chain.

**System prompt (paraphrase for the plan; final wording is implementer's, following the exact
tone/strictness of `reconcileFacts`'s system prompt at `PersonReconciliation.swift:110-118`):**

> You are shown ALL of one person's current facts (id/kind/confidence/status/age/text), with NO
> meeting transcript. Identify facts that are near-duplicates or restate overlapping information,
> and propose merging them into fewer, better facts. Output STRICT JSON only — a JSON array, no
> prose, no code fences. Never invent a fact_id not given to you. Never invent new factual content
> not already present across the merged facts' texts — a merge may rephrase for clarity/concision
> but must not introduce a claim absent from every source fact. If nothing overlaps, output `[]`.

**User prompt:** the person's `formatPersonBlock`-formatted current facts, plus the merge/keep op
schema (mirroring `reconcileFacts`'s JSON schema block at `PersonReconciliation.swift:140-145`):

```
{"op": "merge"|"keep", "fact_ids": [string]|null, "fact_id": string|null,
 "fact_text": string|null, "fact_kind": "goal"|"interest"|"project"|"role_signal"|"other"|null,
 "confidence": number|null, "reason": string|null}
```

(`fact_ids` used by `"merge"`, `fact_id` used by `"keep"` — matches reconciliation's precedent of
carrying both shapes in one lenient `Decodable` struct and validating per-op in application code.)

## 6. Application logic (op → DB effect)

For each parsed op:

- **`"merge"`:**
  1. Validate: `fact_ids.count >= 2` (a single-id "merge" is rejected — "that's not a merge");
     every id in `fact_ids` must appear in this person's `listActiveAndPending` set fetched at the
     top of the call (never trust an id the model didn't see, mirrors reconciliation's
     "not owned by this person" refusal at `PersonReconciliation.swift:229-233`); no `fact_id`
     (across ALL ops in this response) may be referenced by more than one `"merge"`/`"keep"` op —
     reject the whole op if a duplicate reference is detected (prevents a fact being merged twice
     or merged-and-kept in the same pass).
  2. `fact_text` must be non-empty (No-Fake-State-adjacent: no empty consolidated fact).
  3. Create ONE new `ProfileFact`: `status: .pending`, `sourceMeetingId: nil`,
     `sourceSegmentRef: "Consolidated from \(fact_ids.count) existing facts"` (an honest,
     non-fabricated evidence string — it does not claim transcript evidence it doesn't have),
     `origin: .attributed` (mirrors both `"add"` and `"supersede"` in `reconcileFacts`, which
     always set `.attributed` regardless of the pre-merge facts' own origins — simplest consistent
     choice; a self-reported origin isn't preserved through a merge since the new text may blend
     multiple facts).
  4. `db.profileFacts.upsert(newFact)`, then
     `db.profileFacts.recordSupersession(newFactId: newFact.id, oldFactIds: fact_ids)` (§4.3 — the
     new N-ary primitive, NOT `markSupersedes` called N times, to avoid the overwrite trap in
     §4.1).
  5. Increment `merged += 1`, `factsRetired += fact_ids.count`.
  6. **No source row** is recorded via `recordSource`/`addSourceDedup` — there is no meeting/segment
     evidence to attach; `sourceCount` for the new fact is honestly `0` until a future meeting
     reaffirms it (read-time-computed per `ProfileFactRepository.swift:406-417` — nothing to fake).

- **`"keep"`:** validate `fact_id` belongs to this person's set; increment `kept += 1`; no DB
  write (no staleness-clock touch, since there is no new evidence — `touchConfirmed` is reserved
  for reconciliation's transcript-backed reaffirmation).

- **Unknown op / malformed fields:** skipped, never guessed (same discipline as `reconcileFacts`'s
  `default: continue`).

**No cap-backstop pass** — this method only ever creates `.pending` facts (never `.active`), and
the merge always **reduces** the active-eligible set once confirmed (N old → 1 new), so it can
only move the person further under the active/pending caps, never over. `trimActiveToCap`/
`trimPendingToCap` are not called here (unlike `reconcileFacts`, which can add active-affecting
`.pending` volume from a live meeting).

## 7. Trigger surface — decision

**Recommendation: (a) manual, on-demand button on `PersonDetailView`, scoped to the currently open
person.** No automatic app-launch backfill.

Rationale:
- The user explicitly asked for a "one-time... cleanup pass" they can run themselves on the one
  person they noticed the problem on — not a recurring background job.
- An automatic backfill-on-launch (option b/c) would fire an LLM call per person with 2+ facts on
  next launch, with no user visibility into when/why it ran, and no way to re-trigger it later if
  the model's first pass under- or over-merged (a manual button is trivially re-runnable; a
  marker-gated one-shot, mirroring `LegacyDatabaseImporter`'s `.legacy-import-complete` pattern
  (`Ari/App/AppEnvironment.swift`), is not, without deleting the marker file).
- A manual button keeps the change fully scoped to one screen (`PersonDetailView.swift`) and one
  new engine file — no new coordinator wiring, no new background-task lifecycle, no new settings
  toggle. This matches the WIP-limited, narrowly-scoped nature of the ask.
- **No new review UI is needed**: a `"merge"` op's new fact lands `.pending`, which
  `PersonDetailViewModel.refreshFacts` (`PersonDetailViewModel.swift:193-207`) already buckets into
  `pendingFacts`, and the existing "Pending confirmation" `factBucket` section
  (`PersonDetailView.swift:207-217`) already renders Confirm/Reject buttons wired to
  `confirmFact`/`rejectFact`. Confirming a merge-created pending fact now retires all its
  `profileFactSupersession`-linked old facts via the `confirmFact` extension in §4.3 — zero new UI.

**Concretely:** add a "Consolidate facts" button near the facts column header in
`PersonDetailView.swift` (alongside the existing manual-fact composer, ~`PersonDetailView.swift:
348` area), calling a new `PersonDetailViewModel.consolidateFacts()` method that constructs
`PersonFactConsolidation` (same DI shape as reconciliation) and calls `consolidateFacts(for:)`,
then `await reloadFacts()` and surfaces `result.message` (e.g. via a transient banner/toast —
follow whatever existing pattern `identityError`/save-feedback in `PersonDetailView.swift:29,125-
139` uses for surfacing a result string; No-Fake-State: show the honest count, including "nothing
to consolidate").

**Open decision for the human:** whether disabling the button when `< 2` facts exist (cheap,
avoids a wasted tap) is worth the extra reactive property on the view model, versus just letting
it return the honest "nothing to consolidate" message on tap. Recommend the latter (simpler,
consistent with the degrade-gracefully philosophy) unless the human wants the affordance hidden.

## 8. Acceptance tests

New file `AriKit/Tests/AriKitTests/Engine/Persons/PersonFactConsolidationTests.swift`, mirroring
`PersonReconciliationTests.swift`'s structure (in-memory `AppDatabase`, `StubSettingsReading`,
`StubSecretsReading`, `StubLLMClient` with a canned response):

**Degrade-gracefully (never throws):**
1. Fewer than 2 existing facts (0 or 1) → all-zero result, no LLM call made (assert via a spy
   client that records call count, or by using a `StubLLMClient` that would throw/return garbage
   if invoked, proving it wasn't).
2. Unconfigured provider → all-zero result.
3. Malformed/unparseable model response → all-zero result.
4. Empty ops array (`[]`) → all-zero result ("nothing to consolidate").

**Happy path:**
5. A `"merge"` op with 3 `fact_ids` → exactly 1 new `.pending` fact created with the given
   `fact_text`; `db.profileFacts.all()` grows by exactly 1; the 3 old facts remain `.active`
   (deferred, unconfirmed) — mirrors `supersedeCreatesDeferredReplacement`'s pattern
   (`PersonReconciliationTests.swift:137-164`); assert 3 rows now exist in
   `profileFactSupersession` for the new fact id (via a small repository test helper or
   `withProvenance`-adjacent read, whichever the implementer wires — a new `ProfileFactRepository`
   test-visible read of `profileFactSupersession` may be needed).
   - **Confirm-then-retire integration:** call `db.profileFacts.confirmFact(newFactId)` and assert
     ALL 3 old facts flip to `.superseded` with `supersededBy == newFactId` (this is the test that
     actually proves the §4.1 gap is closed — the naive `markSupersedes`-called-3× approach would
     fail this by only retiring the last-written old fact).
6. A `"keep"` op → `kept == 1`, no DB mutation, old fact's `status`/`lastConfirmedAt` unchanged.

**Rejections (No-Fake-State discipline):**
7. A `"merge"` whose `fact_ids` includes an id belonging to a DIFFERENT person → the whole op is
   rejected (0 merges applied, no cross-contamination) — mirrors
   `supersedeRefusesUnownedFactId` (`PersonReconciliationTests.swift:166-196`).
8. A `"merge"` with only 1 `fact_id` → rejected ("that's not a merge"), `merged == 0`.
9. Two ops in the same response that both reference the same `fact_id` (e.g. two `"merge"`s
   sharing one id, or a `"merge"` and a `"keep"` on the same id) → the second (or both, per
   implementer's tie-break — plan recommends "first wins, second is rejected" for determinism)
   reference is rejected; assert no fact ends up merged twice / double-counted in
   `factsRetired`.

**No spike gate / eval set (S1–S4) applies** — this reuses the already-GO'd summary-model
provider path (`ProviderConfigResolution`) with a JSON-in/JSON-out prompt of the same shape as the
already-shipped `reconcileFacts`; no new model capability is being bet on.

## 9. Invariants preserved

- **No-Fake-State:** the consolidation pass never invents fact content — `"merge"` only reorganizes
  text already present across the source facts (enforced by prompt instruction; not
  mechanically verifiable, same trust boundary as `reconcileFacts`'s existing "never invent
  facts" instruction). The `sourceSegmentRef` on a merged fact is an honest description of its own
  provenance ("Consolidated from N existing facts"), never a fabricated transcript quote.
  `sourceCount` stays read-time-computed (`ProfileFactRepository.swift:406-417`) — a freshly merged
  fact honestly shows `0` sources until reaffirmed, never a fake carried-over count.
- **Deferred supersession preserved:** exactly like `reconcileFacts`'s `"supersede"`, a merge's old
  facts stay `.active` (in use, visible, not hidden) until a human explicitly confirms the new
  pending fact — nothing is silently retired by the background pass itself.
- **Human-in-the-loop, not automated pruning:** unlike the cap-backstop's `trimActiveToCap`/
  `trimPendingToCap` (which do silently `.removed` facts with no confirm step), every disposition
  from this pass is inert until a human clicks Confirm on the resulting pending fact — matches the
  "one-time cleanup the user reviews" framing, not a background auto-prune.
- **Same provider resolution, no new setting:** reuses `settings.summaryModelConfig()` +
  `ProviderConfigResolution.resolve` exactly as `reconcileFacts`/`extractFacts` do — no new
  provider-selection UI, no new degrade paths beyond what's already proven.
- **Consent-before-record / recall safety shell:** not applicable — this touches no audio, no
  recording, no RAG retrieval.

## 10. Risks & sequencing

Single feature, single phase (Phase 3.4 Track H extension) — no WIP-limit conflict with any other
in-flight migration phase.

Ordered, independently testable steps:

1. **Schema:** add `v6_profile_fact_supersession` migration (§4.2) + its own migration test (per
   the `sqlite-schema`/`grdb` skill pattern — confirm no FK-order issue since `profileFact` is
   already declared before this point in the migrator).
2. **Repository:** add `recordSupersession(newFactId:oldFactIds:)` + extend `confirmFact` (§4.3),
   with unit tests directly against `ProfileFactRepository` (a merge-then-confirm round trip,
   independent of the engine layer above it) — this is the step that most needs to be right before
   anything is built on top of it.
3. **Engine:** `PersonFactConsolidation.swift` + `PersonFactConsolidationTests.swift` (§8) — can be
   built and fully tested headless, no UI needed yet.
4. **UI:** the "Consolidate facts" button + `PersonDetailViewModel.consolidateFacts()` +
   result-message surfacing — last, since it only wires already-tested lower layers.

**Nothing here needs a Rust sidecar** — this is 100% Swift/GRDB, no engine-protocol involvement, no
spike gate to miss.

**Risk called out for the human:** the "first wins, second is rejected" tie-break for a `fact_id`
referenced twice in one model response (§8 test 9) is this plan's own design choice, not observed
in the Rust incumbent (which has no consolidation op set to compare against) — worth a quick nod
from the human that silently dropping the second reference (rather than, say, rejecting the WHOLE
response) is the right failure mode.

## Open decisions for the human

1. Confirm the actual current migration head (`v5_vocabulary_term` at the time this plan was
   written) before assigning `v6_profile_fact_supersession` — another migration may have landed
   since.
2. Whether to disable the "Consolidate facts" button below 2 facts, or just let it return an
   honest "nothing to consolidate" message (plan recommends the latter).
3. Sign-off on the "first wins, second is rejected" tie-break for a `fact_id` double-referenced in
   one model response (§8/§10) — a genuine new design choice with no Rust precedent to defer to.
