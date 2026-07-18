# AriKit `Models/` — domain value-type port (plan)

> **STATUS: COMPLETE (2026-07-17).** The 10 shared domain value types + support layer (`Identifier<T>`, tolerant enums, RFC3339 date strategy, `LocalAudioReference`) are ported, Swift 6 strict-concurrency clean, `swift test` green. The two follow-ons this plan deferred to the Store port (snake→camel decode adapter; `Series` stored columns) were resolved there (`arikit-store.md`) — the `Series`/`Summary`/`MeetingNote` additions landed with the Store slices.

## 0. Decisions resolved (2026-07-17)

The architect surfaced 5 open decisions; resolved here with defaults so implementation can proceed. Override any of these if you disagree — they set domain-wide patterns.

1. **Typed IDs → YES, phantom `Identifier<Entity>`.** Encodes transparently as a bare String, so persistence/wire/CKRecord are unaffected; prevents mixing the 6+ coexisting `String` ID kinds. Adopted as the domain-wide pattern.
2. **`Summary` domain type → DEFER.** The frozen Rust engine has **no** Summary row (summary lives in `SummaryProcess.result` JSON + Transcript fields); the target `summary` table is a Store-port decision. Porting mirrors what exists — we do **not** fabricate a `Summary` type ahead of the Store defining its columns (No-Fake-State). Removed from the include list; noted as a Store-port delta. `Summary.swift` is **not** created in this pass.
3. **Ambiguous time strings → keep as `String`.** `Transcript.timestamp`, `SeriesMember.occurrenceTime`, `SeriesSummary.lastMeetingTime` — representation unconfirmed (RFC3339 instant vs. display label); typed as `String` until confirmed, rather than mis-typed as `Date`.
4. **Module boundary → accept the recommended split.** Recall types, `Setting`/`TranscriptSetting`, and EventKit `Native*` projections are **excluded** from `Models/` (they belong to Recall / a Config layer / the Calendar capture layer). Matches the scope set for this stream.
5. **`cadence`/`detectedType` stay `String`; `SegmentSource` seed set = `import` (+`unknown`)**, writer-set confirmed during implementation.

Net effect: the include list drops `Summary` (→10 types); everything else as the architect specified below.

---

## 1. Goal & seam

Port the shared **domain value types** — the Swift mirror of the frozen Rust engine's `database/models.rs`, `persons/models.rs`, `meeting_series/models.rs`, `calendar/models.rs` — into `AriKit/Sources/AriKit/Models/`, replacing today's 9-line scaffold (`public enum Models {}`, `Models.swift:9`). These are **pure, persistence-agnostic Swift value types + their invariants as Swift Testing suites** — the foundational brick `Store`, `Recall`, and `Context` build on.

**Seam / phase.** This is net-new Swift work in `AriKit`. In the plan it is the *type substrate* of Phase 3 step 1 ("Store") and Phase 5 ("Fold the Mac engine's models into the shared `AriKit` package", `swift-migration-plan.md:190`), pulled forward as an independent, testable brick because it has no runtime dependencies and gates nothing. It lands entirely on the **target (Swift) side** of the store seam (principle 8, `swift-migration-plan.md:34`).

**Not a frozen-Rust re-implementation.** These are *data definitions*, not behavior. The frozen Rust app keeps its own `models.rs` untouched; this plan adds the Swift domain vocabulary the Swift store/engine will later persist. It does **not** re-implement any shipped Rust *feature* — no extraction, reconciliation, diarization, or recall logic is ported here (those are Engine/Recall work streams).

**Hard scope guard (parallel Rust Stage-B carve).** This plan touches **only** `AriKit/Sources/AriKit/Models/**`, `AriKit/Tests/AriKitTests/**`, and this doc. It touches **no** Rust file, no `Cargo.toml`, no `frontend/**`. Where the Swift domain shape and the Rust source disagree, the plan **documents the delta** (below) — it never edits Rust to reconcile.

## 2. Module & surface

**Persistence is excluded** (task + `swift-conventions.md`): no GRDB/SQLiteData, no `FetchableRecord`/`PersistableRecord`, no migrations, no repositories. These types are the domain *values* the separate `Store/` work stream will later persist. No import of GRDB in this module.

### File layout under `Models/`

```
Models/
├─ Models.swift                     (repurpose scaffold: module doc + `enum Models` namespace
│                                     hosting the shared Codable factory, see §7)
├─ Support/
│  ├─ Identifier.swift              phantom-typed ID (§ decision 4)
│  ├─ UnknownTolerantEnum.swift     shared forward-compat enum pattern (§ decision 2)
│  ├─ ModelsCoding.swift            Models.jsonDecoder/encoder + RFC3339 date strategy (§ decision 3)
│  └─ LocalAudioReference.swift     local-only audio path newtype (§ decision 6)
├─ Meeting.swift                    Meeting  (← MeetingModel)
├─ Transcript.swift                 Transcript segment (← Transcript)
├─ Speaker.swift                    Speaker voiceprint + EnrollmentState
├─ SpeakerSegment.swift             SpeakerSegment + SegmentSource
├─ Person.swift                     Person (tier 1)
├─ ProfileFact.swift               ProfileFact (tier 2) + ProfileFactSource + FactOrigin/
│                                     FactStatus/FactKind/FactSourceRelation + aggregate
├─ Series.swift                     Series (reconciled SeriesSummary⊕SeriesDetail)
└─ CalendarEvent.swift              CalendarEvent + Attendee + CalendarLinkSource
```

(`Summary.swift` deferred per decision 0.2.) Splitting per-entity keeps each file SwiftLint-clean. All types `public`.

### Include / defer list (task item 8)

**INCLUDE (port now as domain value types):**

| Swift type | Rust source | Notes |
|---|---|---|
| `Meeting` | `MeetingModel` (`models.rs:6`) | `audioPath`→`LocalAudioReference?` |
| `Transcript` | `Transcript` (`models.rs:30`) | keep `speakerId`, `audioStartTime`/`audioEndTime`/`duration`; `timestamp` stays `String` |
| `Speaker` | `Speaker` (`models.rs:50`) | `centroid: Data`, `enrollmentState: EnrollmentState`, `totalSpeechSecs` |
| `SpeakerSegment` | `SpeakerSegment` (`models.rs:71`) | `embedding: Data?`, `source: SegmentSource` |
| `Person` | `Person` (`persons/models.rs:8`) | tier 1; `isOwner`, `domain` already present |
| `ProfileFact` | `ProfileFact` (`persons/models.rs:36`) | tier 2 row |
| `ProfileFactSource` | `ProfileFactSource` (`persons/models.rs:58`) | provenance row; `relation` enum |
| `Attendee` | `Attendee` (`calendar/models.rs:17`) | pure value type |
| `CalendarEvent` | `CalendarEvent` (`calendar/models.rs:24`) | `linkSource` enum |
| `Series` | `SeriesSummary`⊕`SeriesDetail` | reconciled to one row-shaped type incl. `ledgerMarkdown`/`ledgerVersion`; `seriesLedger`-split deferred to Store |

**DEFER (view/response DTO, engine-op result, another module's territory, or fabricated-ahead-of-Store):**

- **`Summary`** — no Rust row; Store-port decision (decision 0.2).
- **Response/aggregate DTOs → app/view layer later:** `PersonSummary`, `PersonDetail`, `ProfileFactWithPerson`, the `SeriesSummary` count-view, `SeriesMember`, `SeriesForMeeting`, `CalendarEventDetail`, `LinkedMeeting`, `MeetingCandidate`, `CalendarInfo`. Rationale: they carry computed counts / joins / nav position (`activeFactCount`, `meetingCount`, `position`) — deferring keeps domain types free of stale aggregates (No-Fake-State at the type level).
- **Input DTO → command layer later:** `NewPerson`.
- **Engine-op results → Engine module:** `ExtractionResult`, `ReconciliationResult`.
- **Job/process bookkeeping → Engine:** `SummaryProcess`, `TranscriptChunk` (summarizer cache).
- **Recall's own persistence types → Recall module port:** `RecallChunk`, `RecallIndexState`, `AskConversationRow`, `AskMessageRow`.
- **Config/secrets → a Settings/Keychain layer:** `Setting`, `TranscriptSetting` (API keys must not live in a synced Codable domain type).
- **EventKit projections → Calendar capture layer:** `NativeCalendar`, `NativeEvent`. Their recurrence signals (`seriesKey`, `hasRecurrence`, `occurrenceDate`, `isDetached`) surface on `CalendarEvent`/`Series` when persisted, not as a Native* domain type.

## 3. Concurrency model

- **Every type is a value type (`struct`/`enum`) and `Sendable`.** Composition is `String`, `Int`, `Double`, `Bool`, `Date`, `Data`, nested value types, and the tolerant enums — all `Sendable`, so conformance is synthesized. **No actors**, **no `@unchecked Sendable`**, **no `nonisolated(unsafe)`** — none is justified.
- The module imposes no isolation; immutable data is safe to pass across the audio hot path, STT, and the DB owner without contention. Deliberate: the domain layer never blocks anything.
- Swift 6 language mode + strict concurrency is already pinned (`Package.swift`). A `Sendable`-inventory test (§5) makes conformance a compile-time guarantee.

## 4. Persistence

**None in this module — by scope.** Single-DB-owner (principle 3) honored trivially: `Models/` opens no database, imports no store. Types are shaped so the future `Store/` port is a clean mapping: stable String/UUID identity (typed `Identifier<T>` encoding as bare String), no audio blobs (§6), provenance carried on the type.

**Documented deltas the Store port must reconcile** (target `sqlite-schema/SKILL.md` vs. current Rust): dedicated `summary` table (Rust has none — summary lives in `SummaryProcess.result` JSON + Transcript fields); `seriesLedger` as a separate table (`ledgerMarkdown`/`ledgerVersion` actually live on the `series_ledger` table, NOT the `meeting_series` row — the `Series` domain type carries them from the reconciled IPC surface); `meetingEvent` + `attendee` link tables (Rust embeds `attendees` inline + `meetingId`/`linkSource` on the event). `person.domain` is **already** present in Rust — no delta. **Post-review additions (2026-07-17):** the `Series` domain type omits real stored `meeting_series` columns the IPC DTOs don't expose — `owner_person_id` (→ `ownerPersonId: PersonID?`) and the series' own `created_at`/`updated_at` — which the Store must add; and consider `ledgerVersion: Int?` at the Store (nil = no ledger yet, vs. the wire DTO's ambiguous `0`). The four database-origin types need a **snake→camel decode adapter** at the seam (see §7.7).

## 5. Acceptance tests (Swift Testing, written first)

`import Testing` / `@Test` / `@Suite` / `#expect`, per `swift-conventions.md`. New files under `AriKit/Tests/AriKitTests/`.

1. **`UnknownEnumToleranceTests.swift`** — for each tolerant enum: an unseen raw value decodes to `.unknown("futureValue")` (never throws); re-encoding round-trips the unknown raw losslessly; known values decode to known cases.
2. **`ModelsCodableTests.swift`** — Codable round-trip (`decode(encode(x)) == x`) for every included type, plus **wire-fixture parity**: decode captured real JSON from the frozen Rust engine's IPC output (camelCase) and assert the Swift value matches. Fixtures committed under `Tests/.../Fixtures/`.
3. **`DateDecodingTests.swift`** — RFC3339 strings (with `Z`, with/without fractional seconds) decode to the correct `Date` via `Models.jsonDecoder`; numeric audio times stay `Double` (seconds); malformed dates surface a decode error, not a silent default.
4. **`IdentifierTests.swift`** — `Identifier<Meeting>` encodes/decodes as a bare JSON string (single-value container); is `Hashable`; cross-type assignment is a compile error (documented).
5. **`ProvenanceTests.swift`** — a `ProfileFact` with `origin: .selfReported`, source refs, `observedAt`, `confidence`; a multi-entry `[ProfileFactSource]` with `.origin`+`.reaffirmed`+`.carried`; a two-hop `supersededBy` chain resolved by a chain-walk helper.
6. **`ResultsAudioSplitTests.swift`** — `Meeting.audioReference` decodes from a path String, not bytes; assert (by construction/reflection over Codable keys) there is **no** audio-`Data` field on any domain type. Small model vectors (`Speaker.centroid`, `SpeakerSegment.embedding`) are exempt (vectors, not audio).
7. **`SendableInventoryTests.swift`** — `func requireSendable<T: Sendable>(_: T.Type) {}` invoked for every domain type; non-conformance is a build error.

## 6. Invariants preserved

- **Two-tier identity (F2)** is the type split: authored `Person` (tier 1) distinct from inferred `ProfileFact` (tier 2); never collapsed. (test 5)
- **Provenance / never-invents-citations (data-level analog).** Every inferred `ProfileFact` is traceable — `sourceMeetingId`, `sourceSegmentRef`, `observedAt`, `origin`, `confidence`, plus a `[ProfileFactSource]` lineage. Un-sourced inferred facts are expressible (nullable source) while the corroboration signal survives.
- **No-Fake-State (absolute).** Domain types carry **no** computed/aggregate counts; all view numbers (`activeFactCount`, `meetingCount`, `position`, `total`) are deferred to DTOs. Optionals stay optional (no `nil`→`0` defaulting).
- **Consent-before-record** is an Engine/capture concern; `Meeting` has no auto-record flag and audio is a plain local path reference.
- **Results/audio split (principle 5)** encoded as `LocalAudioReference` + the no-audio-blob shape rule (test 6).

## 7. Design decisions settled

1. **Sendable / value types** — all `struct`/`enum`, all `Sendable`, synthesized; no exceptions.
2. **Tolerant enums (forward-compatible).** Shared pattern in `Support/UnknownTolerantEnum.swift`: raw-`String`-backed enum with `case unknown(String)`, custom `Codable`+`RawRepresentable` so decoding never fails and unknown raws round-trip losslessly. Enums:
   - `EnrollmentState`: `provisional`, `confirmed`, `owner` (+`unknown`).
   - `FactKind`: `goal`, `interest`, `project`, `roleSignal`(`role_signal`), `other` (+`unknown`).
   - `FactStatus`: `pending`, `active`, `superseded`, `rejected` (+`unknown`).
   - `FactOrigin` (Rust `source_kind`; skill's `origin`): `selfReported`(`self_reported`), `attributed` (+`unknown`). Reconciles the `source_kind`→`origin` rename.
   - `FactSourceRelation`: `origin`, `reaffirmed`, `carried` (+`unknown`).
   - `CalendarLinkSource`: `manual`, `calendar` (+`unknown`).
   - `SegmentSource`: seed `import` (+`unknown`) — confirm writer set during implementation.
   - **Stay `String` (no closed set — don't invent cases):** `Series.cadence`, `Series.detectedType`.
3. **Dates → `Date`, canonical.** Real instants (`createdAt`, `updatedAt`, `observedAt`, event `start`/`end`) are `Date` via a shared `Models.jsonDecoder`/`Models.jsonEncoder` with an RFC3339 strategy tolerant of fractional seconds and `Z`. Numeric audio offsets are `Double` seconds (`TimeInterval`). Ambiguous string-timestamps (`Transcript.timestamp`, series time strings) stay `String` (decision 0.3).
4. **Identifiers → phantom-typed.** `struct Identifier<Entity>: RawRepresentable, Codable, Hashable, Sendable { let rawValue: String }` + per-entity `typealias MeetingID = Identifier<Meeting>`. Encodes as a bare String (single-value container). `ExpressibleByStringLiteral` in test builds for ergonomic fixtures.
5. **Two-tier + provenance.** `ProfileFact` is a pure row-mirror; `ProfileFactSource` a separate value; aggregate `ProfileFactWithProvenance { fact; sources: [ProfileFactSource] }` composes them without forcing the Store to denormalize. `supersededBy: ProfileFactID?` models the chain as a pointer.
6. **Results/audio split.** `Meeting.audioReference: LocalAudioReference?` — newtype wrapping a path `String`, documented local-only, never a synced blob. No domain type carries audio bytes; small model vectors stay `Data` (exempt).
7. **Codable strategy — single domain type, camelCase-native; no wire-DTO split (for now).** Swift properties are camelCase. This matches the IPC surface for the persons / calendar / meeting_series structs (they carry `#[serde(rename_all = "camelCase")]`), which therefore decode from real engine JSON directly. ⚠️ **Correction (post-review 2026-07-17):** it does **NOT** hold for the four database-origin types — `Meeting`, `Transcript`, `Speaker`, `SpeakerSegment` have **no `rename_all`** in `database/models.rs`, so the engine's IPC DTOs (`api/api.rs:365-398`) emit **snake_case** (`folder_path`, `audio_start_time`, `speaker_id`, `total_speech_secs`, `cluster_key`, …). The camelCase domain shape is still correct and plan-sanctioned, but decoding raw engine JSON for those four types requires a **snake→camel adapter at the Store/Engine seam** — `Models.jsonDecoder` will not decode their raw wire output. The hand-authored fixtures encode the camelCase *domain* shape (not the snake_case wire) for these four; capturing live engine JSON (test 2) will surface the mismatch and force the adapter. A separate CKRecord/wire mapping likewise belongs to the Store/Engine layer.

## 8. Risks & sequencing

**Parallel-work guard:** all steps edit only `Models/**` and `AriKitTests/**`; the Rust Stage-B carve is untouched. Deltas documented, never applied to Rust.

Ordered, each independently testable:

1. **Support layer** — `Identifier`, `UnknownTolerantEnum`, `ModelsCoding`, `LocalAudioReference` + tests 1, 3, 4.
2. **Enum catalog** — all tolerant enums + `UnknownEnumToleranceTests`.
3. **Core meeting entities** — `Meeting`, `Transcript` + Codable/date/audio-split tests. (No `Summary`.)
4. **Persons two-tier** — `Person`, `ProfileFact`, `ProfileFactSource`, aggregate + `ProvenanceTests`.
5. **Speaker** — `Speaker`, `SpeakerSegment` (blob-`Data`) + Codable tests.
6. **Series + Calendar** — `Series`, `CalendarEvent`, `Attendee` + Codable/fixture tests.
7. **Cross-cutting** — `SendableInventoryTests`, `ResultsAudioSplitTests`, wire-fixture parity across all types.

**Risks:** (a) *fixture drift* — capture real IPC JSON once and commit it (test 2). (b) *target-vs-Rust deltas* (Summary table, seriesLedger split) — documented (§4); flagged so the Store port isn't surprised. (c) *ambiguous string-timestamps* — held as `String` until confirmed.
