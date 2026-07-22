# Live (Real-Time) Speaker Identification During Recording

**Plan:** `docs/plans/live-speaker-id.md`
**Phase:** Swift migration Phase 3 (identity) — a **follow-on to the post-hoc diarization port** (`docs/plans/arikit-diarization.md`, Phase 3 step 5, `plans/swift-migration-plan.md:186`). Same identity seam; not a new phase (see §9 R5 WIP note).
**Status:** PLAN-ONLY (2026-07-22). No code. Depends on Phase-3.5 diarization being landed (it is — D1–D9b done, `docs/plans/arikit-diarization.md:5`); D10 calibration + S3 human close are still open and are shared dependencies.
**Rust incumbent:** **none for live ID.** The frozen Rust app diarizes **post-meeting** via the `diarize-helper` sherpa sidecar; real-time speaker labelling during recording was **never shipped in Rust** (the `reid-integration-contract` explored the PCM tap but its recommended contract was "emit transcript with `speaker_id: None`, run re-ID off the hot path, then patch the DB row" — still after-the-fact). **This is net-new Swift capability, not a re-implementation of a frozen feature** (see §1).
**Spike evidence:** S3 FluidAudio conditional-GO (`plans/swift-migration-plan.md:104`) — but that gate covered the **offline** pipeline only; the migration plan explicitly warns FluidAudio's **streaming** DER is 38–53% (`swift-migration-plan.md:97`). This plan's central risk (§2, gate **S-Live1**) is a *new* spike, not covered by S3.

---

## 1. Goal, seam, scope

### Goal

During a live recording, surface a near-real-time, **advisory** guess at who is currently speaking, by embedding a rolling window of incoming speech and matching it against **already-enrolled voiceprints** — reusing the existing three-tier `SpeakerMatcher` and confirm-before-enroll rules verbatim. When the meeting is **calendar-linked**, pre-load only the expected attendees' voiceprints so matching runs against a small, high-precision pool instead of the whole database. Live labels are a hint; the existing offline `DiarizationService` remains the sole source of truth and the sole writer of `speaker`/`speakerSegment`/`transcript.speakerId`.

### Seam

The intended seam already exists and has **no consumer today**: `CaptureCoordinator.forkedWindows()` (`AriKit/Sources/AriCapture/CaptureCoordinator.swift:236`), fed by `emitWindow`'s pre-mix fork (`CaptureCoordinator.swift:324-326` — "The pre-mix fork FIRST — mic + system still separate (the Q2/F1 seam)"). The fork is a drop-oldest `AsyncStream<PCMWindow>` with a 32-window buffer (`CaptureCoordinator.swift:116`) constructed at init, precisely so a slow diarization consumer can never stall windowing (`CaptureCoordinator.swift:10-13`). The file header names this the seam "so both the mixed-STT path and later diarization (F1, Phase 3.5) can consume the pre-mix streams" (`PCMWindow.swift:8-10`). This plan builds the first consumer of it.

This lands entirely on the **target (Swift) side of the cut seam** (plan principle 8): the `forkedWindows()` seam, the matcher, and the store are all Swift-native; no Rust work is planned or possible (the Rust app has no live-ID path to extend). Confirmed net-new.

### Non-goals (explicitly deferred)

- **Live labels as authoritative / persisted speaker stamps.** Live never writes `speaker`/`speakerSegment`/`transcript.speakerId`. The offline pass owns those tables (§6). This is the load-bearing safety decision.
- **Live turn segmentation via FluidAudio's streaming diarizer** (`SortformerDiarizer`/`LSEENDDiarizer`). Its 26–53% DER (`swift-migration-plan.md:97`) makes it unfit as a source of truth; a later slice *may* use it only to detect speaker-change boundaries. Not this plan.
- **Live auto-enrollment / voiceprint folding.** Live matching reads confirmed/owner voiceprints and writes nothing back — confirm-before-enroll (I1) is preserved trivially.
- **Remote-participant separation.** System audio is ONE mixed mono stream (`SystemAudioTap.swift:14-17`, Q3) — individual remote callers are not separable live any more than offline. Live ID on the system source is best-effort "someone enrolled is speaking", constrained by the calendar pool.
- **iOS / "Ari Lite".** Speaker ID is excluded there by design (`swift-migration-plan.md:87`); this is macOS-only (`AriCapture` is `#if os(macOS)`).
- **Owner-mic-track separation.** The mic fork *is* separable from system, but this plan treats both fork sources uniformly for a first slice; per-source policy (mic = in-room, system = remote pool) is a later refinement (§9 sequencing).

---

## 2. The embedding problem (CENTRAL RISK)

**The invariant that makes or breaks this feature is I7 (embedding-space integrity):** a live embedding is meaningless unless it lives in the **same vector space (same `embeddingModel` string + `dim`)** as the enrolled voiceprints in the `speaker` table. Those enrolled centroids were built by `FluidAudioCentroidBuilder` from the **offline** pipeline's `DiarizationResult.segments[].embedding` (`FluidAudioDiarizationProvider.swift:65,139-162`), stamped `embeddingModel = "fluidaudio-community-1"` (`FluidAudioDiarizationProvider.swift:18`), dim ≈ 256 (WeSpeaker; per FluidAudio docs, see Sources below).

### Can community-1 embeddings be produced incrementally?

**FluidAudio's offline `OfflineDiarizerManager.process(audio:)` is whole-file** (`spikes/fluidaudio-s3/README.md:37`) — it is *not* a rolling-window API and MUST NOT be called on live windows. But FluidAudio's diarizer separately exposes a **standalone embedding extractor** and a **`SpeakerManager`**:

- `diarizer.extractEmbedding(audio)` → a **256-D L2-normalized** WeSpeaker embedding from an arbitrary audio buffer (FluidAudio `Documentation/Diarization/GettingStarted.md`; DeepWiki "Clustering Algorithms and Speaker Management"). This is the candidate live embedder: run it on a rolling ~N-second buffer, off the hot path.
- `SpeakerManager.initializeKnownSpeakers([...])` + `assignSpeaker` with `speakerThreshold`/`embeddingThreshold` — FluidAudio's *own* matcher. **We do not use it.** We use our `SpeakerMatcher` (cosine *similarity*, three-tier, confirm-before-enroll) so live and offline share one decision path, one set of thresholds (`MatchConfig`), and one confirm-gate. FluidAudio's assign path uses cosine *distance* and its own enrollment model — adopting it would fork the identity logic and bypass I1.

### The unresolved question the docs do NOT answer

FluidAudio's public docs do **not** state that `extractEmbedding()`'s output is bit-for-bit the same vector the **offline** pipeline averages into `DiarizationResult.segments[].embedding`. Both are described as WeSpeaker 256-D, which strongly implies the same model — but "same model" is not proven to be "same space as our stored centroids" (segment embeddings may carry offline-only pre/post-processing — VAD-cropped windows, quality weighting — that a raw `extractEmbedding` call does not replicate). **This is the gate.**

### Gate S-Live1 (throwaway spike, GO/NO-GO — must run before any production slice)

Extend `spikes/fluidaudio-s3/`: for a known 2-speaker fixture, (a) run the offline pipeline and take each speaker's stored centroid; (b) run `extractEmbedding()` on several rolling windows of the same speakers' speech; (c) assert same-speaker cosine ≫ cross-speaker cosine, and that same-speaker live-vs-enrolled cosine clears roughly the `MatchConfig.autoThreshold` band (0.70, `MatchConfig.swift:12`). Record numbers in this plan.

- **GO** (live embeddings are in the enrolled space): proceed with the design below; live provider stamps `embeddingModel = "fluidaudio-community-1"` and queries `SpeakerRepository.matchCandidates(embeddingModel:)` (`SpeakerRepository.swift:75`) directly — the enrolled pool *is* the candidate pool.
- **NO-GO** (spaces differ): the live embedder stamps a **distinct** `embeddingModel` (e.g. `"fluidaudio-live-wespeaker"`). Because `matchCandidates` filters by `embeddingModel` (`SpeakerRepository.swift:79`), there would be **zero overlap** with enrolled prints → live ID cannot name anyone. Honest fallback: **ship live ID as anonymous "voice activity + turn indicator" only** (no names), or **defer the whole feature** until an in-space live embedder exists. Do not fabricate a name from a mismatched space (No-Fake-State). Recommended if NO-GO: defer; do not ship a names-less "who's speaking" that the product's differentiator (recurring identity) can't back.

A secondary calibration point rides on S-Live1: live windows are short and un-VAD-floored, so the offline `MatchConfig` thresholds (tuned for whole clusters) will likely be **too loose live**. The plan ships live matching with a **stricter live `MatchConfig`** (raise `autoThreshold`, widen `margin`) so a fleeting cross-talk window never shows a confident wrong name; exact values set from S-Live1 + the D10 calibration data. Until calibrated, **demote live `autoConfirm` to `suggest`** in the UI (safety, zero write risk).

---

## 3. Module boundaries & public surface

Dependency direction mirrors the diarization plan's isolation recipe (`docs/plans/arikit-diarization.md:48-56`): core `AriKit` never imports FluidAudio.

| Target | Language mode | New contents |
|---|---|---|
| `AriKit` (existing) | `.v6` | **`LiveSpeakerEmbedding` protocol** (seam), **`LiveSpeakerIdentifier` actor** (rolling buffer + matcher, DB-free), **`LiveSpeakerGuess` / `LiveIdentityState`** value types, **`LiveCandidatePool`** value type, **`StubLiveSpeakerEmbedder`** (test support). Reuses `SpeakerMatcher`, `MatchConfig`, `SpeakerMath`, `CentroidCodec`, `PCMWindow`. |
| `AriKitDiarizationFluidAudio` (existing, `Package.swift:207`) | `.v6` | **`FluidAudioLiveEmbedder`** — the sole `LiveSpeakerEmbedding` conformer, wrapping `extractEmbedding()`; an **actor** (holds loaded CoreML models, same rationale as `FluidAudioDiarizationProvider.swift:6-9`). |
| `AriCapture` (existing) | `.v6` | **`LiveResampler16k`** — a *streaming* 48 kHz→16 kHz mono window converter (distinct from `DiarizationAudioLoader` which decodes a whole file, `DiarizationAudioLoader.swift:5-11`, and from `Resampler` which only targets 48 kHz, `Resampler.swift:23`). |
| `AriViewModels` (existing) | `.v6` | **`CaptureService.forkedWindows()`** added to the protocol (`CaptureService.swift:16`); **`LiveSpeakerViewModel`** (`@Observable`) OR live-guess state folded into `RecordingSession`. **`LiveSpeakerIdProviding`** closure seam so `RecordingSession` stays FluidAudio-free (same pattern as `makeCaptureService`, `RecordingSession.swift:83`). |
| `Ari` app | — | `forkedWindows()` impl in `LiveCaptureService` (`Ari/Capture/LiveCaptureService.swift`); FluidAudio live-embedder injection at composition root; SwiftUI live-speaker surface. |

### Public API (core AriKit)

```swift
// The live embedder seam. Sendable so it crosses actor boundaries. NEVER called on the
// capture hot path (mirrors DiarizationProvider.swift:36).
public protocol LiveSpeakerEmbedding: Sendable {
    /// The embedding-space id all vectors live in. MUST equal enrolled voiceprints'
    /// embeddingModel for matching to be meaningful (I7). Value set by gate S-Live1 (§2).
    var embeddingModel: String { get }
    func prepare() async throws
    /// `samples`: 16 kHz mono [-1,1], a rolling window (~N s). Returns an L2-normalized
    /// embedding, or `nil` when the window is too short/silent to embed honestly (No-Fake-State).
    func embed(window: [Float]) async throws -> [Float]?
}

/// One advisory live guess for the current window. Never persisted.
public struct LiveSpeakerGuess: Sendable, Equatable {
    public var source: CaptureSource         // .microphone (in-room) vs .system (remote pool)
    public var decision: MatchDecision       // reused verbatim — tier/score/speakerId
    public var atSeconds: Double             // PCMWindow.hostTime
}

/// The bounded, pre-loaded set of voiceprints live matching runs against.
public struct LiveCandidatePool: Sendable, Equatable {
    public var candidates: [(id: SpeakerID, personId: PersonID?, centroid: [Float])]
    public var embeddingModel: String
    public var origin: Origin                // .calendarConstrained(count:) | .fullEnrolled | .empty
    public enum Origin: Sendable, Equatable { case calendarConstrained(Int), fullEnrolled, empty }
}
```

`LiveSpeakerIdentifier` (actor, core AriKit) owns the rolling buffer per source, calls `embed()` off the hot path, runs `SpeakerMatcher.match(...)` against the pool, and yields an `AsyncStream<LiveSpeakerGuess>`. **It has no `AppDatabase` handle and performs no writes** (I1/I5). The candidate pool is built once (via repositories, off-hot-path) and injected.

---

## 4. Concurrency model

- **Hot path is untouched.** `LiveSpeakerIdentifier` consumes `forkedWindows()`, a drop-oldest `.bufferingNewest(32)` stream (`CaptureCoordinator.swift:116`). The capture window loop only ever calls `forkedContinuation?.yield(...)` (`CaptureCoordinator.swift:357`), which is non-blocking; a slow embedder drops windows (real silence to it, logged honestly — same posture as the mixed/STT lane, `CaptureCoordinator.swift:336-339`). **This is the Swift mirror of the Rust "never block STT" contract** (`open-questions.md` Q2: "Never do embedding inference inline in that loop").
- **`LiveSpeakerIdentifier` is an `actor`.** It accumulates windows into a per-source rolling buffer, resamples 48→16 kHz (`LiveResampler16k`), and — gated by a min-window and a cheap energy/VAD check — awaits `embedder.embed(...)` and `SpeakerMatcher.match(...)`. All heavy work (`embed`) is inside the FluidAudio actor's `async` calls, off the main actor and off the capture actor.
- **Cadence & backpressure.** Embed on a **sliding ~3 s window advanced every ~1 s** (tunable; set with S-Live1). If an `embed()` is still in flight when the next window is ready, **skip** rather than queue (a live guess is only useful if fresh; a backlog would show stale names). Guesses cross to `@MainActor` via the `AsyncStream` + a `Task { @MainActor in ... }` hop into `@Observable` state (same bridge as `RecordingSession.beginLiveConsumption`, `RecordingSession.swift:360-365`) — no Combine, no TCA.
- **Sendable boundaries.** Every seam type (`LiveSpeakerGuess`, `LiveCandidatePool`, `MatchDecision`, `[Float]`) is a `Sendable` value type. `FluidAudioLiveEmbedder` is an actor (not `@unchecked Sendable`) to hold CoreML models legitimately (`FluidAudioDiarizationProvider.swift:6-9`). **No `@unchecked Sendable` / `nonisolated(unsafe)` in our code.** If the FluidAudio-consuming target won't compile clean under `.v6`, the `.v5` exception is scoped to that target only (precedent `AriKitEngineMLX`, `Package.swift:188`) — but the existing `AriKitDiarizationFluidAudio` already compiles `.v6` (`Package.swift:203-214`), so `.v6` is expected.
- **Memory.** A 3 s rolling window at 16 kHz mono f32 is ~192 KB — trivial (vs the offline job's ~150 MB, `arikit-diarization.md` §4). Buffers are dropped as they slide.

---

## 5. Calendar-constrained candidate set

The precision win: instead of matching against the whole enrolled DB, pre-load only the voiceprints of the people expected in *this* meeting.

**Resolution chain (built once, at recording start, off the hot path, via repositories only):**

1. **Expected persons.** Prefer the meeting's linked calendar event's attendees. The linkage hook already exists: `RecordingSession.pendingCalendarLink` is consumed at start and written via `calendarEvents.setManualLink(...)` (`RecordingSession.swift:241-243`). Resolve attendees for the linked event via `CalendarEventRepository.forMeeting(_:)` (`CalendarEventRepository.swift:44`) → `CalendarEvent.attendees` (`[Attendee]` with `email`/`name`, `CalendarEvent.swift:67-76`). Also union with `PersonRepository.participants(inMeeting:)` (`PersonRepository.swift:111`) for any already-linked participants — same preference order the count-hint provider uses (`StoredCalendarHintProvider.swift:24-33`).
2. **Attendee → person.** For each attendee `email`, resolve to a `Person`. `PersonRepository` currently exposes email resolution only via `upsertStubFromAttendee` (`PersonRepository.swift:189`, which *writes*) and a **private** `findByEmail` (`PersonRepository.swift:254`). **Decision needed:** add a **public read-only `findByEmail(_:) -> Person?`** to `PersonRepository` (preferred — no write during pool-build), or restrict the first slice to already-linked participants (`participants(inMeeting:)`, no new API). Recommended: add the read-only lookup; do **not** auto-create person stubs during a live recording (that is a write, and it is the calendar-sync job's responsibility, not live ID's).
3. **Person → voiceprint.** `SpeakerRepository.canonicalEnrolledSpeaker(for: personId)` (`SpeakerRepository.swift:218`) returns the person's canonical confirmed/owner voiceprint (or `nil`). Decode its centroid with `CentroidCodec.vector(from:)`. Filter to `embeddingModel == embedder.embeddingModel` (I7).

**Graceful behavior (No-Fake-State):**
- **Unenrolled expected attendee** (no canonical voiceprint) → simply absent from the pool. Live ID can't name them; it shows anonymous/voice-activity, never a guess (they're not a candidate).
- **Non-calendar meeting** (empty attendees + no participants) → `origin = .fullEnrolled`: fall back to `SpeakerRepository.matchCandidates(embeddingModel:)` (`SpeakerRepository.swift:75`, the whole confirmed/owner pool). Larger pool → the `margin` gate does more work; the stricter live `MatchConfig` (§2) guards against false confidence.
- **No enrolled voiceprints at all** → `origin = .empty`: `SpeakerMatcher.match` returns `.noCandidates` (`SpeakerMatcher.swift:84`) → UI shows "listening", never a name.
- The pool is **static for the session** (loaded once). A late calendar link mid-recording is a deferred refinement (§9).

---

## 6. Reconciliation with the post-hoc pass

**Live is advisory; offline `DiarizationService` is the source of truth.** The two never contend because they touch disjoint state:

- **Live writes nothing to the identity tables.** No `speaker`, `speakerSegment`, or `transcript.speakerId` writes from the live path — those are written only by `DiarizationService.run(...)` after the meeting (`DiarizationService.swift:106-256`) and by `confirmSpeaker(...)` (`DiarizationService.swift:272`). Live guesses live in `@Observable` VM state for the duration of the recording and are discarded on stop.
- **Confirm-before-enroll preserved (I1).** Live matching uses `matchCandidates`-filtered confirmed/owner voiceprints only and never folds (`persistFold`) or assigns (`assignToPerson`). A live `autoConfirm` is display-only; it enrolls nothing.
- **Idempotent re-run preserved (I3).** Because live writes no rows, the offline `clearMeetingDiarization` idempotency guard (`SpeakerRepository.swift:174`) and re-run behavior are entirely unaffected — there is nothing for live to corrupt.
- **Optional, safe hand-off (later slice, flagged):** the set of enrolled people live matching saw (distinct high-confidence guesses) could **prefill** the offline identify-speakers UI or tighten the offline candidate pool — but only as a UI hint the user still confirms, never as an auto-write. Deferred (§9); not required for the first slice.

If the offline pass later disagrees with a live guess, the offline result simply wins (it's the only thing written). The live guess was ephemeral and honest about being a guess.

---

## 7. UI surface (Marginalia + No-Fake-State)

The live recording view (the recording page, driven by `RecordingSession`) gains a **current-speaker readout**:

- **Confident (`suggest`+ against the pool):** show the person's name + a subtle confidence treatment (e.g. score as a quiet secondary label, not a fake precise %). Name chips may carry the Marginalia accent (Shin-kai), within the ≤8% rule (`arikit-diarization.md:483`). SF Symbols only (`person.crop.circle`, `waveform`) — never emoji.
- **Uncertain / anonymous / empty pool:** honest "Listening…" or a bare `waveform` with no name. **Never "Speaker 1", never a fabricated name** (No-Fake-State; mirrors the transcript fallback `TranscriptSegmentRow.swift` "No speaker"). An unenrolled or unmatched voice shows *presence*, not identity.
- **Advisory framing:** the readout is visibly a live hint (e.g. subtitle "live guess — confirm after the meeting"), so the user never mistakes it for the confirmed record. This also sets expectations honestly given live DER is worse than offline.
- **Recording red** is legitimate on this surface (it IS a capture surface, unlike the offline identify sheet) but stays reserved for the recording-state indicator, not speaker chips.
- Tokens via `MarginaliaColor`/`Typography`; parity enforced by the existing `MarginaliaTokenParityTests`.

State lives in `@Observable` VM state. Whether it is a new `LiveSpeakerViewModel` or fields on `RecordingSession` is an implementation choice for the UI slice; keeping the recording brain (`RecordingSession`, `@MainActor @Observable`, `RecordingSession.swift:23-25`) free of a FluidAudio dependency (via the `LiveSpeakerIdProviding` closure seam) is the constraint.

---

## 8. Acceptance tests & invariants

Tests are Swift Testing (`import Testing`), written first. Headless targets (`AriKit`, `AriViewModels`) run on `StubLiveSpeakerEmbedder`; the FluidAudio embedder gets an opt-in integration test.

### Invariants preserved

| # | Invariant | Enforcing test |
|---|---|---|
| I-L1 | **Never block capture** — a slow/blocked embedder drops windows, never stalls the fork | `slowEmbedderDropsWindowsNeverStallsFork` (feed a fast synthetic `forkedWindows` into a `LiveSpeakerIdentifier` with an artificially slow stub embedder; assert the producer stream never awaits the consumer and windows are dropped, not queued unbounded) |
| I-L2 | **No identity writes from live** — live path touches no `speaker`/`speakerSegment`/`transcript.speakerId` | `liveIdentifierPerformsNoDatabaseWrites` (in-memory `AppDatabase`; run a full live session; assert row counts on all three tables unchanged) |
| I-L3 | **Confirm-before-enroll (I1)** — live autoConfirm enrolls/folds nothing | `liveAutoConfirmDoesNotFoldOrAssign` (stub returns an in-space embedding matching a confirmed voiceprint; assert no `persistFold`/`assignToPerson` call, centroid/samples unchanged) |
| I-L4 | **Same embedding-space matching (I7)** — pool built only from voiceprints in the embedder's `embeddingModel` | `poolExcludesWrongEmbeddingSpace`, `poolExcludesProvisionalAndDeleted` |
| I-L5 | **No-Fake-State** — no name shown at anonymous/empty-pool/silent-window; short/silent window → `embed` returns `nil`, matcher → `.noCandidates`/`.anonymous` | `emptyPoolYieldsNoName`, `silentWindowProducesNoGuess`, `anonymousTierNeverShowsName` (VM) |
| I-L6 | **Consent-before-record untouched** — live ID starts only after `RecordingSession.confirmConsent()` starts capture; adds no capture path | `liveIdStartsOnlyAfterCaptureStarts` (assert `LiveSpeakerIdentifier` is wired only inside `beginLiveConsumption`, reachable only post-`.starting`; existing `RecordingSession` consent-invariant test unchanged) |
| I-L7 | **Offline remains source of truth / idempotent (I3)** — a live session before an offline run leaves the offline result and `clearMeetingDiarization` behavior identical | `offlineRunUnaffectedByPriorLiveSession` |
| I-L8 | **Recall safety shell untouched** | existing recall suite (regression check each slice) |

### Behavioral tests

- `LiveCandidatePoolTests`: calendar-linked meeting → `origin == .calendarConstrained(n)` with exactly the enrolled attendees; unenrolled attendee omitted; non-calendar meeting → `.fullEnrolled`; no enrolled → `.empty`; attendee-email → person resolution is read-only (no stub created — I-L2 corollary).
- `LiveSpeakerIdentifierTests` (stub embedder): rolling-window accumulation crosses the min-window threshold before emitting; sliding cadence; in-flight `embed` causes skip-not-queue; per-source (mic vs system) guesses tagged correctly; `MatchDecision` reused verbatim (tier boundaries covered by the existing `SpeakerMatcherTests`, not re-tested here).
- `FluidAudioLiveEmbedderTests` (opt-in, `.enabled(if: env)`, needs model download): `embed` on a bundled speech clip returns a 256-D L2-normalized vector; `prepare` idempotent (actor lazy-prepare, mirrors `FluidAudioDiarizationProvider` `prepareIsIdempotentAcrossRepeatedCalls`).
- `LiveResampler16kTests`: 48 kHz mono window → 16 kHz mono, correct sample count, empty-in → empty-out (No-Fake-State).
- `LiveSpeakerViewModelTests`: honest idle before first guess; name shown only at `suggest`+; anonymous/empty → no name; advisory framing string present; guesses arrive on `@MainActor`.

### Gate: S-Live1 (§2)

The **prerequisite spike** (extend `spikes/fluidaudio-s3/`). GO → live provider stamps `"fluidaudio-community-1"` and the enrolled pool is directly usable. NO-GO → distinct model id, live ID degrades to names-less or defers (§2). Record the same-vs-cross-speaker cosine numbers and the chosen live `MatchConfig` in this plan before any production slice ships default-on. This gate rides alongside the diarization plan's **D10** matcher calibration (`arikit-diarization.md:461`) — the live thresholds are calibrated from the same centroid-pair data.

---

## 9. Risks & sequencing

### Ordered slices (each independently testable, `swift build`/`swift test` green)

- **L0 — Gate S-Live1** (spike; §2). Blocks all production slices. GO/NO-GO recorded here.
- **L1 — Seam types + `LiveSpeakerIdentifier` + stub** (core AriKit; headless). `LiveSpeakerEmbedding`, `LiveSpeakerGuess`, `LiveCandidatePool`, `StubLiveSpeakerEmbedder`, the actor + rolling buffer + matcher reuse. Tests I-L1/I-L3/I-L5 + `LiveSpeakerIdentifierTests`. No DB, no UI.
- **L2 — `LiveCandidatePool` builder + `PersonRepository.findByEmail` read** (core AriKit; in-memory DB). Calendar-constrained + fallbacks. Tests I-L2/I-L4 + `LiveCandidatePoolTests`.
- **L3 — `LiveResampler16k`** (AriCapture). `LiveResampler16kTests`.
- **L4 — `FluidAudioLiveEmbedder`** (AriKitDiarizationFluidAudio). Opt-in integration test.
- **L5 — Wiring:** `CaptureService.forkedWindows()` + `LiveCaptureService` impl; `LiveSpeakerIdProviding` closure into `RecordingSession.beginLiveConsumption`; construct pool at start (post `pendingCalendarLink` consume). Tests I-L6/I-L7.
- **L6 — UI surface** (`AriViewModels` + `Ari`). `LiveSpeakerViewModelTests` + Marginalia parity. Ships with live `autoConfirm` demoted to `suggest` until S-Live1/D10 calibration lands.

Order: L0 → L1 → L2 → (L3, L4 parallel) → L5 → L6.

### Risks

- **R1 — Embedding-space mismatch (central, §2).** Mitigation: gate S-Live1 before any production slice; NO-GO path is honest (names-less or defer), never a fabricated name.
- **R2 — Live thresholds too loose on short windows.** Short un-VAD-floored windows + cross-talk → false-confident names. Mitigation: stricter live `MatchConfig`; ship `autoConfirm`→`suggest` until calibrated; advisory UI framing.
- **R3 — Remote participants unseparable (Q3).** System audio is one mixed stream (`SystemAudioTap.swift:14-17`); live ID on `.system` is "one of the enrolled expected people", not per-caller. Mitigation: calendar-constrained pool narrows it; UI honest about it; not a regression (offline has the same ceiling).
- **R4 — Fresh meeting has no calendar link yet.** `meetingId` is minted at start (`RecordingSession.swift:187`); only a `pendingCalendarLink` (notch/calendar-triggered start) gives attendees up front. Mitigation: fall back to `.fullEnrolled`; late-link refinement deferred.
- **R5 — WIP limit.** This **re-opens a stated non-goal of the diarization plan** ("Streaming / live diarization … offline pipeline only", `arikit-diarization.md:33`). It is a *deliberate follow-on* on the **same Phase-3 identity seam**, reusing that plan's matcher/persistence — not a second phase and not net-new Rust. It depends on Phase-3.5 being landed (it is) and shares D10/S3-close as open dependencies. **Recommendation: sequence after the diarization plan's D10 calibration + S3 human close**, so the live thresholds calibrate from the same data and the offline source-of-truth is validated first. Do not start L1+ while D10 is mid-flight.
- **R6 — License.** FluidAudio SDK Apache-2.0; pyannote/WeSpeaker-derived weights CC-BY-4.0 (attribution) — same as offline; no new obligation.

### If the S-Live1 gate is missed

There is **no Rust sidecar fallback** for live ID (the Rust app never had one). Missing S-Live1 means either shipping **anonymous live voice-activity only** (turn indicator, no names) or **deferring the feature**. Recommended: defer — a names-less "who's speaking" doesn't serve Ari's recurring-identity differentiator, and the offline pass already delivers confirmed identity. The offline path (frozen sherpa fallback in the Rust app, or the landed Swift `DiarizationService`) remains the identity source of truth regardless.

---

## Open decisions for the human

1. **Store strategy is settled** (GRDB, `swift-conventions.md`) — no decision here; live ID writes nothing anyway.
2. **Gate S-Live1 has not been run.** Its GO/NO-GO governs whether live ID can name people at all (§2). Run it before committing to L1+.
3. **`PersonRepository.findByEmail` public read** vs first-slice restriction to already-linked participants (§5 step 2). Recommended: add the read-only lookup; never write person stubs from the live path.
4. **Live `autoConfirm` policy** (§2/R2): ship demoted to `suggest` until calibrated (recommended), or enable once D10 calibration lands.
5. **Sequencing vs the diarization plan's open D10/S3 close** (R5): recommended to sequence after, to share calibration data and validate the offline source-of-truth first.

Sources for the FluidAudio streaming/embedding API surface (verified 2026-07-22): [FluidAudio API.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/API.md), [Diarization Getting Started](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md), [Clustering & Speaker Management (DeepWiki)](https://deepwiki.com/FluidInference/FluidAudio/3.2.3-offline-diarization-with-vbx-clustering).
