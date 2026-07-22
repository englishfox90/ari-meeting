# People View Parity — Native Swift (Phase 2 read/write UI + F2 calendar bridge)

**Status:** IN PROGRESS. **Author:** swift-architect · **Date:** 2026-07-22
**Phase/seam:** Swift migration **Phase 2** (native macOS shell read/write UI) on the landed **Store seam** (GRDB `AppDatabase` + repositories) + a small **Phase-2 F2 calendar-attendee→person bridge** on the already-running `CalendarSyncEngine`. Both land on the **target (Swift) side** of the seam — no Rust is touched.

**Rust incumbent (frozen baseline, read-only reference):** `frontend/src/app/people/page.tsx`, `frontend/src/app/person-details/page.tsx`, `frontend/src/components/MeetingDetails/VoiceprintGlyph.tsx`, `frontend/src/lib/voiceprint-glyph.ts`; `ari-engine/src/persons/import.rs`, `ari-engine/src/database/repositories/person.rs:308-346`, `ari-engine/src/persons/commands.rs:239-324`, `ari-engine/src/diarization/voiceprint.rs:86-115` + `speaker.rs:563-598`.

## Resolved decisions (defaults = frozen-Rust parity)
1. **Manual-fact origin/confidence:** `origin = .attributed`, `confidence = 1.0`, `status = .active` (Rust parity).
2. **Owner "Organization":** treated as the owner `Person`'s `organization` field (no separate app-config in Swift).
3. **Needs-review staleness window:** `staleDays = 28` (the React "over four weeks" bucket).
4. **Multi-line input:** add a small `MarginaliaTextEditor` to the design system if none exists (Slice 4); else reuse `MarginaliaTextField`.

## 1. Goal & scope

Bring the native Swift People feature to functional parity with the frozen Tauri/React app, plus a searchable list (net-new, user-requested). The Swift domain/store layer is complete; the People UI today is a thin read-only shell. Replace both screens with the full owner-card / pending-review / search list and the identity-editing / facts-buckets / voiceprint / provenance detail, and wire the deferred calendar-attendee→person import into the live sync engine.

**In scope.** (1) People list: search + owner card + edit-owner + pending-facts review. (2) Person detail: voiceprint + identity editing + facts buckets + confirm/reject + manual add + provenance + "Linked to N meetings" + meetings list. (3) Calendar attendee→Person auto-import wired into `CalendarSyncEngine`, plus a reverse person→meetings query.

**Out of scope — deferred, do NOT build.** Fact **auto-generation / reconciliation** (needs the summary pipeline, which is unwired). The facts UI works only against **existing** data. Voice enrollment itself (the diarization "Identify speakers" flow, already landed). The source-carry / confidence-raise sub-steps of confirm (wait for Track-H reconciliation wiring).

## 2. Module & surface

Homes follow the landed split: repository methods + pure helpers in **`AriKit`**; `@Observable` view models + geometry/color helpers in **`AriViewModels`** (imports `Observation`, never SwiftUI); SwiftUI views in the **`Ari`** app target.

### 2.1 `AriKit` — new repository methods (thin wrappers over existing primitives)

All `async throws`, value-in/value-out, on the existing `Sendable` repository structs; no new tables, no migration.

**`PersonRepository`:**
- `func meetings(forPerson id: PersonID) async throws -> [Meeting]` — reverse query (closes `PersonDetailViewModel` TODO(S6)). Join `meetingParticipant` → `meeting`, filter non-deleted, order `createdAt` desc.
- `func upsertStubFromAttendee(email: String?, displayName: String, at date: Date = Date()) async throws -> Person` — email-keyed idempotent stub (port of `person.rs:308-346`). In one write txn: if `email != nil` and a non-deleted person with that email exists, return it **unchanged**; else insert stub (`isOwner=false`, optionals nil) with resolved name (`displayName` if non-empty → email local-part → "Unknown"). Needs internal `findByEmail(_:)` (case-insensitive, non-deleted). **Divergence (tested):** email-less attendees additionally deduped by exact `displayName` among already-linked participants of the target meeting, at the call site (§2.6), so re-runs are truly idempotent.
- No `search` method — client-side VM filter (mirrors `SeriesListViewModel.filtered`).

**`ProfileFactRepository`** — single-shot convenience over existing primitives:
- `func confirmFact(_ id:, at date: Date = Date()) async throws` — port of `commands.rs:239-276`: `status = .active`, then `touchConfirmed`. If fact carries `supersedesFactId`, retire the old fact (`.superseded`, `supersededBy = id`). (carry_sources/raise_confidence deferred.)
- `func rejectFact(_ id:) async throws` — `status = .rejected` (never retires a supersede target).
- `func addManualFact(personId:, factText:, factKind:, at date: Date = Date()) async throws -> ProfileFact` — `origin=.attributed`, `confidence=1.0`, `status=.active`, `sourceMeetingId=nil`, `sourceCount=0`.
- `func pendingFactsAll() async throws -> [ProfileFactWithPerson]` — all non-deleted pending facts across persons, paired with person `displayName`. Introduces small public aggregate `ProfileFactWithPerson { fact; personId; personDisplayName }` in `Models/`.
- `func factCounts() async throws -> [PersonID: (pending: Int, active: Int)]` — per-person badge counts, one grouped read.

Reused as-is: `activeFacts(for:)`, `listActiveAndPending(for:)`, `factsNeedingReview(person:, staleDays: 28)`, `withProvenance(_:)` (drives lazy "Seen in N meetings"), `touchConfirmed`, `markSupersedes`.

**`SpeakerRepository`** — canonical-signature accessors (port of `speaker.rs:563-598`):
- `func canonicalEnrolledSpeaker(for personId:) async throws -> Speaker?` — strongest enrolled voiceprint: `personId==id`, `enrollmentState IN (owner,confirmed)`, non-deleted, order owner DESC, `totalSpeechSecs` DESC, `samples` DESC, LIMIT 1.
- `func listCanonicalEnrolled() async throws -> [Speaker]` — one per person for list glyphs (dedupe first-per-person after the ordered read).

### 2.2 `AriKit` — voiceprint signature helper (pure)

New file `AriKit/Sources/AriKit/Engine/Diarization/Voiceprint.swift` (no Swift equivalent exists). Pure, unit-testable:
- `static func downsampleNormalize(_ embedding: [Float], buckets: Int = 32) -> [Float]?` — exact port of `voiceprint.rs:86-115`: bucket-mean then min-max normalize to `[0,1]`; `nil` for empty/degenerate/non-finite. `buckets=32` = `SIGNATURE_BUCKETS`.
- `static func signature(fromCentroid centroid: Data, buckets: Int = 32) -> [Float]?` — composes existing `CentroidCodec.vector(from:)` → `downsampleNormalize`.

### 2.3 `AriViewModels` — voiceprint ring geometry + color (pure, UI-free)

New file `AriViewModels/VoiceprintRing.swift` (ports `voiceprint-glyph.ts`):
- `static func ringRadii(_ values: [Float]) -> [Double]?` — per-bucket normalized radii in [0.46, 0.94], clamped; `nil` when `< 3` values.
- `static func color(_ values: [Float], dark: Bool) -> (hueFrom:, hueTo:, saturation:, lightness:)?` — circular-mean projection; `nil` when `< 3` values. Deterministic.

### 2.4 `AriViewModels` — view models

**`PeopleListViewModel`** (rework). `@MainActor @Observable`. State: `state: LoadState<[Person]>` (one-shot read then `observeAll()`); `searchText`/`filtered` (name/email/role, owner excluded)/`hasNoMatches` (copy `SeriesListViewModel`); `owner: LoadState<Person?>`; `pendingFacts: [ProfileFactWithPerson]` (best-effort); `signatures: [PersonID: [Float]]` (from `listCanonicalEnrolled` → `Voiceprint.signature`); `factCounts`. Actions: `saveOwner`, `confirmPendingFact`, `rejectPendingFact` — repo then refresh affected slices.

**`PersonDetailViewModel`** (rework). `@MainActor @Observable`. Replace empty stub. State: `person: LoadState<Person>`; `participantMeetings: [Meeting]` + derived `meetingCount`; `signature: [Float]?` (nil ⇒ honest no-voiceprint copy); fact buckets from `listActiveAndPending` + `factsNeedingReview(staleDays:28)`: pending / needsReview / active / others. Actions: `saveIdentity` (no-op on empty name; preserve id/isOwner/createdAt), `confirmFact`, `rejectFact`, `reaffirm`(=confirm), `dismiss`(=reject), `addManualFact`, `provenance(for:) -> ProfileFactWithProvenance?` (lazy).

### 2.5 `Ari` app target — SwiftUI views

- `PeopleListView`: off `CardListScaffold` into bespoke screen — header + `MarginaliaSearchField` + owner card + collapsible "Review pending facts" (count badge, flat rows: name link + factText + "From <meeting>" + Reject/Confirm) + people rows (`VoiceprintGlyph` avatar when signature exists, name, subtitle `role ?? email ?? "No details yet"`, "N pending"(accent)+"N facts" badges, chevron via `NavigationLink(value:)`). Edit-owner sheet (Name/Email/Role/Organization/Domain/Notes).
- `PersonDetailView`: header ("Linked to N meetings" + large `VoiceprintGlyph` or honest copy), two-column identity form (left) + facts buckets (right); `FactRow` with kind pill / origin pill / status pill (when not active) / factText / "From <meeting> · Confidence N%" / expandable provenance; "Add a fact manually" (multi-line + kind picker + Add). Feed meetings list real `participantMeetings`.
- `VoiceprintGlyph.swift` (new SwiftUI View): `Path` from `VoiceprintRing.ringRadii` (closed Catmull-Rom → cubic Bézier) painted with `VoiceprintRing.color`; amber only when a clip is actively playing (Signal rule); neutral placeholder dot when `ringRadii == nil`. Provisional voiceprints lighter/dashed.
- Routing unchanged: `RootSplitView.swift:73-74` + `:99-100`.

### 2.6 Calendar attendee→person import (F2 bridge)

Port `ari-engine/src/persons/import.rs` into `CalendarSyncEngine`. Add private `runAttendeeImport(in range:) async throws -> Int` called **after** `runAutoMatch` inside `syncRange` (the link must exist on the DB row first). Steps: read `calendarEvents.events(startingIn:)`, keep `meetingId != nil`; per attendee skip if email+name both empty; `upsertStubFromAttendee`; `addParticipant(meetingId:, personId:, linkSource:"calendar", at:)` (`INSERT OR IGNORE`). Return count; extend `CalendarSyncReport` with `importedParticipants: Int`. Idempotent, safe on the 15-min loop.

## 3. Concurrency
Both VMs `@MainActor @Observable final class`; repo calls `async throws` off-main via `nonisolated` `AppDatabase` accessors. `CalendarSyncEngine` `Sendable struct`; import runs on the existing background sync `Task`. Pure helpers are `enum` static-function namespaces. Swift 6 strict-clean by construction (all crossing types `Sendable` value types). No `@unchecked`/`nonisolated(unsafe)`.

## 4. Persistence
**No schema change, no migration.** All tables exist in `v1_baseline`. `sourceMeetingTitle`/`sourceCount` stay read-time-computed. All access through the repository layer on the one `AppDatabase` (single-DB-owner + repositories-only).

## 5. Acceptance tests (Swift Testing — written first)
Repos (1–8): reverse meetings query; attendee stub idempotency + name resolution; confirmFact (+supersede retire); rejectFact; addManualFact (active); pendingFactsAll; factCounts; canonical-speaker ordering/dedupe. Voiceprint (9–10): downsample port + nil on degenerate; signature determinism. Calendar (11–13): attendee→person+link `linkSource="calendar"`; double-sync idempotency; no-meeting/empty-attendee/authored-identity guards. VMs (14–15): list honest-state/search/owner-exclusion/owner-save/pending actions; detail fact-bucketing/no-voiceprint/identity-save-guard/manual-fact/reverse-meetings/provenance.

## 6. Invariants preserved (as tests)
No-Fake-State (no placeholder ring; honest loading/empty/failed; read-time sourceCount; real reverse-meeting count). Confirm-before-enroll (pending facts need explicit Confirm; manual facts author-active; explicit non-retiring reject). Provenance never fabricated. Idempotent import. Single-DB-owner / repositories-only.

## 7. Slices (tests-first, each shippable)
- **Slice 1 — repository surface (`AriKit`):** the Person/ProfileFact/Speaker methods + `ProfileFactWithPerson`; tests 1–8.
- **Slice 2 — voiceprint helpers:** `Voiceprint` + `VoiceprintRing`; tests 9–10.
- **Slice 3 — People list VM + view:** search, owner card + edit sheet, pending-review, badges/glyphs; test 14.
- **Slice 4 — Person detail VM + view:** reverse-meetings, identity editing, fact buckets, confirm/reject/reaffirm/dismiss, manual add, provenance, voiceprint header; test 15. (May add `MarginaliaTextEditor`.)
- **Slice 5 — calendar attendee→person import:** `upsertStubFromAttendee` + `runAttendeeImport` + `CalendarSyncReport.importedParticipants`; tests 11–13.
