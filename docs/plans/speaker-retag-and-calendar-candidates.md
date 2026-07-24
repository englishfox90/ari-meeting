# Speaker Re-tag Without Re-diarization + Calendar Attendee Candidates

**Plan:** `docs/plans/speaker-retag-and-calendar-candidates.md`
**Phase:** Swift migration Phase 3 (identity) — a tightly-scoped follow-on to the landed offline diarization port (`docs/plans/arikit-diarization.md`, D1–D9b done). Same identity seam; not a new phase (WIP-limit note in §7).
**Status:** PLAN-ONLY. No code.
**Rust incumbent:** none to port. Both improvements are **net-new Swift UX on already-shipped Swift capability** — the reconstruct-from-store path (#2) and the calendar-candidate picker section (#3) have no frozen Rust analogue (the Rust `diarize-helper` flow always re-ran the whole file, and its assign dialog had voice-only + full-list picking). This lands entirely on the target (Swift) side of the cut seam (plan principle 8). Confirmed net-new; nothing to freeze-check.

---

## 1. Goal & seam

Two independent slices on the offline "Identify speakers" flow, both read-only additions that never change what `DiarizationService.run(...)` does:

- **#2 — Reach the assign UI without re-diarizing.** Today the sheet renders assignable speaker rows only under `runState == .succeeded(result)`, and the *only* producer of that state is `SpeakerIdentificationViewModel.run(...)` (`SpeakerIdentificationViewModel.swift:171`), which calls the full whole-file pipeline (`DiarizationService.run`, `DiarizationService.swift:106`) — decode + diarize the entire audio. So tagging a second speaker in an already-diarized meeting pays the full re-diarization cost. Add a read-only **reconstruct-from-store** path that rebuilds the assignable list from persisted `speaker`/`speakerSegment`/`transcript` rows and opens the sheet straight to it. Full re-diarization stays available as an explicit "Re-run" action.
- **#3 — Calendar attendees as assign candidates.** The assign picker (`AssignPersonView`, `IdentifySpeakersSheet.swift:319`) offers voice-only "Looks like…" suggestions + the entire unfiltered person table ("All people", `IdentifySpeakersSheet.swift:382-390`). A never-enrolled invited attendee gets no suggestion even when the linked calendar event names them. Add a "Likely in this meeting" section resolved read-only from the linked event's attendees ∪ linked participants, shown above the voice matches.

Seam: both attach at the existing offline identify surface — `SpeakerIdentificationViewModel` + `DiarizationService` (headless AriKit) and the `IdentifySpeakersSheet`/`AssignPersonView` (Ari app). No capture, no hot path, no new engine.

---

## 2. Module & surface (minimal public additions)

### AriKit — `DiarizationService` (actor, `DiarizationService.swift`)

**#2 reconstruction (read-only, no writes):**

```swift
/// One speaker rebuilt from persisted diarization rows for a meeting. Carries ONLY fields that
/// genuinely exist in the store — no fabricated match score/tier (No-Fake-State).
public struct PersistedSpeaker: Sendable, Equatable {
    public var speakerId: SpeakerID
    public var isAssigned: Bool      // personId != nil AND enrollmentState in {confirmed, owner}
    public var speechSecs: Double    // SUM of THIS meeting's segment durations (not Speaker.totalSpeechSecs)
}

public struct PersistedDiarizationResult: Sendable, Equatable {
    public var speakers: [PersistedSpeaker]   // oldest-first, mirrors SpeakerRepository.forMeeting order
    public var stampedRows: Int               // transcripts in this meeting with a non-nil speakerId
    public var unresolvedRows: Int            // timed transcript rows with a nil speakerId
}

/// Read-only rebuild of a completed run's assignable view from persisted rows. Returns `nil` when
/// the meeting has never been diarized (no `speakerSegment` rows) — the caller then keeps `.idle`
/// and requires an explicit run. Writes nothing (I1/I5/idempotency preserved trivially).
public func loadPersisted(meetingId: MeetingID) async throws -> PersistedDiarizationResult?
```

Implementation reads only existing repository methods — **no new SpeakerRepository/SpeakerSegmentRepository method required**:
- "already diarized?" = `database.speakerSegments.forMeeting(meetingId)` (`SpeakerSegmentRepository.swift:32`) non-empty.
- speaker list = `database.speakers.forMeeting(meetingId)` (`SpeakerRepository.swift:52`) — distinct, non-deleted, oldest-first.
- per-meeting `speechSecs` = sum of `endTime - startTime` over that meeting's segments grouped by `speakerId`, computed in Swift from the segments already fetched. **Must not use `Speaker.totalSpeechSecs`** — that field is the cross-meeting accumulated fold weight (`Speaker.swift:59-60`), not per-meeting.
- `isAssigned` = `speaker.personId != nil && speaker.enrollmentState ∈ {confirmed, owner}` (`Speaker.swift:50,58`).
- `stampedRows`/`unresolvedRows` from `database.transcripts.forMeeting(meetingId)` (timed rows with/without `speakerId`, matching `RunResult`'s honest counts).

**#3 candidate resolution (read-only):**

```swift
/// The people likely in this meeting, resolved READ-ONLY from the linked calendar event's
/// attendees (by email) UNIONed with already-linked participants. Never creates person stubs
/// (that is the calendar-sync job). Honest empty when there is no calendar link and no
/// participants. Deduped by PersonID, sorted by displayName.
public func likelyAttendees(inMeeting meetingId: MeetingID) async throws -> [Person]
```

Resolution chain (reuses live-speaker-id §5 step 1–2 verbatim, but for the offline picker):
1. `database.calendarEvents.forMeeting(meetingId)` (`CalendarEventRepository.swift:44`) → union all `.attendees` (`CalendarEvent.attendees`, `CalendarEvent.swift:90`; `Attendee.email`, `CalendarEvent.swift:70`).
2. each `attendee.email` → `database.persons.findByEmail(email)` (NEW public read — see below); drop `nil` resolutions (No-Fake-State, no stub write).
3. ∪ `database.persons.participants(inMeeting: meetingId)` (`PersonRepository.swift:182`) — same preference order the count-hint provider uses (`StoredCalendarHintProvider.swift:24-33`).
4. dedup by `Person.id`, sort by `displayName`.

### AriKit — `PersonRepository` (`PersonRepository.swift`)

```swift
/// Case-insensitive, non-deleted email lookup. Read-only public wrapper over the existing
/// store-internal static `findByEmail` (PersonRepository.swift:331) — never writes; never
/// creates a stub (that is `upsertStubFromAttendee`'s job).
public func findByEmail(_ email: String) async throws -> Person?
```

Thin `dbWriter.read` wrapper delegating to the existing `static findByEmail(_:db:)` (`PersonRepository.swift:331`). This is the exact addition live-speaker-id §5 (open decision 3) recommended; shared by both plans.

### AriViewModels — `SpeakerIdentificationViewModel` (`SpeakerIdentificationViewModel.swift`)

**#2 new `RunState` case** (rejecting reuse of `.succeeded(RunResult)` — see §6 No-Fake-State):

```swift
public enum RunState {
    case idle
    case running(phase: DiarizationPhase, fraction: Double)
    case succeeded(DiarizationService.RunResult)          // fresh run — honest MatchDecision scores
    case reconstructed(DiarizationService.PersistedDiarizationResult)  // rebuilt from store — no scores
    case failed(String)
}

/// Rebuilds the assignable list from persisted rows WITHOUT running the pipeline. On success sets
/// `.reconstructed`; on "never diarized" leaves `runState` untouched (stays `.idle` — explicit run
/// still required); on error sets `.failed`. Refuses to overwrite a live `.running`.
public func loadPersisted(meetingId: MeetingID) async
```

**#3 new observable state + loader:**

```swift
public private(set) var likelyPeople: [Person] = []   // honest empty until loaded / when none
public func loadLikelyPeople(inMeeting meetingId: MeetingID) async
```

Both wired through the existing injected-closure pattern (mirrors `RunOperation`/`ConfirmOperation`, `SpeakerIdentificationViewModel.swift:70-88`): add `LoadPersistedOperation` and `LikelyPeopleOperation` typealiases + convenience-init closures calling `service.loadPersisted(...)` / `service.likelyAttendees(...)`. Keeps the VM headless and app-target-free.

### Ari app — `IdentifySpeakersSheet` / `MeetingDetailView`

- `.task` (`IdentifySpeakersSheet.swift:108`) additionally calls `await viewModel.loadPersisted(meetingId)` and `await viewModel.loadLikelyPeople(inMeeting: meetingId)` before/alongside `loadHint`/`loadAssignablePeople`. If reconstruction succeeds, the results list renders immediately; suggestion-loading (currently `loadSuggestions()`, `IdentifySpeakersSheet.swift:303`) must also run for reconstructed provisional (`!isAssigned`) speakers.
- `resultsSection` (`IdentifySpeakersSheet.swift:220`) renders for **both** `.succeeded` and `.reconstructed`, feeding `SpeakerAssignmentRow`. Because `SpeakerAssignmentRow` today takes a `DiarizationService.ResolvedSpeaker` but renders only `.tier` and `.speechSecs` (never `.score`, confirmed by reading `SpeakerAssignmentRow.swift:33-114`), the row is refactored to take the minimal fields it actually renders — a small render-tier enum (`identified`/`assignable`) + `speechSecs` + `speakerId` — so a fresh run maps its `MatchTier` (`autoConfirm`→identified, `suggest`/`anonymous`→assignable) and a reconstruction maps `isAssigned` (true→identified, false→assignable) into it without either path fabricating a score. Confirmed-override behavior (`confirmedSpeakerNames`, `IdentifySpeakersSheet.swift:60`) is unchanged.
- The count/run section (`countSection`, `IdentifySpeakersSheet.swift:120`) stays but, when state is `.reconstructed`/`.succeeded`, its primary action is reframed as an explicit **"Re-run diarization"** (calls the unchanged `viewModel.run(...)`), not the default path to reach the assign UI.
- `AssignPersonView` (`IdentifySpeakersSheet.swift:319`) gains `let likely: [Person]`; `peopleColumn` (`IdentifySpeakersSheet.swift:371`) renders a **"Likely in this meeting"** section ABOVE "Looks like…" → "All people" → "New person". When `likely.isEmpty` the section is omitted entirely (honest absence, never a "no candidates" placeholder). `MeetingDetailView.identifySpeakersSheet` (`MeetingDetailView.swift:917`) passes `viewModel.likelyPeople` through.

Value types + protocols preferred; the only `@Observable` class touched is the existing view model.

---

## 3. Concurrency model

- `DiarizationService` is an `actor` (`DiarizationService.swift:36`); `loadPersisted`/`likelyAttendees` are `async` read-only methods on it, doing only `dbWriter.read` repository calls — no new threading, no main-actor work, nothing on any capture/STT hot path (there is no capture here).
- `SpeakerIdentificationViewModel` is `@MainActor @Observable` (`SpeakerIdentificationViewModel.swift:28`); `loadPersisted`/`loadLikelyPeople` await the injected `@Sendable` closures and assign results on the main actor — same shape as the existing `loadAssignablePeople` (`SpeakerIdentificationViewModel.swift:212`). `loadPersisted` reuses the `.running` reentrancy guard (`SpeakerIdentificationViewModel.swift:172`) so it can't clobber an in-flight run.
- All new seam types (`PersistedSpeaker`, `PersistedDiarizationResult`, `[Person]`) are `Sendable` value types. **No `@unchecked Sendable` / `nonisolated(unsafe)`.** Targets stay `.swiftLanguageMode(.v6)`.
- `PersonRepository.findByEmail` is a plain `dbWriter.read` — safe to call concurrently; single DB owner preserved (§6).

---

## 4. Persistence

**No schema change. No new migration.** (v1_baseline stays frozen; nothing to alter.) Both slices are pure reads over existing tables:

| Read | Existing method | File:line |
|---|---|---|
| meeting's segments (detect + speechSecs) | `SpeakerSegmentRepository.forMeeting` | `SpeakerSegmentRepository.swift:32` |
| meeting's speakers | `SpeakerRepository.forMeeting` | `SpeakerRepository.swift:52` |
| meeting's transcripts (stamp counts, samples) | `TranscriptRepository.forMeeting` (already used, `MeetingDetailViewModel.swift:53`) | — |
| linked calendar events | `CalendarEventRepository.forMeeting` | `CalendarEventRepository.swift:44` |
| linked participants | `PersonRepository.participants(inMeeting:)` | `PersonRepository.swift:182` |
| **NEW** email → person (read-only) | `PersonRepository.findByEmail` (public wrapper over static, `PersonRepository.swift:331`) | new |

Single-DB-owner rule reasserted: every access is through the `AppDatabase` repository layer; `DiarizationService` remains the sole writer of the diarization tables, and neither new method writes. No raw SQLite handles.

---

## 5. Acceptance tests (Swift Testing, written first)

**AriKit — `DiarizationServiceReconstructionTests` (in-memory `AppDatabase`):**
- `loadPersistedReconstructsSpeakersFromStore` — seed a diarized meeting (segments + speakers + stamped transcripts); assert returned `speakers` match persisted rows, oldest-first.
- `reconstructedSpeechSecsArePerMeetingSums` — a speaker with segments in two meetings: assert `speechSecs` is *this* meeting's segment-duration sum, NOT `Speaker.totalSpeechSecs`.
- `reconstructedIsAssignedReflectsEnrollment` — confirmed/owner speaker → `isAssigned == true`; provisional (personId nil) → `false`.
- `reconstructedStampCountsAreHonest` — `stampedRows`/`unresolvedRows` equal real counts of timed transcripts with/without `speakerId`.
- `loadPersistedReturnsNilWhenNeverDiarized` — meeting with no segments → `nil`.
- `loadPersistedPerformsNoWrites` — snapshot row counts on `speaker`/`speakerSegment`/`transcript`/`meetingParticipant`; run `loadPersisted`; assert all unchanged (I1/I5).

**AriKit — `DiarizationServiceLikelyAttendeesTests` + `PersonRepositoryFindByEmailTests`:**
- `likelyAttendeesResolvesCalendarEmailsReadOnly` — linked event with 2 attendee emails matching 2 persons → both returned; assert person-table row count unchanged (no stub write).
- `unresolvedAttendeeIsOmittedNeverFabricated` — attendee email with no matching person → absent; no stub created.
- `likelyAttendeesUnionsParticipantsAndDedups` — a linked participant not in attendees appears; a person in both appears once.
- `likelyAttendeesEmptyWithoutCalendarLinkOrParticipants` — no linked event + no participants → `[]`.
- `findByEmailIsCaseInsensitiveAndExcludesDeleted` — mirrors the static impl (`PersonRepository.swift:331-336`); confirms no write.

**AriViewModels — `SpeakerIdentificationViewModelTests` (spy closures):**
- `loadPersistedReachesAssignUIWithZeroDiarizeCalls` — inject a `runOperation` spy and an audio-loader spy that **fail the test if invoked** (`#expect(Bool(false))`), plus a `loadPersistedOperation` returning a reconstructed result; call `loadPersisted`; assert `runState == .reconstructed(...)` AND the run/audio-load spies were never called. (This is the load-bearing #2 proof.)
- `loadPersistedNilLeavesIdle` — operation returns nil → `runState` stays `.idle`.
- `loadPersistedDoesNotOverrideRunningState` — reentrancy guard holds.
- `rerunAfterReconstructStillRunsAndStaysIdempotent` — after `.reconstructed`, `run(...)` invokes the run operation exactly once and transitions `.running`→`.succeeded`; a second `run` re-invokes cleanly (idempotency owned by `run`/`clearMeetingDiarization`, unchanged).
- `loadLikelyPeoplePopulatesHonestly` — closure returns 2 → `likelyPeople.count == 2`; throwing closure → `likelyPeople == []`.
- `confirmRemainsOnlyWritePath` — assert neither `loadPersisted` nor `loadLikelyPeople` touches the `confirmOperation` spy (I1).

**Section ordering (#3):** `AssignPersonView` is SwiftUI and not unit-tested directly; ordering is encoded by the VM-array test above plus a documented composition contract ("Likely in this meeting" → "Looks like…" → "All people" → "New person"). Note this as the one place the bar rests on a composition contract rather than a unit assertion.

**Dual-run / eval gate:** none applies — no Rust incumbent to dual-run against, and no S1–S4 spike gate is in scope (this is UX over already-GO'd offline diarization, S3). Existing `SpeakerMatcherTests` and the recall suite are regression-checked each step.

---

## 6. Invariants preserved

- **I1 confirm-before-enroll.** The only write path into a person↔voiceprint link remains `SpeakerIdentificationViewModel.confirm` → `DiarizationService.confirmSpeaker` (`DiarizationService.swift:272`). `loadPersisted`, `likelyAttendees`, and `findByEmail` are strictly read-only; #3 explicitly does **not** auto-create person stubs (that stays the calendar-sync job via `upsertStubFromAttendee`, `PersonRepository.swift:261`).
- **No-Fake-State.** #2 introduces `.reconstructed` with `PersistedSpeaker` carrying only store-backed fields — it does **not** reuse `.succeeded(RunResult)`/`ResolvedSpeaker`, whose `score`/`tier` (`SpeakerMatcher.swift:49-58`) are a *fresh run's* real match decision and would be fabricated for a rebuild. `SpeakerAssignmentRow` is narrowed to the fields it truly renders so neither path invents a score. #3 shows only genuinely-resolved persons; unresolved attendees are omitted; empty sections vanish rather than showing placeholders.
- **Single-DB-owner.** All access via the `AppDatabase` repository layer; `DiarizationService` stays the sole diarization writer; no new writes, no second owner.
- **Offline-remains-source-of-truth / idempotency (I3).** `run(...)` and `clearMeetingDiarization` (`SpeakerRepository.swift:174`) are untouched; re-run stays the explicit, idempotent authority. Reconstruction is a faithful read of what a prior run already wrote.

---

## 7. Risks & sequencing

Ordered steps, each independently `swift build` / `swift test` green:

1. **`PersonRepository.findByEmail` public read + tests** (AriKit). Foundation for #3; also unblocks live-speaker-id L2. Independent.
2. **#2 service reconstruction** — `PersistedSpeaker`/`PersistedDiarizationResult` + `loadPersisted` + tests (AriKit). No UI.
3. **#2 view model** — `.reconstructed` case + `loadPersisted` + injected closure + tests (AriViewModels).
4. **#2 UI** — sheet `.task` calls `loadPersisted`; `resultsSection` + narrowed `SpeakerAssignmentRow` render both cases; "Re-run diarization" reframed (Ari app).
5. **#3 service** — `likelyAttendees(inMeeting:)` + tests (AriKit); depends on step 1.
6. **#3 view model** — `likelyPeople` + `loadLikelyPeople` + closure + tests (AriViewModels).
7. **#3 UI** — `AssignPersonView` "Likely in this meeting" section + ordering (Ari app).

Steps 2–4 (#2) and 5–7 (#3) are independent after step 1; either could ship first. Recommended order as listed (start with the shared read, then #2 which is the higher-value cost fix).

**Risks:**
- **R1 — stale cached VM.** `MeetingDetailView` caches `speakerIdentificationViewModel` across opens (`MeetingDetailView.swift:895-903`), so a prior `.succeeded`/`.reconstructed` could linger. Mitigation: `.task` always re-runs `loadPersisted` on present; it overwrites state deterministically.
- **R2 — "diarized but all speakers tombstoned"** edge case (segments exist but `speakers.forMeeting` returns empty after soft-deletes). Mitigation: treat empty speaker list as "reconstruct produced no rows" → fall back to `.idle` (offer a run), which is honest.
- **R3 — attendee/participant duplication across picker sections.** A person could appear in both "Likely" and "Looks like…". Mitigation: acceptable (different rationale, both honest); optional later refinement to suppress a "Likely" row already shown as the top voice suggestion — deferred, not in this slice.
- **R4 — WIP limit.** Two related improvements are one slice on one seam (offline identify), not two phases; they share step 1 and the same files. This stays within the single-feature limit. If step 4/7 UI churn grows, split #2 and #3 into sequential PRs behind the shared step 1.
- **No spike-gate dependency**, so no Rust-sidecar fallback question arises.

---

## Decisions (settled 2026-07-23)

1. **`.reconstructed` new RunState case** — ADOPTED (architect-recommended). A rebuild never carries a fabricated `MatchDecision.score`/`tier` (No-Fake-State). The lighter `score = 0` alternative was rejected (stamps an unused-yet-fake field).
2. **`PersonRepository.findByEmail` public read** — ADOPTED. Shared with live-speaker-id §5; enables never-linked invited attendees to surface as candidates.
3. **Picker cross-section dedup (R3)** — allow duplication in this slice (simplest, honest); suppress-if-already-top-voice-suggestion deferred.
